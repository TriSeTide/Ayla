"""Bounded keyset pages; callers apply authorization before every page read."""
from dataclasses import dataclass
from datetime import datetime
from typing import Generic, Literal, TypeVar

from django.core import signing
from django.db.models import Model, Q, QuerySet
from django.utils.timezone import is_aware
from rest_framework.exceptions import ValidationError

ModelT = TypeVar("ModelT", bound=Model)
CURSOR_SALT = "ayla.media.cursor.v1"
MAX_LIMIT = 100


@dataclass(frozen=True)
class MediaPage(Generic[ModelT]):
    rows: list[ModelT]
    next_cursor: str | None
    has_more: bool
    total: int

    def response_data(self, results) -> dict:
        return {"results": results, "next_cursor": self.next_cursor,
                "has_more": self.has_more, "total": self.total}


def paginate_media(
    queryset: QuerySet[ModelT], request, *, resource: str, scope: str,
    field: str = "created_at", field_type: Literal["datetime", "integer"] = "datetime",
    descending: bool = True, reverse_results: bool = False,
    default_limit: int = 50, required: bool = False, allow_history_anchor: bool = False,
) -> MediaPage[ModelT] | None:
    """Read limit+1 rows using a signed (field,id) continuation.

    History callers opt in with pagination=cursor; new member endpoints require
    pages. Cursors bind user, resource and scope, and are not snapshot claims.
    """
    params = request.query_params
    if not required and not any(key in params for key in ("pagination", "cursor", "before_id")):
        return None
    for key in ("pagination", "cursor", "limit", "before_id"):
        if key in params and len(params.getlist(key)) != 1:
            raise ValidationError({"detail": f"{key} 只能提供一次"})
    if "pagination" in params and params["pagination"] != "cursor":
        raise ValidationError({"detail": "pagination 必须为 cursor"})
    raw_limit = params.get("limit", str(default_limit))
    if (not raw_limit.isascii() or not raw_limit.isdecimal() or len(raw_limit) > 3
            or not 1 <= int(raw_limit) <= MAX_LIMIT):
        raise ValidationError({"detail": f"limit 必须是 1 到 {MAX_LIMIT} 的整数"})
    limit = int(raw_limit)
    binding = {"v": 1, "resource": resource, "scope": scope,
               "user": str(request.user.pk), "field": field,
               "field_type": field_type, "descending": descending}
    total = queryset.count()
    if "before_id" in params:
        raw_anchor = params["before_id"]
        if (not allow_history_anchor or not descending or "cursor" in params
                or not raw_anchor.isascii() or not raw_anchor.isdecimal()
                or len(raw_anchor) > 19 or not 1 <= int(raw_anchor) <= 2**63 - 1):
            raise ValidationError({"detail": "before_id 无效或不能与 cursor 同时使用"})
        anchor = queryset.filter(pk=int(raw_anchor)).first()
        if anchor is None:
            raise ValidationError({"detail": "历史起点不存在，请重试或返回最新消息"})
        anchor_value = getattr(anchor, field)
        queryset = queryset.filter(Q(**{f"{field}__lt": anchor_value})
                                   | Q(**{field: anchor_value, "id__lt": anchor.pk}))
    if "cursor" in params:
        cursor = params["cursor"]
        try:
            if not cursor or len(cursor) > 4096:
                raise ValueError
            decoded = signing.loads(cursor, salt=CURSOR_SALT)
            if not isinstance(decoded, dict) or decoded.get("binding") != binding:
                raise ValueError
            position = decoded["position"]
            if not isinstance(position, list) or len(position) != 2:
                raise ValueError
            value, item_id = position
            if type(item_id) is not int or not 1 <= item_id <= 2**63 - 1:
                raise ValueError
            if field_type == "datetime":
                value = datetime.fromisoformat(value)
                if not is_aware(value):
                    raise ValueError
            elif type(value) is not int or value < 0:
                raise ValueError
        except (signing.BadSignature, KeyError, TypeError, ValueError, OverflowError):
            raise ValidationError({"detail": "cursor 无效或与当前列表条件不匹配"}) from None
        op = "lt" if descending else "gt"
        queryset = queryset.filter(Q(**{f"{field}__{op}": value})
                                   | Q(**{field: value, f"id__{op}": item_id}))
    prefix = "-" if descending else ""
    rows = list(queryset.order_by(f"{prefix}{field}", f"{prefix}id")[: limit + 1])
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if has_more:
        last = rows[-1]
        value = getattr(last, field)
        if field_type == "datetime":
            value = value.isoformat()
        next_cursor = signing.dumps({"binding": binding, "position": [value, last.pk]},
                                   salt=CURSOR_SALT)
    if reverse_results:
        rows.reverse()
    return MediaPage(rows, next_cursor, has_more, total)
