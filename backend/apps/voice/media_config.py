"""
语音媒体配置下发 —— `VOICE_MEDIA_TRANSPORT` 双下发（M4-5 §2.5）。

设计（见 `Ayla/.workbuddy/evidence/livekit-udp/recon/PLAN.md` §2.5 与 §7.1）：

- `VOICE_MEDIA_TRANSPORT` 是**唯一全局回滚开关**：改成 `ws_relay` 并重启后端，
  全部客户端立即回到 WS 音频中继（无需发版、无需重建客户端）；
- join / media-token **同时下发两种媒体配置**：`transport` 只是服务端建议值，
  客户端在 `transport=livekit` 但连接失败时可直接按已到手的 `ws_relay` 原地降级，
  不必回后端再要一次配置（回滚速度 = 一次连接尝试）；
- `livekit` 配置缺失（未启用或未配置 key/secret/url）时为 `None`，且 `transport`
  回落 `ws_relay`——显式降级，绝不把坏配置下发给客户端。

回滚路径（`ws/voice/audio/` 中继）在 `routing.py` / `audio_consumer.py` /
`audio_relay.py` 中**一行未改**，是完整的生产可用路径。
"""
import logging

from django.conf import settings

from . import livekit

logger = logging.getLogger(__name__)

TRANSPORT_LIVEKIT = "livekit"
TRANSPORT_WS_RELAY = "ws_relay"

#: 合法取值（环境变量写错时显式回落并留 warning，不静默镜像错误配置）
VALID_TRANSPORTS = (TRANSPORT_LIVEKIT, TRANSPORT_WS_RELAY)


def configured_transport() -> str:
    """`VOICE_MEDIA_TRANSPORT` 的归一化取值；非法值回落 `ws_relay`（安全侧）。"""
    raw = str(getattr(settings, "VOICE_MEDIA_TRANSPORT", "") or "").strip().lower()
    if raw in VALID_TRANSPORTS:
        return raw
    if raw:
        logger.warning(
            "VOICE_MEDIA_TRANSPORT=%r 非法，回落 %s（合法值：%s）",
            raw,
            TRANSPORT_WS_RELAY,
            "/".join(VALID_TRANSPORTS),
        )
    return TRANSPORT_WS_RELAY


def relay_ws_url(channel_id) -> str:
    """WS 音频中继的完整地址（回滚路径）。

    基址取 `VOICE_RELAY_WS_BASE`（生产 = 与 API 同源的 sakura 隧道，
    `wss://s.ayla.trise.top:26211`；本地 dev 留空则返回站内相对路径，
    由 Vite 的 `/ws` 代理转发）。客户端既可直接使用本字段，也可继续沿用
    自拼地址——两者语义等价。
    """
    base = str(getattr(settings, "VOICE_RELAY_WS_BASE", "") or "").rstrip("/")
    path = f"/ws/voice/audio/?channel={channel_id}"
    return f"{base}{path}"


def livekit_config(user, channel) -> dict | None:
    """签发 LiveKit 媒体配置；未启用或签发失败时返回 `None`（显式降级到中继）。"""
    try:
        issued = livekit.issue_token(user, channel.room_name)
    except livekit.LiveKitNotConfigured:
        logger.info("LIVEKIT_* 未配置，media.livekit 不下发（transport 回落 ws_relay）")
        return None
    except ValueError:
        # room_name 非法属数据异常，留痕但不阻断 join（媒体面回落中继）
        logger.exception("签发 LiveKit token 失败（room_name 非法），媒体面回落 ws_relay")
        return None
    return {
        "url": settings.LIVEKIT_WS_URL,
        "token": issued.token,
        "ttl": issued.ttl_seconds,
        "expires_at": issued.expires_at.isoformat(),
        "room_name": issued.room_name,
        "identity": issued.identity,
    }


def media_payload(user, channel) -> dict:
    """构造响应里的 `media` 旁路字段（join 与 media-token 共用同一形状）。

    - `transport`：服务端建议值（`livekit` | `ws_relay`）；
    - `livekit`：仅在 transport=livekit 且配置齐全时非空；否则 `None`；
    - `ws_relay`：**恒下发**（回滚路径永远可用，客户端据此原地降级）。
    """
    transport = configured_transport()
    lk: dict | None = None
    if transport == TRANSPORT_LIVEKIT:
        lk = livekit_config(user, channel)
        if lk is None:
            # 开关指向 livekit 但配置不全 ⇒ 回落中继，别让客户端拿到坏配置
            transport = TRANSPORT_WS_RELAY
    return {
        "transport": transport,
        "livekit": lk,
        "ws_relay": {"url": relay_ws_url(channel.pk)},
    }
