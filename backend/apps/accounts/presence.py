"""
在线状态（Presence）—— Redis 实时存储。

设计：
- 实时值以 Redis 为准：`presence:<user_id>` -> JSON {"status": "...", "ts": "..."}，
  带 TTL 实现"心跳超时自动掉线"；
- 数据库 User.status 仅作为离线后的持久化期望，不回写实时值；
- 隐身（invisible）用户在 presence 中记录但对外查询视为离线（visibility 规则）。

### 多连接感知（同一账号 App + web 并存 / 重连时旧连接 close 晚到）

`presence:<user_id>` 只表达"这个账号至少有一条活连接"，**不表达还有几条**。
没有独立的连接集合时，任一连接断开就会 clear + 广播 offline，把仍活着的新连接
标成离线（真因与实测见 Ayla/.workbuddy/evidence/livekit-udp/P4-WS-热更新-结论.md §7）。
因此另有一组 Redis 结构（全部落在 Redis，跨 daphne 进程 / 多 worker 正确）：

- `presence:conns:<user_id>`      SET，member = 该账号每条 presence 连接的
  `channel_name`（Channels 保证单实例唯一），即"活连接集合" = 引用计数；
- `presence:conn:<channel_name>`  单连接存活标记（TTL `_CONN_TTL`），心跳 ping 续期；
  进程被 kill / 节点重启来不及 `disconnect` 时标记自然过期，不会留下永久幽灵成员；
- `presence:conn_registry`        HASH，channel_name -> user_id；用于把"集合里剩下的
  连接"映射回账号，并在标记过期后清理墓碑 member。

`unregister_connection(user_id, channel_name)` 只有在该账号**确实没有其它活连接**时
返回 True；调用方（`PresenceConsumer.disconnect`）只在 True 时 clear + 广播 offline。
存储不可用时返回 None——**不许猜**：无法证明"这是最后一条连接"就不广播离线，
真实离线仍由 `presence:<user_id>` 的 60s TTL 兜底（serializers 读不到 key 即离线）。

### 第二个独立标记源：ElyH（DSH 插件）通道

`presence:elyh:<user_id>` 表达"爱莉的 ElyH 通道当前连着 Ayla"，由
`elysia_bridge.consumers.AylaBridgeConsumer` 的 connect / ping / disconnect
维护，TTL 90s（DSH 每 30s ping 一次）。它与上面的 `presence:<user_id>` **完全
独立**，不共享 key、不共享引用计数：两套来源各自增删，对外可见性取"或"
（`serializers.UserPublicSerializer`）。这样前端直连和 ElyH 常连可以同时存在，
不会因为一方断开把另一方标成离线。
"""
import json
import logging
from datetime import datetime, timezone

from django.conf import settings

logger = logging.getLogger(__name__)

_PRESENCE_PREFIX = "presence:"
_PRESENCE_TTL = 60  # 秒；心跳间隔应 < TTL

# 单条连接的存活标记 TTL（秒）：presence ping 25s 一次，留 2+ 个周期余量。
# 进程被 kill / 节点重启来不及 disconnect 时，标记自然过期，不会留下永远"活着"的连接。
_CONN_TTL = _PRESENCE_TTL * 2

# 连接集合 key 的兜底 TTL（秒）：只在"某条连接崩溃且该账号再也不产生任何连接变更"时
# 才会残留，这里给一个足够长的兜底过期，而不是短 TTL——短 TTL 会让集合在连接仍活着时
# 消失，从而把"还有别的连接"误判成"最后一条连接"（正是本修复要消除的错误）。
_CONNS_TTL = 7 * 24 * 3600

_INVISIBLE = "invisible"


def _redis_client():
    from django_redis import get_redis_connection  # type: ignore

    return get_redis_connection("default")


def _key(user_id: str) -> str:
    return f"{_PRESENCE_PREFIX}{user_id}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _conns_key(user_id: str) -> str:
    """该账号活连接集合（SET，member=channel_name）。"""
    return f"{_PRESENCE_PREFIX}conns:{user_id}"


def _conn_key(channel_name: str) -> str:
    """单条连接的存活标记（TTL 续期，崩溃后自然过期）。"""
    return f"{_PRESENCE_PREFIX}conn:{channel_name}"


