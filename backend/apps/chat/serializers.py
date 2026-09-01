"""chat DRF 序列化器。"""
from django.contrib.auth import get_user_model
from django.db.models import Max
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

# 混排段媒体占位（预览摘要用）
_SEGMENT_PLACEHOLDER = {"image": "[图片]", "video": "[视频]"}
# 单媒体消息类型 → 预览占位（无文本内容时）
_MEDIA_TYPE_PLACEHOLDER = {
    Message.TYPE_IMAGE: "[图片]",
    Message.TYPE_VOICE: "[语音]",
    Message.TYPE_FILE: "[文件]",
    Message.TYPE_EMOJI: "[表情]",
    Message.TYPE_VIDEO: "[视频]",
}
_PREVIEW_MAX = 60


def expand_segments(msg) -> list | None:
    """把 DB 里 segments（媒体段只存 media_id、@ 段只存 user_id）展开为带完整
    descriptor 的段列表。

    返回 None（无 segments）或段数组：
    [{"type": "text", "text": "..."},
     {"type": "image"|"video", "media_id": "...", "media": descriptor|null},
     {"type": "mention", "user_id": "...", "user": UserPublic|null}]
    REST 序列化与 WS 广播共用，保证两端契约一致。
    """
    raw = msg.segments
    if not raw:
        return None
    from apps.media.models import MediaObject
    from apps.media.serializers import MediaObjectSerializer

    out = []
    for seg in raw:
        seg_type = seg.get("type")
        if seg_type == "text":
            out.append({"type": "text", "text": seg.get("text", "")})
        elif seg_type in ("image", "video"):
            media_id = seg.get("media_id")
            media = (
                MediaObject.objects.filter(media_id=media_id).first()
                if media_id
                else None
            )
            out.append(
                {
                    "type": seg_type,
                    "media_id": media_id,
                    "media": MediaObjectSerializer(media).data if media else None,
                }
            )
        elif seg_type == "mention":
            user_id = seg.get("user_id")
            user = User.objects.filter(id=user_id).first() if user_id else None
            out.append(
                {
                    "type": "mention",
                    "user_id": user_id,
                    "user": UserPublicSerializer(user).data if user else None,
                }
            )
    return out


def _mention_name(user_id) -> str:
    """@ 目标显示名（预览用）；用户注销/缺失回退「未知用户」。"""
    if not user_id:
        return "未知用户"
    user = User.objects.filter(id=user_id).first()
    if user is None:
        return "未知用户"
    return user.nickname or user.username or "未知用户"


def _poke_preview(msg) -> str:
    """戳一戳列表预览：`发送者戳了戳目标`（content 存目标 user id）。

    昵称缺失回退「有人/对方」；前端渲染时对「自己」归一为「我」。
    """
    sender = msg.sender
    sender_name = (
        getattr(sender, "nickname", "") or (sender.username if sender else "") or "有人"
    )
    target = None
    target_id = (msg.content or "").strip()
    if target_id:
        target = User.objects.filter(id=target_id).first()
    target_name = (
        getattr(target, "nickname", "") or (target.username if target else "") or "对方"
    )
    return f"{sender_name}戳了戳{target_name}"


