"""清理过期上传会话/孤儿临时对象 + 聊天媒体两级过期（可选运维命令）。

继承 Elysium 手动启动纪律：不引入后台调度，运维手动/计划任务执行即可。

--include-active：连同未过期的 pending 会话一起清理。用于 complete 中途
崩溃（如旧版整块读内存 OOM）留下的残留——这类会话未过期、永远不会被
默认策略覆盖，会随重试持续堆积（2026-08-23 曾堆积 23GiB）。执行前提：
确认当前没有进行中的上传。

--expire-chat-media：聊天媒体分级过期（docs/architecture/media-storage-expiration.md）：
- 候选 = created_at 超该 kind 有效 TTL 且未完全过期（expired_at 为 null）且 status=READY；
- 保护集合 = 全量扫描七类永久保留引用（A1-A7：PostImage/EmojiItem/Comment 两种形态/
  Conversation.avatar/User.avatar/LiveChannel.cover，见
  docs/architecture/media-retention-boundaries.md §3），被任一保护类引用的媒体永不过期；
- 表情包（kind=emoji）显式跳过，永不过期（边界文档 §6.1 Q1）；
- 可过期 = 候选 - 保护（含无任何引用的孤儿媒体）；
- 图片两级：阶段 1（7 天）删 storage_path（original）标记 original_expired_at；
  阶段 2（30 天）删 thumbnail/waveform 标记 expired_at；
- 语音/文件/视频单级：TTL（默认 7 天）到期直接删全部对象标记 expired_at；
- 幂等可重跑：已标记的媒体不再重复处理；--no-delete 预览不删对象不标记。
"""
import logging
import re
from datetime import timedelta

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from apps.media import storage
from apps.media.models import MediaObject, MediaUploadSession

logger = logging.getLogger(__name__)

# 头像/封面类字段（Conversation.avatar / User.avatar / LiveChannel.cover）存的是
# /api/v1/media/{id}/content 形式 URL，解析出 media_id 再比对。
_AVATAR_MEDIA_RE = re.compile(r"/api/v1/media/([^/]+)/content")


def _collect_content_url_media_ids(model, field: str, protected: set[str]) -> None:
    """扫描某个 model 的 content URL 字段，把解析出的 media_id 并入 protected。

    A5（User.avatar）/ A6（Conversation.avatar）/ A7（LiveChannel.cover）共用同一
    引用形态；新增同类引用时复用本函数，避免又漏一类（边界文档 §8 约束 2）。
    """
    # 全量扫描（不得分页截断：漏判 = 资产被删），但用 iterator 分块取，
    # 避免用户表/会话表较大时把整列一次性读进内存。
    values = model.objects.exclude(**{field: ""}).values_list(field, flat=True)
    for url in values.iterator(chunk_size=2000):
        match = _AVATAR_MEDIA_RE.search(url or "")
        if match:
            protected.add(match.group(1))


def _protected_media_ids() -> set[str]:
    """全量扫描七类资产引用（A1-A7），返回被引用的 media_id 集合。

    漏判会导致资产类媒体被误删——这是本方案最高风险点，必须全量扫描。

    引用清单（唯一事实源 docs/architecture/media-retention-boundaries.md §3）：
    - A1 PostImage.media（FK）；A2 EmojiItem.media（FK）；
    - A3 Comment.media_id（字符串）；A4 Comment.images（JSON 数组）；
    - A5 User.avatar、A6 Conversation.avatar、A7 LiveChannel.cover（content URL）。

    注意：E1-E4（Message / Danmaku / VoiceChatMessage）是「可过期」聊天类，
    **不得**加入本集合（边界文档 §4）。
    """
    from apps.accounts.models import User
    from apps.chat.models import Conversation
    from apps.emoji.models import EmojiItem
    from apps.live.models import LiveChannel
    from apps.posts.models import Comment, PostImage

    protected: set[str] = set()
    # FK 引用：FK 列存的是 MediaObject.id，需经 media__media_id 取对外稳定指纹
    protected.update(str(mid) for mid in PostImage.objects.values_list("media__media_id", flat=True))
    protected.update(str(mid) for mid in EmojiItem.objects.values_list("media__media_id", flat=True))
    # Comment 两种形态：media_id 列 + images JSON 数组（图文同发）
    protected.update(
        str(mid) for mid in Comment.objects.exclude(media_id="").values_list("media_id", flat=True)
    )
    for images in Comment.objects.values_list("images", flat=True):
        for mid in images or []:
            if mid:
                protected.add(str(mid))
    # 头像/封面类 content URL 引用（A5/A6/A7）：解析 URL 提取 media_id
    _collect_content_url_media_ids(User, "avatar", protected)  # A5 用户头像
    _collect_content_url_media_ids(Conversation, "avatar", protected)  # A6 群头像
    _collect_content_url_media_ids(LiveChannel, "cover", protected)  # A7 直播间封面
    return protected


