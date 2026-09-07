"""Opt-in chronological SQL pages, bound to the reader and exact post."""
from datetime import datetime

from django.core import signing
from django.db.models import Q
from django.utils.timezone import is_aware
from rest_framework.exceptions import ValidationError

from apps.common.catalog_pagination import CatalogPage

CURSOR_SALT = "ayla.post-comments.cursor.v1"


def paginate_comments(queryset, request, post_id):
    """Preserve the old array contract unless a page parameter is supplied."""
    params = request.query_params
    if "limit" not in params and "cursor" not in params:
        return None
    for key in ("limit", "cursor"):
        if key in params and len(params.getlist(key)) != 1:
            raise ValidationError({"detail": f"{key} 只能提供一次"})
    raw_limit = params.get("limit", "20")
    if not raw_limit.isascii() or not raw_limit.isdecimal() or len(raw_limit) > 3 or not 1 <= int(raw_limit) <= 100:
        raise ValidationError({"detail": "limit 必须是 1 到 100 的整数"})
    limit = int(raw_limit)
    binding = {"v": 1, "reader": str(request.user.pk), "post": str(post_id), "order": "created_at,id"}
    position = None
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
            at = datetime.fromisoformat(position[0])
            if not is_aware(at) or type(position[1]) is not int or not 1 <= position[1] <= 2**63 - 1:
                raise ValueError
        except (signing.BadSignature, KeyError, ValueError, TypeError, OverflowError):
            raise ValidationError({"detail": "cursor 无效或与当前评论列表不匹配"}) from None
    total = queryset.count()
    if position is not None:
        queryset = queryset.filter(Q(created_at__gt=at) | Q(created_at=at, id__gt=position[1]))
    rows = list(queryset.order_by("created_at", "id")[:limit + 1])
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if has_more:
        last = rows[-1]
        next_cursor = signing.dumps({"binding": binding, "position": [last.created_at.isoformat(), last.pk]}, salt=CURSOR_SALT)
    return CatalogPage(rows, next_cursor, has_more, total)
