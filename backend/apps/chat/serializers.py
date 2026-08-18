"""chat DRF 序列化器。"""
from django.contrib.auth import get_user_model
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.accounts.serializers import UserPublicSerializer

from .models import (
    Conversation,
    ConversationMember,
    GroupInvite,
    GroupJoinRequest,
    GroupMemberLeaveNotice,
    Message,
    MessageRead,
)

User = get_user_model()


class ConversationMemberSerializer(serializers.ModelSerializer):
    id = serializers.CharField(read_only=True, source="user.id")
    user = UserPublicSerializer(read_only=True)
    role = serializers.CharField(read_only=True)
    muted = serializers.BooleanField(read_only=True)

    class Meta:
        model = ConversationMember
        fields = ["id", "user", "role", "muted", "joined_at"]


class MessageSerializer(serializers.ModelSerializer):
    """消息对外序列化：id 转字符串，含 conversation_id/sender_id/seq/created_at。"""

    id = serializers.CharField(read_only=True)
    conversation_id = serializers.CharField(read_only=True)
    sender_id = serializers.CharField(read_only=True)
    reply_to = serializers.SerializerMethodField()
    type = serializers.CharField(read_only=True)
    status = serializers.CharField(read_only=True)
    seq = serializers.IntegerField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)
    # M4-3：media 从字符串 media_id 升级为 descriptor 对象（无引用为 null）
    media = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = [
            "id",
            "conversation_id",
            "sender_id",
            "type",
            "content",
            "media_id",
            "media",
            "reply_to",
            "status",
            "seq",
            "created_at",
        ]
        read_only_fields = fields

    def get_reply_to(self, obj):
        return str(obj.reply_to_id) if obj.reply_to_id else None

    def get_media(self, obj):
        """media descriptor：media_id 引用的 MediaObjectSerializer（无引用为 null）。"""
        media_id = obj.media_id
        if not media_id:
            return None
        from apps.media.models import MediaObject
        from apps.media.serializers import MediaObjectSerializer

        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None:
            return None
        return MediaObjectSerializer(media, context=self.context).data


class ConversationSerializer(serializers.ModelSerializer):
    """会话序列化：id(str), type, title, owner_id, members[], my_role, unread_count。"""

    id = serializers.CharField(read_only=True)
    owner_id = serializers.CharField(read_only=True)
    members = ConversationMemberSerializer(many=True, read_only=True)
    my_role = serializers.SerializerMethodField()
    unread_count = serializers.SerializerMethodField()
    member_count = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            "id",
            "type",
            "title",
            "announcement",
            "avatar",
            "join_policy",
            "owner_id",
            "members",
            "my_role",
            "member_count",
            "unread_count",
            "created_at",
        ]
        read_only_fields = fields

    def get_my_role(self, obj) -> str:
        request = self.context.get("request")
        if request and hasattr(request, "user"):
            try:
                return ConversationMember.objects.get(
                    conversation=obj, user=request.user
                ).role
            except ConversationMember.DoesNotExist:
                return None
        return None

    def get_member_count(self, obj) -> int:
        return obj.members.count()

    def get_unread_count(self, obj) -> int:
        request = self.context.get("request")
        if not request or not hasattr(request, "user"):
            return 0
        # 未读数 = 非本人发送、状态未 read、且我未读过 的消息数
        read_msg_ids = MessageRead.objects.filter(
            message__conversation=obj, user=request.user
        ).values_list("message_id", flat=True)
        return obj.messages.exclude(sender=request.user).exclude(
            id__in=list(read_msg_ids)
        ).exclude(status=Message.STATUS_RECALLED).count()


class ConversationListSerializer(ConversationSerializer):
    """会话列表：私聊展示对方昵称作为 title。"""

    title = serializers.SerializerMethodField()
    peer = serializers.SerializerMethodField()

    class Meta(ConversationSerializer.Meta):
        fields = ConversationSerializer.Meta.fields + ["peer"]

    def get_title(self, obj) -> str:
        if obj.type == Conversation.TYPE_PRIVATE:
            peer = self.get_peer(obj)
            if not peer:
                return ""
            return peer.get("nickname") or peer.get("username") or ""
        return obj.title

    def get_peer(self, obj):
        request = self.context.get("request")
        if not request or not hasattr(request, "user"):
            return None
        member = (
            obj.members.exclude(user=request.user).select_related("user").first()
        )
        if member is None:
            return None
        return UserPublicSerializer(
            member.user, context={"request": request}
        ).data