class Command(BaseCommand):
    help = "清理过期上传会话与孤儿临时对象；--expire-chat-media 执行聊天媒体两级过期"

    def add_arguments(self, parser):
        parser.add_argument("--no-delete", action="store_true", help="仅列出，不删除")
        parser.add_argument(
            "--include-active",
            action="store_true",
            help="连同未过期的 pending 会话一起清理（确认无进行中上传时使用）",
        )
        parser.add_argument(
            "--expire-chat-media",
            action="store_true",
            help="执行聊天媒体分级过期（图片 7 天删原图留缩略图/30 天完全过期；语音/文件/视频 7 天直接删除；资产类豁免）",
        )

    def handle(self, *args, **options):
        now = timezone.now()
        store = storage.get_storage()
        count = 0
        pending = MediaUploadSession.objects.filter(
            status=MediaUploadSession.STATUS_PENDING
        )
        expired = pending if options["include_active"] else pending.filter(
            expires_at__lt=now
        )
        for session in expired[:2000]:
            count += 1
            key = storage.tmp_key(session.upload_id)
            if store.exists(key):
                self.stdout.write(f"[media] 清理临时对象 {key}")
                if not options["no_delete"]:
                    store.delete(key)
            if not options["no_delete"]:
                session.status = MediaUploadSession.STATUS_EXPIRED
                session.save(update_fields=["status"])
        self.stdout.write(f"[media] 已处理 {count} 个上传会话")

        if options["expire_chat_media"]:
            self._expire_chat_media(now, store, no_delete=options["no_delete"])

    def _expire_chat_media(self, now, store, no_delete: bool) -> None:
        """聊天媒体过期（幂等可重跑）。

        按 kind 分派（docs/architecture/media-storage-expiration.md）：
        - **两级**（image / video）：ORIGINAL_TTL 删原对象、保留派生封面
          （图片=缩略图；视频=首帧海报帧），FULL_TTL 删全部对象完全过期；
        - **单级**（voice / file）：TTL 到期直接删除全部对象（无派生封面）。

        2026-10-29 变更（用户拍板）：video 由单级改为两级 —— 视频本体 7 天过期，
        海报帧与图片缩略图同寿命（30 天），聊天里 7 天后仍显示封面而非灰块。

        另含**卡死兜底**：status=processing 超过 MEDIA_PROCESSING_STALE_HOURS
        仍未就绪的媒体先转 failed 再纳入过期，避免中途崩溃的行永久占存储。
        """
        two_stage = {
            MediaObject.KIND_IMAGE: (
                int(getattr(settings, "MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS", 7)),
                int(getattr(settings, "MEDIA_CHAT_IMAGE_FULL_TTL_DAYS", 30)),
            ),
            MediaObject.KIND_VIDEO: (
                int(getattr(settings, "MEDIA_CHAT_VIDEO_TTL_DAYS", 7)),
                int(
                    getattr(
                        settings,
                        "MEDIA_CHAT_VIDEO_FULL_TTL_DAYS",
                        getattr(settings, "MEDIA_CHAT_IMAGE_FULL_TTL_DAYS", 30),
                    )
                ),
            ),
        }
        single_ttls = {
            MediaObject.KIND_VOICE: int(getattr(settings, "MEDIA_CHAT_VOICE_TTL_DAYS", 7)),
            MediaObject.KIND_FILE: int(getattr(settings, "MEDIA_CHAT_FILE_TTL_DAYS", 7)),
        }
        # 配置校验：两级媒体的 FULL 必须 >= ORIGINAL（否则阶段 2 先于阶段 1 触发，
        # 等于没有两级窗口，属显式配置错误而非静默容忍）。
        for kind, (original_ttl, full_ttl) in two_stage.items():
            if full_ttl > 0 and original_ttl > 0 and full_ttl < original_ttl:
                raise CommandError(
                    f"{kind}: FULL_TTL_DAYS({full_ttl}) < ORIGINAL_TTL_DAYS({original_ttl})，"
                    "配置错误"
                )
        effective_ttls = [
            t
            for pair in two_stage.values()
            for t in pair
            if t > 0
        ] + [t for t in single_ttls.values() if t > 0]
        if not effective_ttls:
            self.stdout.write("[media] 聊天媒体过期均已禁用（TTL<=0），无动作")
            return

        # 卡死兜底：processing 超时先转 failed（--no-delete 时只统计不落库）
        stale_hours = int(getattr(settings, "MEDIA_PROCESSING_STALE_HOURS", 24))
        stale_failed = 0
        if stale_hours > 0:
            stale_qs = MediaObject.objects.filter(
                status=MediaObject.STATUS_PROCESSING,
                created_at__lt=now - timedelta(hours=stale_hours),
                expired_at__isnull=True,
            )
            stale_failed = stale_qs.count()
            if stale_failed and not no_delete:
                stale_qs.update(status=MediaObject.STATUS_FAILED)
            if stale_failed:
                self.stdout.write(
                    f"[media] 卡死兜底：{stale_failed} 个 processing 超过 {stale_hours}h"
                    f"{'（预览，未落库）' if no_delete else ' 已转 failed'}"
                )

        # 候选：created_at 超任一有效 TTL、未完全过期（expired_at 为 null），
        # 且（已就绪 或 卡死转失败的）。failed 不参与正常流程，只承接上面的兜底。
        oldest_ttl = min(effective_ttls)
        candidates = list(
            MediaObject.objects.filter(
                created_at__lt=now - timedelta(days=oldest_ttl),
                status__in=(MediaObject.STATUS_READY, MediaObject.STATUS_FAILED),
                expired_at__isnull=True,
            )
        )
        if not candidates:
            self.stdout.write("[media] 无可过期的聊天媒体")
            return

        protected = _protected_media_ids()
        stage1_count = stage2_count = emoji_skipped = 0
        for media in candidates:
            if media.media_id in protected:
                continue
            # 表情包永不过期（边界文档 §6.1 Q1）：必须显式跳过，不能依赖
            # 「不在 single_ttls 表里所以恰好被跳过」的隐式行为——否则下次重构
            # TTL 表时，kind=emoji 会被当成单级媒体 7 天删除。
            if media.kind == MediaObject.KIND_EMOJI:
                emoji_skipped += 1
                continue
            if media.kind in two_stage:
                original_ttl, full_ttl = two_stage[media.kind]
                stage1_count, stage2_count = self._expire_two_stage(
                    media, now, store, no_delete,
                    original_ttl, full_ttl, stage1_count, stage2_count,
                )
            else:
                ttl = single_ttls.get(media.kind, 0)
                if ttl > 0 and media.created_at < now - timedelta(days=ttl):
                    self._delete_all_objects(media, store, no_delete, stage="单级")
                    if not no_delete:
                        media.expired_at = now
                        # 同阶段 2：对象已删 ⇒ DB 不再声明它们
                        media.storage_path = ""
                        media.thumbnail_path = ""
                        media.waveform_path = ""
                        media.save(
                            update_fields=[
                                "expired_at",
                                "storage_path",
                                "thumbnail_path",
                                "waveform_path",
                            ]
                        )
                    stage2_count += 1
        self.stdout.write(
            f"[media] 聊天媒体过期完成：阶段1 {stage1_count} 个，阶段2 {stage2_count} 个"
            f"（保护 {len(protected)} 个引用，候选 {len(candidates)} 个，"
            f"表情包跳过 {emoji_skipped} 个，卡死兜底 {stale_failed} 个）"
        )

    def _expire_two_stage(self, media, now, store, no_delete, original_ttl, full_ttl,
                          stage1_count, stage2_count):
        """两级过期（image / video 共用）：阶段 1 删原对象留封面；阶段 2 全删。

        - 图片：阶段 1 删 original、保留 thumbnail（缩略图）；
        - 视频：阶段 1 删 original（视频本体）、保留 thumbnail（首帧海报帧）；
          waveform 只有语音才有，两级媒体上恒为空，一并由阶段 2 兜底删除。
        """
        # 阶段 2 优先判定：完全过期（超 FULL_TTL）→ 删全部对象（含未删的
        # original 与封面），标记 expired_at；original_expired_at 未标记时一并标记
        # （保留已标记的首次阶段 1 时间，审计可追溯）。
        if full_ttl > 0 and media.created_at < now - timedelta(days=full_ttl):
            self._delete_all_objects(media, store, no_delete, stage="阶段2")
            if not no_delete:
                # 三个 *_path 一并置空：DB 只声明「确实存在的对象」（见 media_audit）
                update_fields = ["expired_at", "storage_path", "thumbnail_path", "waveform_path"]
                if media.original_expired_at is None:
                    media.original_expired_at = now
                    update_fields.append("original_expired_at")
                media.expired_at = now
                media.storage_path = ""
                media.thumbnail_path = ""
                media.waveform_path = ""
                media.save(update_fields=update_fields)
            stage2_count += 1
            return stage1_count, stage2_count
        # 阶段 1：删原对象（图片=原图 / 视频=视频本体），保留 thumbnail 封面
        # （original_expired_at 非空 = 已执行，幂等跳过）。
        #
        # ⚠️ 删完后必须把 storage_path **置空**：DB 的 *_path 是「对象存在」的权威
        # 声明，阶段 1 的语义恰恰是「原对象已不存在」。不置空的话媒体审计
        # （manage.py media_audit）会把每一次**正常**过期都报成「缺失」，护栏立刻
        # 变成噪音（2026-10-29 实测踩到）。阶段 2 同理见 _delete_all_objects。
        if original_ttl > 0 and media.created_at < now - timedelta(days=original_ttl):
            if media.original_expired_at is None:
                if media.storage_path and store.exists(media.storage_path):
                    self.stdout.write(
                        f"[media] 过期 {media.media_id} 阶段1 删除原对象 {media.storage_path}"
                    )
                    if not no_delete:
                        store.delete(media.storage_path)
                if not no_delete:
                    media.original_expired_at = now
                    media.storage_path = ""
                    media.save(update_fields=["original_expired_at", "storage_path"])
                stage1_count += 1
        return stage1_count, stage2_count

    def _delete_all_objects(self, media, store, no_delete: bool, stage: str) -> None:
        """删除媒体全部对象（original + thumbnail + waveform），逐 key 输出日志。

        **只删对象，不改 DB**（DB 标记由调用方负责）。调用方（阶段 2 / 单级）
        必须在标记 `expired_at` 的同时把三个 *_path 置空 —— 否则 DB 会继续声明
        已被删除的对象，媒体审计每次都会报「缺失」（2026-10-29 事故修复时暴露）。
        """
        for key in (media.storage_path, media.thumbnail_path, media.waveform_path):
            if key and store.exists(key):
                self.stdout.write(f"[media] 过期 {media.media_id} {stage} 删除 {key}")
                if not no_delete:
                    store.delete(key)
