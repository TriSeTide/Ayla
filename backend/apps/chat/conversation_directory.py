"""SQL ordering for visible conversation pages, before the page boundary."""
from datetime import datetime, timedelta, timezone as datetime_timezone

from django.db.models import Case, DateTimeField, Exists, F, IntegerField, OuterRef, Subquery, Value, When
from django.db.models.functions import Cast, Coalesce, Greatest
from django.utils import timezone

from .models import Conversation, ConversationMember, Message

CONVERSATION_ORDER = [("_social_pin", "int"), ("_social_activity", "datetime"),
                      ("created_at", "datetime"), ("pk", "pk")]
SUBGROUP_ORDER = [("_social_default", "int"), ("_social_seq", "int"), ("pk", "pk", True)]


def with_subgroup_order(queryset, conversation):
    """Default first, then latest message sequence; identity stabilizes ties."""
    own = Message.objects.filter(subgroup_id=OuterRef("pk")).order_by("-seq")
    legacy = Message.objects.filter(conversation=conversation, subgroup_id__isnull=True).order_by("-seq")
    return queryset.annotate(
        _social_default=Cast(F("is_default"), output_field=IntegerField()),
        _social_seq=Case(When(is_default=True, then=Greatest(
            Coalesce(Subquery(own.values("seq")[:1]), Value(0)),
            Coalesce(Subquery(legacy.values("seq")[:1]), Value(0)),
        )), default=Coalesce(Subquery(own.values("seq")[:1]), Value(0))),
    )


def with_group_presence(queryset):
    """Aggregate badge existence across all visible rooms, independent of pages."""
    from apps.boardgame.models import GameRoom
    from apps.live.models import LiveChannel
    from apps.voice.models import VoiceChannel

    return queryset.annotate(
        _social_live=Exists(LiveChannel.objects.filter(allowed_groups=OuterRef("pk"), status="live")),
        _social_voice=Exists(VoiceChannel.objects.filter(allowed_groups=OuterRef("pk"), members__isnull=False)),
        _social_game=Exists(GameRoom.objects.filter(allowed_groups=OuterRef("pk"))),
    )


def with_conversation_order(queryset, user):
    """Keep pins and current group/private activity ahead of newer empty rows.

    Groups use the existing UI's 24-hour event window and allowed-group scope.
    These projections do not decide permissions: the input is already limited
    to the user's memberships, and cross-domain events require that same group
    in their explicit visibility whitelist.
    """
    from apps.boardgame.models import GameRoom
    from apps.live.models import LiveChannel
    from apps.posts.models import Post
    from apps.voice.models import VoiceChannel

    now = timezone.now()
    recent = now - timedelta(hours=24)
    future = now + timedelta(minutes=1)
    epoch = Cast(Value(datetime(1970, 1, 1, tzinfo=datetime_timezone.utc)), output_field=DateTimeField())
    latest_message = Message.objects.filter(conversation_id=OuterRef("pk")).order_by("-seq")
    member = ConversationMember.objects.filter(conversation_id=OuterRef("pk"), user=user)

    def recent_time(model, field="created_at", **filters):
        events = model.objects.filter(allowed_groups=OuterRef("pk"), **filters,
            **{f"{field}__gt": recent, f"{field}__lt": future}).order_by(f"-{field}", "-pk")
        return Coalesce(Subquery(events.values(field)[:1]), epoch)

    queryset = with_group_presence(queryset).annotate(
        _social_pin=Cast(Coalesce(Subquery(member.values("is_pinned")[:1]), Value(False)), output_field=IntegerField()),
        _social_message=Coalesce(Subquery(latest_message.values("created_at")[:1]), epoch),
    ).annotate(_social_group_activity=Greatest(
        Case(When(_social_message__gt=recent, _social_message__lt=future, then=F("_social_message")), default=epoch),
        recent_time(LiveChannel, "started_at", status="live"), recent_time(VoiceChannel),
        recent_time(GameRoom), recent_time(Post),
    ))
    return queryset.annotate(_social_activity=Case(
        When(type=Conversation.TYPE_GROUP, then=F("_social_group_activity")),
        default=F("_social_message"), output_field=DateTimeField(),
    ))