def _registry_key() -> str:
    """channel_name -> user_id 的映射（HASH），用于映射剩余连接与清理墓碑。"""
    return f"{_PRESENCE_PREFIX}conn_registry"


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


# ---------- ElyH（DSH 插件）独立在线标记 ----------
#
# 规则三（用户定，方案 B）：ElyH 连上 Ayla 时爱莉在线，断开即离线。
#
# **刻意不复用 `presence:<user_id>`**：那个 key 由 Ayla 前端 PresenceConsumer
# 维护（活连接引用计数 + 60s TTL，断开/心跳都会写它）。ElyH 若共用同一个 key，
# 两条来源会互相 clear / 互相续期，产生「谁最后断开谁说了算」的竞态，把真实
# 在线的另一侧标成离线。因此这里另起一个 key 族 `presence:elyh:<user_id>`，
# 只由 ElyH 通道的 connect / ping / disconnect 读写，两套标记互不干扰，
# 对外查询时取「或」关系（见 accounts.serializers.UserPublicSerializer）。
#
# TTL 取 90s：DSH 侧每 30s ping 一次，90s = 3 个心跳周期。DSH 进程被 kill /
# 网络闪断来不及发 close 时，标记最多 90s 自然过期，不会留下永久在线幽灵；
# 偶发丢 1~2 个 ping 也不会误判离线。
_ELYH_PREFIX = "presence:elyh:"
_ELYH_TTL = 90


def _elyh_key(user_id: str) -> str:
    """ElyH 在线标记 key（与 Ayla 前端的 presence key 分离，见上文说明）。"""
    return f"{_ELYH_PREFIX}{user_id}"


def mark_elyh_online(user_id: str, owner: str | None = None) -> None:
    """标记 ElyH 已连接（幂等写入 + 续期）。

    `owner` 是写入方身份（bridge consumer 的 channel_name）。连接被顶替时，
    新连接先写标记，旧连接的 disconnect 晚到——它带着**自己的** owner 去清，
    比较后不匹配即跳过（见 clear_elyh_online）。存储不可用只降级（记日志），
    不阻断 WS 主流程。
    """
    try:
        client = _redis_client()
        payload = json.dumps({"ts": _now_iso(), "owner": owner})
        client.setex(_elyh_key(user_id), _ELYH_TTL, payload)
    except Exception:
        logger.warning("elyh presence mark failed for user=%s", user_id, exc_info=True)


def clear_elyh_online(user_id: str, owner: str | None = None) -> None:
    """清除 ElyH 在线标记。

    `owner=None`：无条件清除（运维/测试）。
    给定 owner：只有当存量的标记确实由该连接写入时才清——被顶替的旧连接不得
    清掉新连接的标记。这里的「读-比较-删」不是原子的，最坏结果只是标记多活到
    TTL 到期（方向上是「短暂仍显示在线」），不会把真实在线误判成离线。
    """
    key = _elyh_key(user_id)
    try:
        client = _redis_client()
        if owner is not None:
            raw = client.get(key)
            if raw:
                try:
                    stored = json.loads(raw).get("owner")
                except (json.JSONDecodeError, AttributeError):
                    stored = None
                # 存量标记没有 owner（早期写法/人工写入）时仍允许清除。
                if stored is not None and stored != owner:
                    return
        client.delete(key)
    except Exception:
        logger.warning("elyh presence clear failed for user=%s", user_id, exc_info=True)


def is_elyh_online(user_id: str) -> bool:
    """ElyH 是否在线；读不到或存储不可用一律 False（无证据即不在线，不猜）。"""
    try:
        client = _redis_client()
        return bool(client.exists(_elyh_key(user_id)))
    except Exception:
        logger.warning("elyh presence read failed for user=%s", user_id, exc_info=True)
        return False


# ---------- 多连接引用计数（活连接集合） ----------

