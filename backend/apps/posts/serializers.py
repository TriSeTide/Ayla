"""
帖子序列化（S3，开发文档 §1.3）。

- 输出：Post（author/author_id + images[] + comment_count + is_author）、
  Comment（author/author_id + reply_to + is_author）、PostImage（media descriptor）；
- 输入：CreatePostSerializer（body 必填、images ≤9、图片合法性校验）、
  UpdatePostSerializer、CreateCommentSerializer（body 必填、reply_to 可选）。

图片校验语义与 chat.CreateMessageSerializer 一致：media 存在 + READY + kind=image +
调用方有访问权；越权走 PermissionDenied（403），与 400 类校验错误区分。
"""
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.accounts.serializers import UserPublicSerializer
from apps.common.visibility import Visibility
from apps.media.serializers import MediaObjectSerializer

from .models import Comment, Post, PostImage


class PostImageSerializer(serializers.ModelSerializer):
    """帖子配图：media 输出完整 descriptor（含缩略图路径）。"""

    id = serializers.IntegerField(read_only=True)
    media = serializers.SerializerMethodField()

    class Meta:
        model = PostImage
        fields = ["id", "media", "order"]
        read_only_fields = fields

    def get_media(self, obj):
        if obj.media_id is None:
            return None
        return MediaObjectSerializer(obj.media, context=self.context).data


