"""Opt-in cursor pages for visible room catalogs; legacy callers keep arrays.

The caller applies visibility and domain filters before this helper. Every page
rechecks those filters, and ``total`` counts that current complete queryset,
not just the cursor remainder. A cursor identifies a position, not a snapshot.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Generic, Literal, TypeVar

from django.core import signing
from django.db.models import Case, DateTimeField, F, IntegerField, Model, Q, QuerySet, Value, When
from django.db.models.functions import Cast, Coalesce
from django.utils.timezone import is_aware
from rest_framework.exceptions import ValidationError

ModelT = TypeVar("ModelT", bound=Model)
CatalogOrder = Literal["activity", "-created_at"]
DEFAULT_LIMIT = 20
MAX_LIMIT = 100
CURSOR_SALT = "ayla.catalog.cursor.v1"


def catalog_scope(params) -> str:
    """Resolve ``group_id`` as an alias for the existing allowed-groups scope."""
    scope = params.get("scope", "").strip()
    if "group_id" not in params:
        return scope
    raw_group = params["group_id"]
    if (
        len(params.getlist("group_id")) != 1
        or not raw_group.isascii()
        or not raw_group.isdecimal()
        or len(raw_group) > 19
        or not 1 <= int(raw_group) <= 2**63 - 1
    ):
        raise ValidationError({"detail": "group_id 必须是有效的正整数"})
    group_scope = f"group:{int(raw_group)}"
    if scope and scope != group_scope:
        raise ValidationError({"detail": "group_id 与 scope 不匹配"})
    return group_scope


def with_activity_order(
    queryset: QuerySet[ModelT],
    *,
    active_condition,
    previous_condition: Q,
    active_time: str,
    previous_time: str,
) -> QuerySet[ModelT]:
    """Project the existing frontend active/previous/new ordering into SQL.

    Null activity timestamps keep the frontend's zero-time fallback. These are
    ordering annotations only; they neither infer state nor modify stored data.
    """
    return queryset.annotate(
        _catalog_rank=Case(
            When(active_condition, then=Value(0)),
            When(previous_condition, then=Value(1)),
            default=Value(2),
            output_field=IntegerField(),
        ),
        _catalog_time=Coalesce(
            Case(
                When(active_condition, then=F(active_time)),
                When(previous_condition, then=F(previous_time)),
                default=F("created_at"),
                output_field=DateTimeField(),
            ),
            Cast(Value(datetime(1970, 1, 1, tzinfo=timezone.utc)), output_field=DateTimeField()),
        ),
    )


@dataclass(frozen=True)
class CatalogPage(Generic[ModelT]):
    """Bounded model rows plus metadata for the caller's existing serializer."""

    rows: list[ModelT]
    next_cursor: str | None
    has_more: bool
    total: int

    def response_data(self, results) -> dict:
        return {
            "results": results,
            "next_cursor": self.next_cursor,
            "has_more": self.has_more,
            "total": self.total,
        }


def paginate_catalog(
    queryset: QuerySet[ModelT],
    request,
    *,
    resource: str,
    ordering: CatalogOrder,
    filters: dict[str, str],
) -> CatalogPage[ModelT] | None:
    """Return a SQL-limited page only when ``limit`` or ``cursor`` is supplied.

    Voice/live receive SQL annotations matching their existing frontend activity
    ordering; games keep newest creation first. All use descending immutable id
    as the final deterministic tiebreaker. Activity changes can move boundaries,
    so this is a live directory cursor, not a cross-request static snapshot.
    Signed, versioned cursors are bound to the requester, resource and filters;
    changing any of those requires a fresh first page. Malformed parameters are
    400 responses, never an empty page or a silently restarted first page.
    """
    params = request.query_params
    if "limit" not in params and "cursor" not in params:
        return None
    for name in ("limit", "cursor"):
        if name in params and len(params.getlist(name)) != 1:
            raise ValidationError({"detail": f"{name} 只能提供一次"})

    raw_limit = params.get("limit", str(DEFAULT_LIMIT))
    if (
        not raw_limit.isascii()
        or not raw_limit.isdecimal()
        or len(raw_limit) > 3
        or not 1 <= int(raw_limit) <= MAX_LIMIT
    ):
        raise ValidationError({"detail": f"limit 必须是 1 到 {MAX_LIMIT} 的整数"})
    limit = int(raw_limit)
    binding = {
        "v": 1,
        "resource": resource,
        "user": str(request.user.pk),
        "ordering": ordering,
        "filters": filters,
    }
    position = None
    if "cursor" in params:
        cursor = params["cursor"]
        if not cursor or len(cursor) > 4096:
            raise ValidationError({"detail": "cursor 无效"})
        try:
            decoded = signing.loads(cursor, salt=CURSOR_SALT)
            if not isinstance(decoded, dict) or decoded.get("binding") != binding:
                raise ValueError
            position = decoded["position"]
            if not isinstance(position, list):
                raise ValueError
            if len(position) != 3:
                raise ValueError
            rank = position[0]
            if type(rank) is not int or rank not in (0, 1, 2):
                raise ValueError
            item_id = position[-1]
            if type(item_id) is not int or not 1 <= item_id <= 2**63 - 1:
                raise ValueError
            activity_at = datetime.fromisoformat(position[1])
            if not is_aware(activity_at):
                raise ValueError
        except (signing.BadSignature, KeyError, TypeError, ValueError, OverflowError):
            raise ValidationError(
                {"detail": "cursor 无效或与当前列表条件不匹配"}
            ) from None

    total = queryset.count()
    if ordering == "-created_at":
        queryset = queryset.annotate(
            _catalog_rank=Value(0, output_field=IntegerField()),
            _catalog_time=F("created_at"),
        )
    queryset = queryset.order_by("_catalog_rank", "-_catalog_time", "-id")
    if position is not None:
        queryset = queryset.filter(
            Q(_catalog_rank__gt=rank)
            | Q(_catalog_rank=rank, _catalog_time__lt=activity_at)
            | Q(_catalog_rank=rank, _catalog_time=activity_at, id__lt=position[-1])
        )

    rows = list(queryset[: limit + 1])
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if has_more:
        last = rows[-1]
        next_position = [last._catalog_rank, last._catalog_time.isoformat(), last.pk]
        next_cursor = signing.dumps(
            {"binding": binding, "position": next_position}, salt=CURSOR_SALT
        )
    return CatalogPage(rows, next_cursor, has_more, total)
