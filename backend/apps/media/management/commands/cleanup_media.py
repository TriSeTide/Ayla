"""清理过期上传会话/孤儿临时对象 + 聊天媒体两级过期（可选运维命令）。

继承 Elysium 手动启动纪律：不引入后台调度，运维手动/计划任务执行即可。

--include-active：连同未过期的 pending 会话一起清理。用于 complete 中途
崩溃（如旧版整块读内存 OOM）留下的残留——这类会话未过期、永远不会被
默认策略覆盖，会随重试持续堆积（2026-08-23 曾堆积 23GiB）。执行前提：
确认当前没有进行中的上传。

--expire-chat-media：聊天媒体分级过期（docs/architecture/media-storage-expiration.md）：
- 候选 = created_at 超该 kind 有效 TTL 且未完全过期（expired_at 为 null）且 status=READY；
- 保护集合 = 全量扫描五类永久保留引用（PostImage/EmojiItem/Comment 两种形态/
  Conversation.avatar），被任一保护类引用的媒体永不过期；
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

# Conversation.avatar 存的是 /api/v1/media/{id}/content 形式 URL，解析出 media_id 再比对
_AVATAR_MEDIA_RE = re.compile(r"/api/v1/media/([^/]+)/content")


def _protected_media_ids() -> set[str]:
    """全量扫描五类永久保留引用，返回被引用的 media_id 集合。

    漏判会导致资产类媒体被误删——这是本方案最高风险点，必须全量扫描。
    """
    from apps.chat.models import Conversation
    from apps.emoji.models import EmojiItem
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
    # Conversation.avatar：解析 content URL 提取 media_id
    for url in Conversation.objects.exclude(avatar="").values_list("avatar", flat=True):
        match = _AVATAR_MEDIA_RE.search(url or "")
        if match:
            protected.add(match.group(1))
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
        - image：两级——ORIGINAL_TTL 删原图留缩略图、FULL_TTL 完全过期；
        - voice/file/video：单级——TTL 到期直接删除全部对象（无缩略图阶段）。
        """
        image_original_ttl = int(getattr(settings, "MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS", 7))
        image_full_ttl = int(getattr(settings, "MEDIA_CHAT_IMAGE_FULL_TTL_DAYS", 30))
        single_ttls = {
            MediaObject.KIND_VOICE: int(getattr(settings, "MEDIA_CHAT_VOICE_TTL_DAYS", 7)),
            MediaObject.KIND_FILE: int(getattr(settings, "MEDIA_CHAT_FILE_TTL_DAYS", 7)),
            MediaObject.KIND_VIDEO: int(getattr(settings, "MEDIA_CHAT_VIDEO_TTL_DAYS", 7)),
        }
        if image_full_ttl > 0 and image_original_ttl > 0 and image_full_ttl < image_original_ttl:
            raise CommandError(
                f"MEDIA_CHAT_IMAGE_FULL_TTL_DAYS({image_full_ttl}) < "
                f"MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS({image_original_ttl})，配置错误"
            )
        effective_ttls = [
            t for t in [image_original_ttl, image_full_ttl, *single_ttls.values()] if t > 0
        ]
        if not effective_ttls:
            self.stdout.write("[media] 聊天媒体过期均已禁用（TTL<=0），无动作")
            return

        # 候选：created_at 超任一有效 TTL 且未完全过期（expired_at 为 null）且就绪
        oldest_ttl = min(effective_ttls)
        candidates = list(
            MediaObject.objects.filter(
                created_at__lt=now - timedelta(days=oldest_ttl),
                status=MediaObject.STATUS_READY,
                expired_at__isnull=True,
            )
        )
        if not candidates:
            self.stdout.write("[media] 无可过期的聊天媒体")
            return

        protected = _protected_media_ids()
        stage1_count = stage2_count = 0
        for media in candidates:
            if media.media_id in protected:
                continue
            if media.kind == MediaObject.KIND_IMAGE:
                stage1_count, stage2_count = self._expire_image(
                    media, now, store, no_delete,
                    image_original_ttl, image_full_ttl, stage1_count, stage2_count,
                )
            else:
                ttl = single_ttls.get(media.kind, 0)
                if ttl > 0 and media.created_at < now - timedelta(days=ttl):
                    self._delete_all_objects(media, store, no_delete, stage="单级")
                    if not no_delete:
                        media.expired_at = now
                        media.save(update_fields=["expired_at"])
                    stage2_count += 1
        self.stdout.write(
            f"[media] 聊天媒体过期完成：阶段1 {stage1_count} 个，阶段2 {stage2_count} 个"
            f"（保护 {len(protected)} 个引用，候选 {len(candidates)} 个）"
        )

    def _expire_image(self, media, now, store, no_delete, original_ttl, full_ttl,
                      stage1_count, stage2_count):
        """图片两级过期：阶段 1 删原图留缩略图；阶段 2 完全过期删全部对象。"""
        # 阶段 2 优先判定：完全过期（超 FULL_TTL）→ 删全部对象（含未删的
        # original），标记 expired_at；original_expired_at 未标记时一并标记
        # （保留已标记的首次阶段 1 时间，审计可追溯）。
        if full_ttl > 0 and media.created_at < now - timedelta(days=full_ttl):
            self._delete_all_objects(media, store, no_delete, stage="阶段2")
            if not no_delete:
                update_fields = ["expired_at"]
                if media.original_expired_at is None:
                    media.original_expired_at = now
                    update_fields.append("original_expired_at")
                media.expired_at = now
                media.save(update_fields=update_fields)
            stage2_count += 1
            return stage1_count, stage2_count
        # 阶段 1：删原图，留缩略图/波形（original_expired_at 非空 = 已执行，幂等跳过）
        if original_ttl > 0 and media.created_at < now - timedelta(days=original_ttl):
            if media.original_expired_at is None:
                if media.storage_path and store.exists(media.storage_path):
                    self.stdout.write(
                        f"[media] 过期 {media.media_id} 阶段1 删除原图 {media.storage_path}"
                    )
                    if not no_delete:
                        store.delete(media.storage_path)
                if not no_delete:
                    media.original_expired_at = now
                    media.save(update_fields=["original_expired_at"])
                stage1_count += 1
        return stage1_count, stage2_count

    def _delete_all_objects(self, media, store, no_delete: bool, stage: str) -> None:
        """删除媒体全部对象（original + thumbnail + waveform），逐 key 输出日志。"""
        for key in (media.storage_path, media.thumbnail_path, media.waveform_path):
            if key and store.exists(key):
                self.stdout.write(f"[media] 过期 {media.media_id} {stage} 删除 {key}")
                if not no_delete:
                    store.delete(key)