class PostSerializer(serializers.ModelSerializer):
    """帖子对外序列化：author 用 UserPublicSerializer，group/group_name 同 live/voice。"""

    id = serializers.IntegerField(read_only=True)
    author = serializers.SerializerMethodField()
    author_id = serializers.CharField(source="owner_id", read_only=True)
    visibility = serializers.CharField(read_only=True)
    group = serializers.CharField(source="group_id", read_only=True, default=None)
    group_name = serializers.CharField(source="group.title", read_only=True, default=None)
    images = PostImageSerializer(many=True, read_only=True)
    comment_count = serializers.SerializerMethodField()
    is_author = serializers.SerializerMethodField()
    allowed_group_ids = serializers.SerializerMethodField()
    allowed_group_names = serializers.SerializerMethodField()

    def get_allowed_group_ids(self, obj):
        return [str(group_id) for group_id in obj.allowed_groups.values_list("id", flat=True)]

    def get_allowed_group_names(self, obj):
        """返回所有可见群的名称列表，用于显示多个群标签"""
        return list(obj.allowed_groups.values_list("title", flat=True))

    class Meta:
        model = Post
        fields = [
            "id",
            "author",
            "author_id",
            "title",
            "body",
            "visibility",
            "group",
            "group_name",
            "allowed_group_ids",
            "allowed_group_names",
            "images",
            "comment_count",
            "is_author",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_author(self, obj):
        return UserPublicSerializer(obj.owner, context=self.context).data

    def get_comment_count(self, obj) -> int:
        if (
            hasattr(obj, "_prefetched_objects_cache")
            and "comments" in obj._prefetched_objects_cache
        ):
            return len(obj._prefetched_objects_cache["comments"])
        return obj.comments.count()

    def get_is_author(self, obj) -> bool:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        return bool(user and user.is_authenticated and user.id == obj.owner_id)


class CommentSerializer(serializers.ModelSerializer):
    """评论对外序列化（media_id + media descriptor + images[] 图文同发列表）。"""

    id = serializers.IntegerField(read_only=True)
    post_id = serializers.CharField(read_only=True)
    author = serializers.SerializerMethodField()
    author_id = serializers.CharField(read_only=True)
    reply_to = serializers.SerializerMethodField()
    is_author = serializers.SerializerMethodField()
    media = serializers.SerializerMethodField()
    images = serializers.SerializerMethodField()

    class Meta:
        model = Comment
        fields = [
            "id",
            "post_id",
            "author",
            "author_id",
            "body",
            "media_id",
            "media",
            "images",
            "reply_to",
            "is_author",
            "created_at",
        ]
        read_only_fields = fields

    def get_author(self, obj):
        return UserPublicSerializer(obj.author, context=self.context).data

    def get_reply_to(self, obj):
        return str(obj.reply_to_id) if obj.reply_to_id else None

    def get_is_author(self, obj) -> bool:
        request = self.context.get("request")
        user = getattr(request, "user", None)
        return bool(user and user.is_authenticated and user.id == obj.author_id)

    def _media_descriptor(self, media_id):
        from apps.media.models import MediaObject

        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None:
            return None
        return MediaObjectSerializer(media, context=self.context).data

    def get_media(self, obj):
        """历史兼容：首个媒体 descriptor（media_id 或 images 首个）。"""
        target = obj.media_id or (obj.images[0] if obj.images else None)
        if not target:
            return None
        return self._media_descriptor(target)

    def get_images(self, obj):
        """图文同发的全部媒体 descriptor 列表（含旧 media_id 单图）。"""
        ids = list(obj.images or [])
        if obj.media_id and obj.media_id not in ids:
            ids.insert(0, obj.media_id)
        out = []
        for mid in ids:
            d = self._media_descriptor(mid)
            if d is not None:
                out.append(d)
        return out


class CreatePostSerializer(serializers.Serializer):
    """发帖入参：title/body 必填，images 为 media_id 列表（≤9；图片或视频）。"""

    MAX_IMAGES = 9
    ALLOWED_KINDS = ("image", "video")

    title = serializers.CharField(required=True, allow_blank=False, max_length=128)
    body = serializers.CharField(required=True, max_length=10000)
    visibility = serializers.ChoiceField(choices=Visibility.choices, required=False)
    group = serializers.CharField(required=False, allow_null=True, default=None)
    allowed_group_ids = serializers.ListField(
        child=serializers.CharField(max_length=32), required=False, default=list
    )
    # 字段名沿用 images（历史契约）；语义已扩展为帖子媒体列表（图片/视频）
    images = serializers.ListField(
        child=serializers.CharField(max_length=64), required=False, default=list
    )

    def validate_group(self, value):
        if value in (None, "", "null"):
            return None
        return value

    def validate_images(self, value):
        if len(value) > self.MAX_IMAGES:
            raise serializers.ValidationError(f"最多 {self.MAX_IMAGES} 个媒体")
        return value

    def validate(self, attrs):
        from apps.media.models import MediaObject
        from apps.media.services import can_access_media

        request = self.context.get("request")
        user = getattr(request, "user", None)
        for media_id in attrs.get("images") or []:
            media = MediaObject.objects.filter(media_id=media_id).first()
            if media is None:
                raise serializers.ValidationError({"images": "media_not_found"})
            if media.status != MediaObject.STATUS_READY:
                raise serializers.ValidationError({"images": "media_not_ready"})
            if media.kind not in (MediaObject.KIND_IMAGE, MediaObject.KIND_VIDEO):
                raise serializers.ValidationError({"images": "media_type_mismatch"})
            if user is not None and not can_access_media(user, media):
                raise PermissionDenied({"images": "media_access_denied"})
        return attrs


class UpdatePostSerializer(serializers.Serializer):
    """编辑帖子：内容与可见性均可变更。"""

    title = serializers.CharField(required=False, allow_blank=True, max_length=128)
    body = serializers.CharField(required=False, max_length=10000)
    visibility = serializers.ChoiceField(choices=Visibility.choices, required=False)
    group = serializers.CharField(required=False, allow_null=True)
    allowed_group_ids = serializers.ListField(
        child=serializers.CharField(max_length=32), required=False
    )

    def validate(self, attrs):
        if not attrs:
            raise serializers.ValidationError("至少提供 title 或 body")
        if "body" in attrs and not (attrs["body"] or "").strip():
            raise serializers.ValidationError({"body": "正文不能为空"})
        return attrs


class CreateCommentSerializer(serializers.Serializer):
    """发评论入参：body 可选（有图片时空白允许），reply_to 可选，images 图文同发（≤4）。

    兼容旧契约：media_id 单图仍接受（等价 images=[media_id]）。
    """

    MAX_IMAGES = 4
    ALLOWED_KINDS = ("image", "video")

    body = serializers.CharField(required=False, max_length=2000, allow_blank=True, default="")
    reply_to = serializers.IntegerField(required=False, allow_null=True, default=None)
    media_id = serializers.CharField(
        max_length=64, required=False, allow_blank=True, allow_null=True, default=None
    )
    images = serializers.ListField(
        child=serializers.CharField(max_length=64), required=False, default=list
    )

    def validate_body(self, value):
        return (value or "").strip()

    def validate_media_id(self, value):
        return value or None

    def validate_images(self, value):
        if len(value) > self.MAX_IMAGES:
            raise serializers.ValidationError(f"最多 {self.MAX_IMAGES} 张图片")
        return list(dict.fromkeys(value))

    def validate(self, attrs):
        from apps.media.models import MediaObject
        from apps.media.services import can_access_media

        request = self.context.get("request")
        user = getattr(request, "user", None)

        # 合并新旧两种传法：images 优先，media_id 视为单图（去重保序）
        ids = list(dict.fromkeys((attrs.get("images") or []) + ([attrs["media_id"]] if attrs.get("media_id") else [])))
        attrs["images"] = ids
        if not ids and not (attrs.get("body") or "").strip():
            raise serializers.ValidationError("评论内容不能为空")

        for media_id in ids:
            media = MediaObject.objects.filter(media_id=media_id).first()
            if media is None:
                raise serializers.ValidationError({"media_id": "media_not_found"})
            if media.status != MediaObject.STATUS_READY:
                raise serializers.ValidationError({"media_id": "media_not_ready"})
            if media.kind not in (MediaObject.KIND_IMAGE, MediaObject.KIND_VIDEO):
                raise serializers.ValidationError({"media_id": "media_type_mismatch"})
            # 越权是授权问题 → 403，与 400 类校验错误区分（同 CreateMessageSerializer）
            if user is not None and not can_access_media(user, media):
                raise PermissionDenied({"media_id": "media_access_denied"})
        return attrs