def message_preview(msg) -> str:
    """会话列表/群活跃度的最新消息预览文本。

    混排消息按段生成「文本文本[视频]文本[图片]」；文本消息取 content；
    单媒体消息取 [图片]/[语音] 等占位（文件消息例外：content 存文件名，直接显示文件名）；
    撤回显示 [已撤回]；戳一戳显示「A戳了戳B」。
    """
    if msg.status == Message.STATUS_RECALLED:
        return "[已撤回]"
    if msg.type == Message.TYPE_POKE:
        return _poke_preview(msg)
    if msg.type == Message.TYPE_MIXED and msg.segments:
        parts = []
        for seg in msg.segments:
            seg_type = seg.get("type")
            if seg_type == "text":
                parts.append(seg.get("text", ""))
            elif seg_type == "mention":
                parts.append(f"@{_mention_name(seg.get('user_id'))}")
            else:
                parts.append(_SEGMENT_PLACEHOLDER.get(seg_type, "[媒体]"))
        preview = "".join(parts)
    elif msg.type == Message.TYPE_FILE:
        # 文件消息契约：content 即文件名（前端发送时写入）；显示文件名而非 [文件] 占位
        preview = msg.content or _MEDIA_TYPE_PLACEHOLDER[msg.type]
    elif msg.type in _MEDIA_TYPE_PLACEHOLDER:
        preview = _MEDIA_TYPE_PLACEHOLDER[msg.type]
    else:
        preview = msg.content or ""
    if len(preview) > _PREVIEW_MAX:
        return preview[:_PREVIEW_MAX] + "…"
    return preview


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
    reply_to_seq = serializers.SerializerMethodField()
    read_by_me = serializers.SerializerMethodField()
    type = serializers.CharField(read_only=True)
    status = serializers.CharField(read_only=True)
    seq = serializers.IntegerField(read_only=True)
    created_at = serializers.DateTimeField(read_only=True)
    # M4-3：media 从字符串 media_id 升级为 descriptor 对象（无引用为 null）
    media = serializers.SerializerMethodField()
    # 图文混排段（type=mixed 消息；媒体段带完整 descriptor；无 segments 为 null）
    segments = serializers.SerializerMethodField()

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
            "segments",
            "reply_to",
            "reply_to_seq",
            "read_by_me",
            "status",
            "seq",
            "created_at",
        ]
        read_only_fields = fields

    def get_reply_to(self, obj):
        return str(obj.reply_to_id) if obj.reply_to_id else None

    def get_reply_to_seq(self, obj):
        """被引用消息的会话序号，供窗口化消息按 before_seq 定位。"""
        return obj.reply_to.seq if obj.reply_to_id and obj.reply_to else None

    def get_read_by_me(self, obj):
        """当前用户是否已对该消息留下已读回执。"""
        request = self.context.get("request")
        if not request or not getattr(request, "user", None) or not request.user.is_authenticated:
            return False
        return MessageRead.objects.filter(message=obj, user=request.user).exists()

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

    def get_segments(self, obj):
        return expand_segments(obj)


