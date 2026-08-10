"""
在线状态（Presence）—— Redis 实时存储。

设计：
- 实时值以 Redis 为准：`presence:<user_id>` -> JSON {"status": "...", "ts": "..."}，
  带 TTL 实现"心跳超时自动掉线"；
- 数据库 User.status 仅作为离线后的持久化期望，不回写实时值；
- 隐身（invisible）用户在 presence 中记录但对外查询视为离线（visibility 规则）。
"""
import json
import logging
from datetime import datetime, timezone

from django.conf import settings

logger = logging.getLogger(__name__)

_PRESENCE_PREFIX = "presence:"
_PRESENCE_TTL = 60  # 秒；心跳间隔应 < TTL

_INVISIBLE = "invisible"


def _redis_client():
    from django_redis import get_redis_connection  # type: ignore

    return get_redis_connection("default")


def _key(user_id: str) -> str:
    return f"{_PRESENCE_PREFIX}{user_id}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def set_presence(user_id: str, status: str) -> None:
    """记录在线状态（幂等），并设置 TTL 兜底。"""
    try:
        client = _redis_client()
        payload = json.dumps({"status": status, "ts": _now_iso()})
        client.setex(_key(user_id), _PRESENCE_TTL, payload)
    except Exception:  # Redis 不可用时在线状态降级，不阻断业务
        logger.warning("presence set failed for user=%s", user_id, exc_info=True)


def get_presence(user_id: str) -> dict | None:
    """读取实时状态；隐身用户对外视为离线。"""
    try:
        client = _redis_client()
        raw = client.get(_key(user_id))
    except Exception:
        logger.warning("presence get failed for user=%s", user_id, exc_info=True)
        return None
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if data.get("status") == _INVISIBLE:
        return None
    return data


def clear_presence(user_id: str) -> None:
    """连接断开时清理在线状态。"""
    try:
        client = _redis_client()
        client.delete(_key(user_id))
    except Exception:
        logger.warning("presence clear failed for user=%s", user_id, exc_info=True)
