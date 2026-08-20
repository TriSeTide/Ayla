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
    """评论对外序列化（media_id + media descriptor，同 chat.Message 约定）。"""

    id = serializers.IntegerField(read_only=True)
    post_id = serializers.CharField(read_only=True)
    author = serializers.SerializerMethodField()
    author_id = serializers.CharField(read_only=True)
    reply_to = serializers.SerializerMethodField()
    is_author = serializers.SerializerMethodField()
    media = serializers.SerializerMethodField()

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

    def get_media(self, obj):
        """media descriptor：media_id 引用 MediaObject 则返回 descriptor，否则 None。"""
        if not obj.media_id:
            return None
        from apps.media.models import MediaObject

        media = MediaObject.objects.filter(media_id=obj.media_id).first()
        if media is None:
            return None
        return MediaObjectSerializer(media, context=self.context).data


class CreatePostSerializer(serializers.Serializer):
    """发帖入参：body 必填，images 为 media_id 列表（≤9）。"""

    MAX_IMAGES = 9

    title = serializers.CharField(required=False, allow_blank=True, max_length=128, default="")
    body = serializers.CharField(required=True, max_length=10000)
    visibility = serializers.ChoiceField(choices=Visibility.choices, required=False)
    group = serializers.CharField(required=False, allow_null=True, default=None)
    allowed_group_ids = serializers.ListField(
        child=serializers.CharField(max_length=32), required=False, default=list
    )
    images = serializers.ListField(
        child=serializers.CharField(max_length=64), required=False, default=list
    )

    def validate_group(self, value):
        if value in (None, "", "null"):
            return None
        return value

    def validate_images(self, value):
        if len(value) > self.MAX_IMAGES:
            raise serializers.ValidationError(f"最多 {self.MAX_IMAGES} 张图片")
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
            if media.kind != MediaObject.KIND_IMAGE:
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
    """发评论入参：body 必填，reply_to 可选（须在本帖内），media_id 可选（图片评论）。"""

    body = serializers.CharField(required=True, max_length=2000)
    reply_to = serializers.IntegerField(required=False, allow_null=True, default=None)
    media_id = serializers.CharField(
        max_length=64, required=False, allow_blank=True, allow_null=True, default=None
    )

    def validate_body(self, value):
        value = (value or "").strip()
        if not value:
            raise serializers.ValidationError("评论内容不能为空")
        return value

    def validate_media_id(self, value):
        return value or None

    def validate(self, attrs):
        media_id = attrs.get("media_id")
        if not media_id:
            return attrs
        from apps.media.models import MediaObject
        from apps.media.services import can_access_media

        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None:
            raise serializers.ValidationError({"media_id": "media_not_found"})
        if media.status != MediaObject.STATUS_READY:
            raise serializers.ValidationError({"media_id": "media_not_ready"})
        if media.kind != MediaObject.KIND_IMAGE:
            raise serializers.ValidationError({"media_id": "media_type_mismatch"})
        # 越权是授权问题 → 403，与 400 类校验错误区分（同 CreateMessageSerializer）
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is not None and not can_access_media(user, media):
            raise PermissionDenied({"media_id": "media_access_denied"})
        return attrs