class ConversationSerializer(serializers.ModelSerializer):
    """会话序列化：id(str), type, title, owner_id, members[], my_role, unread_count。"""

    id = serializers.CharField(read_only=True)
    owner_id = serializers.CharField(read_only=True)
    members = ConversationMemberSerializer(many=True, read_only=True)
    my_role = serializers.SerializerMethodField()
    unread_count = serializers.SerializerMethodField()
    last_read_seq = serializers.SerializerMethodField()
    unread_seqs = serializers.SerializerMethodField()
    mention_unread_seqs = serializers.SerializerMethodField()
    reply_unread_seqs = serializers.SerializerMethodField()
    member_count = serializers.SerializerMethodField()
    # M5：本人视野的置顶标记（每个成员各自独立）
    is_pinned = serializers.SerializerMethodField()
    # M5：最新一条消息摘要（列表预览用，无消息为 null）
    last_message = serializers.SerializerMethodField()
    # M8 @ 能力：本会话 @ 我且未读的消息数（L2 会话列表 @我 标识）
    mention_unread_count = serializers.SerializerMethodField()

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
            "last_read_seq",
            "is_pinned",
            "last_message",
            "mention_unread_count",
            "unread_seqs",
            "mention_unread_seqs",
            "reply_unread_seqs",
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

    def get_is_pinned(self, obj) -> bool:
        request = self.context.get("request")
        if not request or not hasattr(request, "user"):
            return False
        member = ConversationMember.objects.filter(
            conversation=obj, user=request.user
        ).values_list("is_pinned", flat=True).first()
        return bool(member)

    def get_last_message(self, obj):
        """最新一条消息摘要（按 seq 倒序取首条），无消息返回 None。

        结构：{seq, type, content, sender_id, sender_name, status, created_at, preview}
        - preview：混排摘要文案（混排消息为「文本文本[视频]文本[图片]」；
          单媒体消息为 [图片] 等占位；文本消息取 content；撤回为 [已撤回]）。
        - system 类型与已撤回消息保留在预览里（撤回由 preview 显示占位）。
        - sender_name 取发送者 nickname||username；系统消息无发送者可省略。
        """
        last = obj.messages.order_by("-seq").select_related("sender").first()
        if last is None:
            return None
        sender = last.sender
        return {
            "seq": last.seq,
            "type": last.type,
            "content": last.content,
            "sender_id": str(sender.id) if sender else None,
            "sender_name": getattr(sender, "nickname", "") or (sender.username if sender else "") or "",
            "status": last.status,
            "created_at": last.created_at.isoformat() if last.created_at else None,
            "preview": message_preview(last),
        }

    def get_last_read_seq(self, obj) -> int:
        """当前用户连续读到的会话序号；精确读特殊消息不会越过更早未读。"""
        request = self.context.get("request")
        if not request or not hasattr(request, "user"):
            return 0
        first_unread = self._unread_queryset(obj).order_by("seq").values_list("seq", flat=True).first()
        if first_unread is not None:
            return max(0, int(first_unread) - 1)
        return int(obj.messages.order_by("-seq").values_list("seq", flat=True).first() or 0)

    def _unread_queryset(self, obj):
        request = self.context.get("request")
        if not request or not getattr(request, "user", None):
            return obj.messages.none()
        return (
            obj.messages.exclude(sender=request.user)
            .exclude(status=Message.STATUS_RECALLED)
            # 戳一戳刻意无未读/已读属性：不参与未读计数、未读序号与红点
            .exclude(type=Message.TYPE_POKE)
            .exclude(reads__user=request.user)
        )

    def get_unread_count(self, obj) -> int:
        # 未读数 = 非本人发送、非撤回、且当前用户没有已读回执的消息数。
        return self._unread_queryset(obj).count()

    def get_unread_seqs(self, obj) -> list[int]:
        """F7：当前用户未读消息的会话序号，供窗口外标签定位。"""
        return list(self._unread_queryset(obj).order_by("seq").values_list("seq", flat=True))

    def get_mention_unread_seqs(self, obj) -> list[int]:
        """F9/F10：未读且 @ 当前用户的消息序号。"""
        request = self.context.get("request")
        if not request or not getattr(request, "user", None):
            return []
        return list(
            self._unread_queryset(obj)
            .filter(segments__contains=[{"type": "mention", "user_id": str(request.user.id)}])
            .order_by("seq")
            .values_list("seq", flat=True)
        )

    def get_reply_unread_seqs(self, obj) -> list[int]:
        """F10：未读且回复当前用户消息的消息序号。"""
        request = self.context.get("request")
        if not request or not getattr(request, "user", None):
            return []
        return list(
            self._unread_queryset(obj)
            .filter(reply_to__sender=request.user)
            .order_by("seq")
            .values_list("seq", flat=True)
        )

    def get_mention_unread_count(self, obj) -> int:
        """本会话 @ 我且未读的消息数（L2：会话列表 @我 标识）。"""
        request = self.context.get("request")
        if not request or not hasattr(request, "user"):
            return 0
        read_msg_ids = MessageRead.objects.filter(
            message__conversation=obj, user=request.user
        ).values_list("message_id", flat=True)
        return (
            obj.messages.exclude(sender=request.user)
            .exclude(id__in=list(read_msg_ids))
            .exclude(status=Message.STATUS_RECALLED)
            .filter(segments__contains=[{"type": "mention", "user_id": str(request.user.id)}])
            .count()
        )


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
    # 图文混排段（type=mixed）：与 media_id 二选一；至少一个媒体段
    segments = serializers.ListField(
        required=False, allow_empty=False, child=serializers.DictField()
    )

    # M4-3：媒体消息类型（type=image/voice/file/emoji/video 时 media_id 必填并校验）
    MEDIA_TYPES = {
        Message.TYPE_IMAGE,
        Message.TYPE_VOICE,
        Message.TYPE_FILE,
        Message.TYPE_EMOJI,
        Message.TYPE_VIDEO,
    }
    SEGMENT_MEDIA_TYPES = {"image", "video"}

    def validate_media_id(self, value):
        return value or None

    def validate_idempotency_key(self, value):
        return value or None

    def _validate_segment_media(self, media_id, expect_kind):
        """校验混排段媒体：存在/ready/kind 匹配/访问权。返回 MediaObject 或抛错。"""
        from apps.media.models import MediaObject
        from apps.media.services import can_access_media

        media = MediaObject.objects.filter(media_id=media_id).first()
        if media is None:
            raise serializers.ValidationError({"segments": "media_not_found"})
        if media.status != MediaObject.STATUS_READY:
            raise serializers.ValidationError({"segments": "media_not_ready"})
        if media.kind != expect_kind:
            raise serializers.ValidationError({"segments": "media_type_mismatch"})
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if user is not None and not can_access_media(user, media):
            raise PermissionDenied({"segments": "media_access_denied"})
        return media

    def _validate_mention(self, user_id):
        """校验 @ 目标为本群成员（防 @ 无关/已退群用户）。"""
        conversation = self.context.get("conversation")
        if conversation is None:
            return  # 无会话上下文（理论不出现）时不做成员校验
        if not conversation.members.filter(user_id=user_id).exists():
            raise serializers.ValidationError({"segments": "mention_user_not_member"})

    def validate(self, attrs):
        msg_type = attrs.get("type") or Message.TYPE_TEXT
        media_id = attrs.get("media_id")
        segments = attrs.get("segments")

        # 结构化消息段模式：segments 与 media_id 互斥；type 强制 mixed（忽略传入 type）
        if segments is not None:
            if media_id:
                raise serializers.ValidationError(
                    {"segments": "segments 与 media_id 不能同时使用"}
                )
            if not segments:
                raise serializers.ValidationError({"segments": "至少需要一个段"})
            has_non_text_segment = False
            text_parts = []
            for i, seg in enumerate(segments):
                seg_type = seg.get("type")
                if seg_type == "text":
                    text = (seg.get("text") or "").strip()
                    if not text:
                        raise serializers.ValidationError(
                            {"segments": f"第 {i + 1} 段文本为空"}
                        )
                    text_parts.append(text)
                elif seg_type in self.SEGMENT_MEDIA_TYPES:
                    has_non_text_segment = True
                    seg_media_id = seg.get("media_id")
                    if not seg_media_id:
                        raise serializers.ValidationError(
                            {"segments": f"第 {i + 1} 段缺少 media_id"}
                        )
                    self._validate_segment_media(seg_media_id, seg_type)
                elif seg_type == "mention":
                    has_non_text_segment = True
                    mention_user_id = seg.get("user_id")
                    if not mention_user_id:
                        raise serializers.ValidationError(
                            {"segments": f"第 {i + 1} 段缺少 user_id"}
                        )
                    self._validate_mention(mention_user_id)
                else:
                    raise serializers.ValidationError(
                        {"segments": f"第 {i + 1} 段类型不支持"}
                    )
            if not has_non_text_segment:
                raise serializers.ValidationError(
                    {"segments": "混排消息至少需要一个媒体段或 @ 段"}
                )
            attrs["type"] = Message.TYPE_MIXED
            attrs["content"] = "".join(text_parts)
            return attrs

        # 戳一戳：content 存目标用户 id；不得携带媒体/引用；目标必须是会话成员。
        if msg_type == Message.TYPE_POKE:
            if media_id:
                raise serializers.ValidationError(
                    {"media_id": "戳一戳消息不能携带媒体"}
                )
            if attrs.get("reply_to"):
                raise serializers.ValidationError(
                    {"reply_to": "戳一戳消息不支持引用"}
                )
            target_id = (attrs.get("content") or "").strip()
            if not target_id:
                raise serializers.ValidationError(
                    {"content": "戳一戳必须指定目标用户"}
                )
            conversation = self.context.get("conversation")
            if (
                conversation is not None
                and not conversation.members.filter(user_id=target_id).exists()
            ):
                raise serializers.ValidationError(
                    {"content": "目标用户不在会话中"}
                )
            attrs["content"] = target_id
            return attrs

        # 旧模式：单媒体消息 type=image/voice/file/emoji/video 时 media_id 必填并校验
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
