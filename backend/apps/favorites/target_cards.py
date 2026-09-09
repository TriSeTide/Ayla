"""Request-scoped, permission-filtered card projections for one favorite page.

Public resource serializers own field meaning. These projections select the
fields needed by a card before serialization; they never emit live transport
addresses, publishing credentials, message attachments or private group data.
Message cards carry the fields a chat bubble needs (media_id/segments/seq/
subgroup_id/status) so favorites can render media and jump to the original
message; media descriptors are expanded by the chat serializer contract and
never include signed URLs or storage paths.
"""
from collections import defaultdict

from django.db.models import Count, Exists, OuterRef, Prefetch
from rest_framework import serializers

from apps.boardgame.models import GameRoom, GameRoomMember
from apps.boardgame.serializers import GameRoomSerializer
from apps.chat.models import Conversation, Message
from apps.chat.serializers import expand_segments
from apps.common.visibility import visible_queryset
from apps.live.models import LiveChannel
from apps.live.serializers import LiveChannelSerializer
from apps.posts.models import Post, PostView
from apps.posts.serializers import PostSerializer
from apps.voice.models import VoiceChannel, VoiceChannelMember
from apps.voice.serializers import VoiceChannelSerializer

from .models import Favorite


def target_key(target_type: str, target_id) -> tuple[str, int] | None:
    """Normalize legacy string ids without letting damaged records break a page."""
    try:
        value = int(target_id)
    except (TypeError, ValueError, OverflowError):
        return None
    return (target_type, value) if 1 <= value <= 2**63 - 1 else None


class _CardSourceMixin:
    """Reuse public source semantics from the groups prefetched for this page."""

    def get_allowed_group_ids(self, obj):
        return [str(group.id) for group in obj._favorite_allowed_groups]

    def get_allowed_group_names(self, obj):
        return [group.title for group in obj._favorite_allowed_groups]


class _PostCardSerializer(_CardSourceMixin, PostSerializer):
    comment_count = serializers.IntegerField(source="_comment_count", read_only=True)


class _LiveCardSerializer(_CardSourceMixin, LiveChannelSerializer):
    class Meta(LiveChannelSerializer.Meta):
        # Playback URLs also embed the publishing stream identifier. A card
        # needs none of these addresses, including when its viewer is the owner.
        fields = [
            "id", "title", "description", "cover", "status", "visibility",
            "group", "group_name", "allowed_group_ids", "allowed_group_names",
            "owner_id", "owner_nickname", "is_owner", "started_at", "ended_at", "created_at",
        ]
        read_only_fields = fields


class _VoiceCardSerializer(_CardSourceMixin, VoiceChannelSerializer):
    pass


class _GameCardSerializer(_CardSourceMixin, GameRoomSerializer):
    class Meta(GameRoomSerializer.Meta):
        # The card displays a count, not a room member directory.
        fields = [
            "id", "name", "owner", "owner_id", "visibility", "group", "group_name",
            "allowed_group_ids", "allowed_group_names", "game_type", "status",
            "member_count", "is_owner", "is_member", "created_at",
        ]
        read_only_fields = fields


def _with_source(queryset):
    return queryset.select_related("owner", "group").prefetch_related(Prefetch(
        "allowed_groups", queryset=Conversation.objects.only("id", "title"),
        to_attr="_favorite_allowed_groups",
    ))


def build_target_cards(favorites, request) -> dict[tuple[str, int], dict]:
    """Load only this page's visible targets in batches; unavailable keys stay absent.

    Visibility is reapplied to every call. A saved bookmark, prior page or
    cached card grants no access after group/friendship removal. Message
    cards keep the 120-character content preview and stay membership-checked;
    media fields are only the chat bubble contract (media_id/segments), never
    signed URLs or storage paths.
    """
    user = getattr(request, "user", None)
    if user is None or not user.is_authenticated:
        return {}
    ids = defaultdict(set)
    for favorite in favorites:
        key = target_key(favorite.target_type, favorite.target_id)
        if key is not None:
            ids[key[0]].add(key[1])
    cards = {}
    context = {"request": request}
    resource_types = (
        (Favorite.TARGET_POST, Post, _PostCardSerializer),
        (Favorite.TARGET_LIVE, LiveChannel, _LiveCardSerializer),
        (Favorite.TARGET_VOICE, VoiceChannel, _VoiceCardSerializer),
        (Favorite.TARGET_GAME, GameRoom, _GameCardSerializer),
    )
    for kind, model, serializer_class in resource_types:
        if not ids[kind]:
            continue
        queryset = _with_source(visible_queryset(model, user).filter(pk__in=ids[kind]))
        if kind == Favorite.TARGET_POST:
            queryset = queryset.annotate(
                _comment_count=Count("comments", distinct=True),
                _viewed=Exists(PostView.objects.filter(post_id=OuterRef("pk"), user=user)),
            ).prefetch_related("images__media")
        elif kind == Favorite.TARGET_VOICE:
            queryset = queryset.annotate(
                member_count=Count("members", distinct=True),
                _favorite_mine=Exists(VoiceChannelMember.objects.filter(
                    channel_id=OuterRef("pk"), user=user,
                )),
            )
        elif kind == Favorite.TARGET_GAME:
            queryset = queryset.annotate(
                _member_count=Count("members", distinct=True),
                _requester_member=Exists(GameRoomMember.objects.filter(
                    room_id=OuterRef("pk"), user=user,
                )),
            )
        for target in queryset:
            card = dict(serializer_class(target, context=context).data)
            card["id"] = str(target.pk)
            if kind == Favorite.TARGET_POST:
                # Existing clients use title as a summary for an untitled post.
                # New post cards receive the original title independently.
                card["raw_title"] = target.title
                card["title"] = target.title or (target.body or "")[:30]
            elif kind == Favorite.TARGET_VOICE:
                card["mine"] = target._favorite_mine
            cards[(kind, target.pk)] = card

    if ids[Favorite.TARGET_MESSAGE]:
        messages = Message.objects.filter(
            pk__in=ids[Favorite.TARGET_MESSAGE], conversation__members__user=user,
        ).select_related("conversation", "sender", "reply_to")
        for message in messages:
            cards[(Favorite.TARGET_MESSAGE, message.pk)] = {
                "id": str(message.pk),
                "conversation_id": str(message.conversation_id),
                "sender_id": str(message.sender_id),
                "sender_nickname": message.sender.nickname or message.sender.username,
                "subgroup_id": str(message.subgroup_id) if message.subgroup_id else None,
                "type": message.type,
                "content": (message.content or "")[:120],
                "media_id": message.media_id,
                "segments": expand_segments(message),
                "reply_to": str(message.reply_to_id) if message.reply_to_id else None,
                "reply_to_seq": message.reply_to.seq if message.reply_to_id and message.reply_to else None,
                "status": message.status,
                "seq": message.seq,
                "created_at": message.created_at.isoformat(),
            }
    return cards
