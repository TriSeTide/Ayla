"""Explicit, signed keyset pages for aggregate search.

The existing limit-only search contract remains unchanged. Each continuation
belongs to one result type and rechecks its current visibility queryset. The
cursor stores a position, not a snapshot or an authorization grant.
"""
from dataclasses import dataclass
from datetime import datetime

from django.core import signing
from django.db import models
from django.db.models import Q
from django.utils.timezone import is_aware
from rest_framework.exceptions import ValidationError

CURSOR_SALT = "ayla.search.cursor.v1"


@dataclass(frozen=True)
class SearchPageOptions:
    limit: int
    cursor: str | None


def parse_page_options(request, types: list[str]) -> SearchPageOptions | None:
    """Opt in with pagination=cursor; continuation requires exactly one type."""
    params = request.query_params
    if "pagination" not in params and "cursor" not in params:
        return None
    for name in ("pagination", "cursor", "limit", "types", "q"):
        if name in params and len(params.getlist(name)) != 1:
            raise ValidationError({"detail": f"{name} 只能提供一次"})
    if params.get("pagination") != "cursor":
        raise ValidationError({"detail": "游标搜索必须使用 pagination=cursor"})
    raw_limit = params.get("limit", "10")
    if (not raw_limit.isascii() or not raw_limit.isdecimal()
            or len(raw_limit) > 2 or not 1 <= int(raw_limit) <= 50):
        raise ValidationError({"detail": "limit 必须是 1 到 50 的整数"})
    cursor = params.get("cursor")
    if cursor is not None:
        if not cursor or len(cursor) > 4096 or len(types) != 1:
            raise ValidationError({"detail": "cursor 无效，续页必须指定单一搜索类型"})
    return SearchPageOptions(int(raw_limit), cursor)


def search_page(queryset, request, *, query: str, kind: str,
                time_field: str, options: SearchPageOptions):
    """Return SQL-limited rows plus metadata, bound to actor/query/type/order.

    User primary keys are strings; the other search models use integer ids.
    The model field validates cursor values before ORM filtering, and the
    timestamp plus immutable primary key defines a deterministic total order.
    """
    binding = {
        "v": 1, "user": str(request.user.pk), "q": query,
        "type": kind, "order": [f"-{time_field}", "-pk"],
    }
    position = None
    if options.cursor is not None:
        try:
            decoded = signing.loads(options.cursor, salt=CURSOR_SALT)
            if not isinstance(decoded, dict) or decoded.get("binding") != binding:
                raise ValueError
            position = decoded["position"]
            if not isinstance(position, list) or len(position) != 2:
                raise ValueError
            timestamp = datetime.fromisoformat(position[0])
            if not is_aware(timestamp):
                raise ValueError
            raw_pk = position[1]
            field = queryset.model._meta.pk
            if isinstance(field, models.IntegerField):
                if type(raw_pk) is not int or not 1 <= raw_pk <= 2**63 - 1:
                    raise ValueError
            elif (not isinstance(raw_pk, str) or not raw_pk
                  or len(raw_pk) > (field.max_length or 128)):
                raise ValueError
            pk = field.to_python(raw_pk)
        except (signing.BadSignature, KeyError, TypeError, ValueError, OverflowError):
            raise ValidationError({"detail": "cursor 无效或与当前搜索条件不匹配"}) from None

    total = queryset.count()
    queryset = queryset.order_by(f"-{time_field}", "-pk")
    if position is not None:
        queryset = queryset.filter(
            Q(**{f"{time_field}__lt": timestamp})
            | Q(**{time_field: timestamp, "pk__lt": pk})
        )
    rows = list(queryset[:options.limit + 1])
    has_more = len(rows) > options.limit
    rows = rows[:options.limit]
    next_cursor = None
    if has_more:
        last = rows[-1]
        next_cursor = signing.dumps({
            "binding": binding,
            "position": [getattr(last, time_field).isoformat(), last.pk],
        }, salt=CURSOR_SALT)
    return rows, {"total": total, "has_more": has_more, "next_cursor": next_cursor}