def register_connection(user_id: str, channel_name: str) -> int | None:
    """登记一条 presence 连接，返回该账号当前登记的连接数；存储不可用返回 None。

    幂等：同一 channel_name 重复登记只保留一个 member（SADD 语义）。
    """
    member = str(channel_name)
    try:
        client = _redis_client()
        client.sadd(_conns_key(user_id), member)
        client.hset(_registry_key(), member, str(user_id))
        client.setex(_conn_key(member), _CONN_TTL, "1")
        client.expire(_conns_key(user_id), _CONNS_TTL)
        return live_connection_count(user_id, client=client)
    except Exception:
        logger.warning(
            "presence conn register failed for user=%s", user_id, exc_info=True
        )
        return None


def refresh_connection(user_id: str, channel_name: str, status: str = "online") -> None:
    """心跳续期：该连接的存活标记与账号 presence 值一起续 TTL。

    存活标记丢失（崩溃残留 / 已过期）时补登记，避免集合里出现"有 member 但标记已死"
    的墓碑导致该账号永远清不掉。
    """
    member = str(channel_name)
    try:
        client = _redis_client()
        if client.exists(_conn_key(member)):
            client.setex(_conn_key(member), _CONN_TTL, "1")
            client.expire(_conns_key(user_id), _CONNS_TTL)
            client.hset(_registry_key(), member, str(user_id))
        else:
            register_connection(user_id, member)
    except Exception:
        logger.warning("presence conn refresh failed for user=%s", user_id, exc_info=True)
    set_presence(user_id, status)


def _live_members(client, user_id: str, channel_name: str) -> list[str]:
    """该账号除 channel_name 之外仍有存活标记的连接（并顺手清理墓碑 member）。

    判定依据是"连接标记存在"而非"集合里有 member"：进程被 kill 时来不及 SREM，
    只有标记 TTL 能证明连接确实已经消失。
    """
    member = str(channel_name)
    members = client.smembers(_conns_key(user_id)) or set()
    live: list[str] = []
    for raw in members:
        other = raw.decode() if isinstance(raw, bytes) else str(raw)
        if other == member:
            continue
        if client.exists(_conn_key(other)):
            live.append(other)
            continue
        # 墓碑：连接已死但来不及 SREM（进程崩溃/节点重启）→ 现在就清掉
        client.srem(_conns_key(user_id), other)
        client.hdel(_registry_key(), other)
    return live


def live_connection_count(user_id: str, client=None) -> int:
    """该账号当前还有几条活连接（含墓碑清理）；存储不可用时返回 0（未知即无）。"""
    try:
        client = client or _redis_client()
        live = _live_members(client, user_id, "")
        return len(live)
    except Exception:
        logger.warning(
            "presence conn count failed for user=%s", user_id, exc_info=True
        )
        return 0


def unregister_connection(user_id: str, channel_name: str) -> bool | None:
    """注销一条连接；返回 True 表示该账号已无任何活连接（可下线）。

    返回 False 表示仍有其它活连接（**不得** clear presence / 广播 offline）；
    返回 None 表示存储不可用，调用方必须按"无法证明是最后一条"处理（不广播离线）。
    """
    member = str(channel_name)
    try:
        client = _redis_client()
        client.srem(_conns_key(user_id), member)
        client.hdel(_registry_key(), member)
        client.delete(_conn_key(member))
        remaining = _live_members(client, user_id, member)
        if remaining:
            logger.info(
                "presence still alive for user=%s (%d other connection(s))",
                user_id,
                len(remaining),
            )
            return False
        client.delete(_conns_key(user_id))
        return True
    except Exception:
        logger.warning(
            "presence conn unregister failed for user=%s", user_id, exc_info=True
        )
        return None


def purge_connection(channel_name: str) -> bool:
    """按 channel_name 强制摘除一条连接（consumer connect 失败等边界用）。

    从 registry 反查 user_id 后走同一注销语义；返回是否已无活连接。
    """
    member = str(channel_name)
    try:
        client = _redis_client()
        user_id = client.hget(_registry_key(), member)
        if not user_id:
            client.delete(_conn_key(member))
            return True
        return unregister_connection(
            user_id.decode() if isinstance(user_id, bytes) else str(user_id), member
        )
    except Exception:
        logger.warning(
            "presence conn purge failed for conn=%s", channel_name, exc_info=True
        )
        return None
