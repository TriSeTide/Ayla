"""媒体存储一致性审计（只读；可选 --prune-orphans 清理孤儿对象）。

## 为什么需要它

2026-10-29 事故：手工执行 `mc rm --versions --dangerous` 把整个 `media/` 前缀的
**当前对象连同历史版本**一起删除，导致 51 条 `MediaObject` 里绝大多数对象消失，
而**没有任何机制能发现这件事** —— `cleanup_media` 只看 DB，`/content` 到访问时才
报 404。事后只能从客户端漫游缓存抢救回 42 条。

本命令把「DB 声明」与「对象存储实际」做一次全量对账，输出三类问题：

| 类别 | 含义 | 危害 |
|---|---|---|
| **缺失（missing）** | DB 声明了 key，但对象不存在 | 用户看到「已过期」或「加载失败」，且永远无法恢复 |
| **孤儿（orphan）** | 对象存在，但没有任何 DB 记录引用 | 白占磁盘；通常是去重/completed 会话的 tmp 残留 |
| **非标准 key（nonstandard）** | key 不符合 `media/{kind}/{id}/{original,thumbnail,waveform}` 三选一 | 结构漂移，后续清理/TTL 逻辑无法识别 |

## 结构契约（唯一合法形态）

```
tmp/{upload_id}                                  上传暂存（不属于正式媒体）
media/{kind}/{32位小写hex}/{original|thumbnail|waveform}
  kind ∈ {image, voice, video, file, emoji}
```

除此之外**一律视为缺陷**，本命令会报出来。

## 用法

```bash
# 只读对账（生产建议每日跑一次）
manage.py media_audit

# 详细列出每个问题项
manage.py media_audit --verbose

# 清理孤儿对象（危险：只在确认这些 key 不该存在时执行）
manage.py media_audit --prune-orphans --no-dry-run
```

退出码：发现任何问题 → 1（便于 cron / 监控告警）；全部通过 → 0。
"""
import logging
import re

from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.media import storage
from apps.media.models import MediaObject

logger = logging.getLogger(__name__)

# 唯一合法的正式媒体 key 形态。**改动它等于改存储契约**，必须同步
# docs/architecture/media-storage-expiration.md 与 storage.py 的 key 构造函数。
MEDIA_KEY_RE = re.compile(
    r"^media/(image|voice|video|file|emoji)/([0-9a-f]{32})/(original|thumbnail|waveform)$"
)
TMP_KEY_RE = re.compile(r"^tmp/[A-Za-z0-9._-]+$")


class Command(BaseCommand):
    help = "媒体存储一致性审计：DB 声明 vs 对象存储实际（只读，可选清理孤儿）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--verbose", action="store_true", help="逐条列出问题项"
        )
        parser.add_argument(
            "--prune-orphans",
            action="store_true",
            help="删除没有任何 DB 记录引用的正式媒体对象（须配合 --no-dry-run）",
        )
        parser.add_argument(
            "--no-dry-run",
            action="store_true",
            help="真正执行 --prune-orphans（默认只预览）",
        )
        parser.add_argument(
            "--max-report", type=int, default=50, help="每类最多列出的条数（默认 50）"
        )

    def handle(self, *args, **options):
        store = storage.get_storage()
        verbose = options["verbose"]
        max_report = options["max_report"]
        bucket = getattr(store, "_bucket", "?")
        self.stdout.write(f"[audit] backend={type(store).__name__} bucket={bucket}")

        # ---------- 1. DB 声明集合 ----------
        db_keys: dict[str, list[tuple[str, str, bool]]] = {}
        for media in MediaObject.objects.all().iterator(chunk_size=2000):
            for field in ("storage_path", "thumbnail_path", "waveform_path"):
                key = getattr(media, field) or ""
                if not key:
                    continue
                db_keys.setdefault(key, []).append(
                    (media.media_id, field, media.expired_at is not None)
                )
        self.stdout.write(f"[audit] DB 声明 key 数 = {len(db_keys)}")

        # ---------- 2. 对象存储实际集合 ----------
        remote_keys = self._list_remote_keys(store)
        self.stdout.write(f"[audit] 对象存储 key 数 = {len(remote_keys)}")

        # ---------- 3. 三类问题 ----------
        missing: list[str] = []
        for key, owners in db_keys.items():
            if key in remote_keys:
                continue
            # 已完全过期的媒体，对象本就应当不存在 —— 不算问题
            if all(expired for _mid, _f, expired in owners):
                continue
            missing.append(key)

        orphans: list[str] = []
        nonstandard: list[str] = []
        for key in remote_keys:
            if TMP_KEY_RE.match(key):
                continue
            if not MEDIA_KEY_RE.match(key):
                nonstandard.append(key)
                continue
            if key not in db_keys:
                orphans.append(key)

        # ---------- 4. 报告 ----------
        ok = not (missing or orphans or nonstandard)

        self.stdout.write("")
        self.stdout.write(f"[audit] 缺失（DB 有、对象无，且未完全过期）= {len(missing)}")
        self._dump(missing, verbose, max_report)
        self.stdout.write(f"[audit] 孤儿（对象有、DB 无引用）= {len(orphans)}")
        self._dump(orphans, verbose, max_report)
        self.stdout.write(f"[audit] 非标准 key（违反存储契约）= {len(nonstandard)}")
        self._dump(nonstandard, verbose, max_report)

        if ok:
            self.stdout.write(
                self.style.SUCCESS("[audit] PASS：DB 与对象存储完全一致，key 结构合规")
            )
            return

        # ---------- 5. 可选：清理孤儿 ----------
        if options["prune_orphans"] and orphans:
            dry = not options["no_dry_run"]
            if dry:
                self.stdout.write(
                    self.style.WARNING(
                        f"[audit] 预览：将删除 {len(orphans)} 个孤儿对象（加 --no-dry-run 才真删）"
                    )
                )
            else:
                removed = 0
                for key in orphans:
                    store.delete(key)
                    removed += 1
                self.stdout.write(
                    self.style.WARNING(f"[audit] 已删除 {removed} 个孤儿对象")
                )

        # 退出码非 0 ⇒ cron / 监控可据此告警
        raise SystemExit(1)

    # ------------------------------------------------------------------

    def _list_remote_keys(self, store) -> set[str]:
        """列出桶内全部 key；后端不支持列举时显式失败（不伪装成空集）。"""
        try:
            return set(store.list_keys())
        except NotImplementedError:
            self.stderr.write(
                self.style.ERROR(
                    "[audit] 当前存储后端不支持列举；请指向真实 S3/MinIO 后重跑"
                )
            )
            raise SystemExit(2)

    def _dump(self, items: list[str], verbose: bool, max_report: int) -> None:
        if not items:
            return
        shown = items if verbose else items[: max_report]
        for key in shown:
            self.stdout.write(f"    - {key}")
        if not verbose and len(items) > max_report:
            self.stdout.write(f"    …… 另有 {len(items) - max_report} 条（--verbose 全列）")