class CreateMessageSerializer(serializers.Serializer):
    """发消息入参。"""
    type = serializers.ChoiceField(
        choices=[c[0] for c in Message.TYPE_CHOICES], default=Message.TYPE_TEXT
    )
    content = serializers.CharField(allow_blank=True, default="", max_length=10000)
    reply_to = serializers.IntegerField(required=False, allow_null=True, default=None)
    idempotency_key = serializers.CharField(
        max_length=64, required=False, allow_blank=True, default=None
    )
    media_id = serializers.CharField(
        max_length=64, required=False, allow_blank=True, default=None
    )

    # M4-3：媒体消息类型（type=image/voice/file/emoji 时 media_id 必填并校验）
    MEDIA_TYPES = {
        Message.TYPE_IMAGE,
        Message.TYPE_VOICE,
        Message.TYPE_FILE,
        Message.TYPE_EMOJI,
    }

    def validate_media_id(self, value):
        return value or None

    def validate_idempotency_key(self, value):
        return value or None

    def validate(self, attrs):
        msg_type = attrs.get("type") or Message.TYPE_TEXT
        media_id = attrs.get("media_id")
        if msg_type in self.MEDIA_TYPES:
            if not media_id:
                raise serializers.ValidationError(
                    {"media_id": "媒体消息必须携带 media_id"}
                )
            from apps.media.models import MediaObject
            from apps.media.services import can_access_media

            media = MediaObject.objects.filter(media_id=media_id).first()
            if media is None:
                raise serializers.ValidationError(
                    {"media_id": "media_not_found"}
                )
            if media.status != MediaObject.STATUS_READY:
                raise serializers.ValidationError(
                    {"media_id": "media_not_ready"}
                )
            if media.kind != msg_type:
                raise serializers.ValidationError(
                    {"media_id": "media_type_mismatch"}
                )
            # 访问权：调用方对该媒体有访问权（防拿别人 media_id 发消息）
            # 越权是授权问题 → PermissionDenied（403），与 400 类校验错误区分
            request = self.context.get("request")
            user = getattr(request, "user", None)
            if user is not None and not can_access_media(user, media):
                raise PermissionDenied(
                    {"media_id": "media_access_denied"}
                )
        return attrs


class GroupJoinRequestSerializer(serializers.ModelSerializer):
    """入群申请（对外）。"""

    id = serializers.IntegerField(read_only=True)
    conversation_id = serializers.CharField(read_only=True)
    conversation_title = serializers.CharField(
        read_only=True, source="conversation.title"
    )
    applicant = UserPublicSerializer(read_only=True)
    handled_by_id = serializers.CharField(read_only=True, allow_null=True)
    status = serializers.CharField(read_only=True)

    class Meta:
        model = GroupJoinRequest
        fields = [
            "id",
            "conversation_id",
            "conversation_title",
            "applicant",
            "message",
            "status",
            "handled_by_id",
            "handled_at",
            "created_at",
        ]
        read_only_fields = fields


class GroupMemberLeaveNoticeSerializer(serializers.ModelSerializer):
    conversation_title = serializers.CharField(read_only=True, source="conversation.title")

    class Meta:
        model = GroupMemberLeaveNotice
        fields = ["id", "conversation_id", "conversation_title", "member_name", "read_at", "created_at"]
        read_only_fields = fields


class GroupInviteSerializer(serializers.ModelSerializer):
    """入群邀请（对外）。"""

    id = serializers.IntegerField(read_only=True)
    conversation_id = serializers.CharField(read_only=True)
    conversation_title = serializers.CharField(
        read_only=True, source="conversation.title"
    )
    inviter = UserPublicSerializer(read_only=True)
    invitee = UserPublicSerializer(read_only=True)
    status = serializers.CharField(read_only=True)

    class Meta:
        model = GroupInvite
        fields = [
            "id",
            "conversation_id",
            "conversation_title",
            "inviter",
            "invitee",
            "status",
            "handled_at",
            "created_at",
        ]
        read_only_fields = fields


class GroupActionSerializer(serializers.Serializer):
    """同意/拒绝入群申请或邀请。"""

    action = serializers.ChoiceField(choices=["accept", "reject"])
