"""Signed keyset pages for social directories; legacy array reads stay explicit.

Cursors encode a position in a deterministic order, never permission or a data
snapshot. Every continuation re-applies the caller's current queryset and scope.
"""
from datetime import datetime

from django.core import signing
from django.db import models
from django.db.models import Q
from django.utils.timezone import is_aware
from rest_framework.exceptions import ValidationError

SALT = "ayla.social.page.v1"


def page_requested(request):
    """Opt in with pagination=cursor; reject ambiguous or malformed parameters."""
    params = request.query_params
    if "pagination" not in params and "cursor" not in params:
        return False
    for name in ("pagination", "cursor", "limit", "q", "type", "status", "direction", "exclude_self"):
        if name in params and len(params.getlist(name)) != 1:
            raise ValidationError({"detail": f"{name} 只能提供一次"})
    if params.get("pagination") != "cursor":
        raise ValidationError({"detail": "分页必须使用 pagination=cursor"})
    return True


def social_page(queryset, request, *, scope, time_field=None, ascending=False, ordering=None):
    """Read at most limit + 1 rows and return total plus a scope-bound cursor."""
    params = request.query_params
    raw_limit = params.get("limit", "30")
    if (not raw_limit.isascii() or not raw_limit.isdecimal()
            or len(raw_limit) > 3 or not 1 <= int(raw_limit) <= 100):
        raise ValidationError({"detail": "limit 必须是 1 到 100 的整数"})
    limit = int(raw_limit)
    fields = [entry[0] for entry in ordering] if ordering else ([time_field] if time_field else []) + ["pk"]
    directions = [entry[2] if len(entry) > 2 else ascending for entry in ordering] if ordering else [ascending] * len(fields)
    order = [("" if direction else "-") + field for field, direction in zip(fields, directions)]
    binding = {"v": 1, "actor": str(request.user.pk), "scope": scope, "order": order}
    cursor = params.get("cursor")
    values = None
    if cursor is not None:
        try:
            if not cursor or len(cursor) > 4096:
                raise ValueError
            decoded = signing.loads(cursor, salt=SALT)
            if not isinstance(decoded, dict) or decoded.get("binding") != binding:
                raise ValueError
            values = decoded["position"]
            if not isinstance(values, list) or len(values) != len(fields):
                raise ValueError
            for index, field in enumerate(fields):
                kind = ordering[index][1] if ordering else ("pk" if field == "pk" else "datetime")
                if kind == "datetime":
                    values[index] = datetime.fromisoformat(values[index])
                    if not is_aware(values[index]):
                        raise ValueError
                elif kind == "int":
                    if type(values[index]) is not int or not 0 <= values[index] <= 2**63 - 1:
                        raise ValueError
                else:
                    pk_field = queryset.model._meta.pk
                    raw_pk = values[index]
                    if isinstance(pk_field, models.IntegerField):
                        if type(raw_pk) is not int or not 1 <= raw_pk <= 2**63 - 1:
                            raise ValueError
                    elif (not isinstance(raw_pk, str) or not raw_pk
                          or len(raw_pk) > (pk_field.max_length or 128)):
                        raise ValueError
                    values[index] = pk_field.to_python(raw_pk)
        except (signing.BadSignature, KeyError, TypeError, ValueError, OverflowError):
            raise ValidationError({"detail": "cursor 无效或与当前账号、资源、查询不匹配"}) from None
    total = queryset.count()
    queryset = queryset.order_by(*order)
    if values is not None:
        after = Q()
        for index, field in enumerate(fields):
            lookup = "gt" if directions[index] else "lt"
            after |= Q(**{**dict(zip(fields[:index], values[:index])), f"{field}__{lookup}": values[index]})
        queryset = queryset.filter(after)
    rows = list(queryset[:limit + 1])
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if has_more:
        last = rows[-1]
        position = [getattr(last, field) for field in fields]
        position = [value.isoformat() if isinstance(value, datetime) else value for value in position]
        next_cursor = signing.dumps({"binding": binding, "position": position}, salt=SALT)
    return rows, {"total": total, "has_more": has_more, "next_cursor": next_cursor}


def serialized_page(queryset, request, serializer_class, *, scope,
                    time_field=None, ascending=False, context=None):
    """Serialize only a bounded page, or preserve the existing array contract."""
    serializer_context = {"request": request, **(context or {})}
    if not page_requested(request):
        return serializer_class(queryset, many=True, context=serializer_context).data
    rows, metadata = social_page(queryset, request, scope=scope,
                                 time_field=time_field, ascending=ascending)
    return {"results": serializer_class(rows, many=True, context=serializer_context).data,
            **metadata}
