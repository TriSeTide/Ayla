"""直播间在看人数（Viewer Presence）—— Redis 实时存储。

语义（与 `apps/accounts/presence.py` 同款取舍）：
- "在看直播" = 当前持有该直播间弹幕 WS 连接的登录用户；连接建立加入、断开移除，
  心跳（客户端 30s 一次 ping）刷新活跃分，活跃分过期即视为已离开；
- 实时值以 Redis 为准：`live:viewers:<channel_id>` 是有序集合，member=user_id、
  score=最近活跃 epoch 秒；写入时顺带 EXPIRE 兜底（全部连接消失后 key 自动过期）；
- 读取前按 `VIEWER_TTL_SECONDS` 剔除过期活跃分——**只反映"谁在看"这一运行事实**，
  不生成、不缓存任何关于人的判断（AGENTS.md §2 认知零规则）；
- 存储不可用时返回 `None`（降级），由调用方决定呈现；**禁止把不可用伪装成 0 人在看**
  （同 SRS 查询失败 → degraded 的处置，见 services.resolve_live_status）。

本模块只做存储；昵称/头像等展示投影在 `services.viewer_descriptors` 中解析。
"""
import logging
import time

logger = logging.getLogger(__name__)

_KEY_PREFIX = "live:viewers:"

# 活跃分有效期（秒）：客户端弹幕 WS 心跳 30s 一次，留 2+ 个周期余量。
VIEWER_TTL_SECONDS = 75

# key 级兜底过期：全部观众离开后 key 自行消失，避免残留空集合。
_KEY_TTL_SECONDS = VIEWER_TTL_SECONDS * 2


def _client():
    """返回 Redis 客户端（沿用 accounts.presence 的 django_redis 连接复用）。"""
    from django_redis import get_redis_connection  # type: ignore

    return get_redis_connection("default")


def _key(channel_id) -> str:
    return f"{_KEY_PREFIX}{channel_id}"


def add_viewer(channel_id, user_id) -> int | None:
    """登记一位在线观众并返回剔除过期活跃分后的人数；存储不可用返回 None。"""
    return _write(channel_id, str(user_id), present=True)


def remove_viewer(channel_id, user_id) -> int | None:
    """移除一位观众并返回剩余人数；存储不可用返回 None。"""
    return _write(channel_id, str(user_id), present=False)


def touch_viewer(channel_id, user_id) -> bool | None:
    """心跳刷新活跃分（幂等，不改变人数）。

    返回 True 表示该观众此前已被判为离开（活跃分缺失或已过期）——本次心跳把他重新
    计入在看人数，调用方必须补一次人数广播，否则人数会「无声」变化；
    返回 False 表示人数不变；返回 None 表示存储不可用。
    """
    key = _key(channel_id)
    member = str(user_id)
    now = time.time()
    try:
        client = _client()
        previous = client.zscore(key, member)
        client.zadd(key, {member: now})
        client.expire(key, _KEY_TTL_SECONDS)
    except Exception:
        logger.warning(
            "live viewer heartbeat failed for channel=%s", channel_id, exc_info=True
        )
        return None
    if previous is None:
        return True
    score = float(previous)
    return now - score > VIEWER_TTL_SECONDS


def _write(channel_id, member: str, *, present: bool) -> int | None:
    """写入 presence（加入/移除）并回读剔除过期活跃分后的人数。

    任何存储异常都降级为 None——实时在线是运行事实，读不到就说读不到，
    不能用 0 冒充（AGENTS.md §8）。
    """
    key = _key(channel_id)
    now = time.time()
    try:
        client = _client()
        if present:
            client.zadd(key, {member: now})
        else:
            client.zrem(key, member)
        client.expire(key, _KEY_TTL_SECONDS)
        client.zremrangebyscore(key, "-inf", now - VIEWER_TTL_SECONDS)
        return int(client.zcard(key))
    except Exception:
        logger.warning(
            "live viewer presence write failed (present=%s) for channel=%s",
            present,
            channel_id,
            exc_info=True,
        )
        return None


def viewer_ids(channel_id) -> list[str] | None:
    """当前在线观众 id（最近活跃优先）；存储不可用返回 None。"""
    key = _key(channel_id)
    try:
        client = _client()
        client.zremrangebyscore(key, "-inf", time.time() - VIEWER_TTL_SECONDS)
        members = client.zrevrange(key, 0, -1)
    except Exception:
        logger.warning(
            "live viewer list failed for channel=%s", channel_id, exc_info=True
        )
        return None
    return [m.decode() if isinstance(m, bytes) else str(m) for m in members]


def viewer_count(channel_id) -> int | None:
    """当前在看人数；存储不可用返回 None（调用方不得降级为 0）。"""
    ids = viewer_ids(channel_id)
    return None if ids is None else len(ids)


def viewer_counts(channel_ids) -> dict[int, int] | None:
    """批量读取多个频道的人数（单次 pipeline，列表页避免 N 次往返）。

    返回 `{channel_id: count}`；存储不可用返回 None。
    """
    ids = list(channel_ids)
    if not ids:
        return {}
    cutoff = time.time() - VIEWER_TTL_SECONDS
    try:
        client = _client()
        pipe = client.pipeline()
        for channel_id in ids:
            key = _key(channel_id)
            pipe.zremrangebyscore(key, "-inf", cutoff)
            pipe.zcard(key)
        raw = pipe.execute()
    except Exception:
        logger.warning("live viewer counts failed for %s channels", len(ids), exc_info=True)
        return None
    # pipeline 顺序为 [zremrangebyscore, zcard] 交替
    return {channel_id: int(raw[i * 2 + 1]) for i, channel_id in enumerate(ids)}
