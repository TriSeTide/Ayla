"""
媒体域模型（M4-3，严格按开发文档第 4 节媒体域 + 步骤文件 3.1/3.2 落库）。

- MediaObject：媒体对象（media_id 稳定 uuid 对外指纹，content_hash 完整性校验）；
- MediaUploadSession：受控上传会话（三步上传的握手指纹）。

硬约束继承 AGENTS.md / 阶段三 §10：
- `media_id` 唯一是硬约束（对外稳定指纹，重复即冲突，绝不由 services 兜底）；
- `upload_id` 唯一是硬约束；
- 对外序列化只给 descriptor，不暴露 storage_path（见 serializers.py）。
"""
from django.conf import settings
from django.db import models
from django.utils import timezone
from datetime import timedelta


def default_expires_at():
    """上传会话默认过期时间（与 create_upload_session 的 TTL 一致）。"""
    ttl = int(getattr(settings, "MEDIA_TMP_TTL_SECONDS", 600))
    return timezone.now() + timedelta(seconds=ttl)


class MediaObject(models.Model):
    """媒体对象。"""

    KIND_IMAGE = "image"
    KIND_VOICE = "voice"
    KIND_FILE = "file"
    KIND_EMOJI = "emoji"
    KIND_CHOICES = [
        (KIND_IMAGE, "图片"),
        (KIND_VOICE, "语音"),
        (KIND_FILE, "文件"),
        (KIND_EMOJI, "表情"),
    ]

    STATUS_PROCESSING = "processing"
    STATUS_READY = "ready"
    STATUS_FAILED = "failed"
    STATUS_CHOICES = [
        (STATUS_PROCESSING, "处理中"),
        (STATUS_READY, "就绪"),
        (STATUS_FAILED, "失败"),
    ]

    id = models.AutoField(primary_key=True)
    media_id = models.CharField("媒体ID", max_length=64, unique=True, db_index=True)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="media_objects",
        on_delete=models.CASCADE,
        db_index=True,
    )
    kind = models.CharField("类型", max_length=16, choices=KIND_CHOICES, db_index=True)
    content_hash = models.CharField("内容哈希", max_length=64, blank=True, default="")
    mime_type = models.CharField("MIME 类型", max_length=128, blank=True, default="")
    size = models.PositiveBigIntegerField("大小", default=0)
    storage_path = models.CharField("存储路径", max_length=256, blank=True, default="")
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PROCESSING
    )
    # 补充字段（接口驱动：媒体 descriptor 必需；README 已注明）
    width = models.PositiveIntegerField("宽度", null=True, blank=True)
    height = models.PositiveIntegerField("高度", null=True, blank=True)
    duration = models.FloatField("时长", null=True, blank=True)
    thumbnail_path = models.CharField("缩略图路径", max_length=256, blank=True, default="")
    waveform_path = models.CharField("波形图路径", max_length=256, blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True, db_index=True)

    class Meta:
        db_table = "media_objects"
        verbose_name = "媒体对象"
        verbose_name_plural = "媒体对象"

    def __str__(self) -> str:
        return f"{self.kind}:{self.media_id}"

    @property
    def has_thumbnail(self) -> bool:
        return bool(self.thumbnail_path)

    @property
    def has_waveform(self) -> bool:
        return bool(self.waveform_path)


class MediaUploadSession(models.Model):
    """受控上传会话（三步上传：创建 → PUT 二进制 → :complete）。"""

    KIND_CHOICES = MediaObject.KIND_CHOICES

    STATUS_PENDING = "pending"
    STATUS_COMPLETED = "completed"
    STATUS_EXPIRED = "expired"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待上传"),
        (STATUS_COMPLETED, "已完成"),
        (STATUS_EXPIRED, "已过期"),
    ]

    id = models.AutoField(primary_key=True)
    upload_id = models.CharField("上传ID", max_length=64, unique=True)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="media_upload_sessions",
        on_delete=models.CASCADE,
        db_index=True,
    )
    kind = models.CharField("类型", max_length=16, choices=KIND_CHOICES)
    expected_size = models.PositiveBigIntegerField("声明大小", default=0)
    mime_type = models.CharField("期望 MIME", max_length=128, blank=True, default="")
    status = models.CharField(
        "状态", max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING
    )
    # 幂等锚点：complete 成功后回填生成的 media_id（可空）。
    # 同一 upload_id 重复 complete 依据此字段返回同一 media_id，不重复建对象/不重复派生。
    media_id = models.CharField("完成后的媒体ID", max_length=64, blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True)
    expires_at = models.DateTimeField(
        "过期时间",
        db_index=True,
        # 默认 TTL 同 create_upload_session（settings.MEDIA_TMP_TTL_SECONDS）；
        # 允许直接 create 的测试/脚本不必手填过期时间
        default=default_expires_at,
    )

    class Meta:
        db_table = "media_upload_sessions"
        verbose_name = "上传会话"
        verbose_name_plural = "上传会话"
        indexes = [
            models.Index(fields=["owner", "status"], name="idx_upload_owner_status"),
        ]

    def __str__(self) -> str:
        return f"{self.kind}:{self.upload_id}:{self.status}"
