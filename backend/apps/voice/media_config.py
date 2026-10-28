"""
语音媒体配置下发 —— **LiveKit 单一媒体面**。

2026-10-28 定稿：WS 音频中继（ws_relay）与其回退路径**整体删除**。此前这里维护
一个 `VOICE_MEDIA_TRANSPORT` 全局开关，join 同时下发 livekit 与 ws_relay 两套配置，
客户端在 LiveKit 连接失败时原地降级。用户明确要求：中继性能不好，不保留实现也不保留
回退 ⇒ 现在：

- **只下发 `media.livekit`**（url / token / ttl / expires_at / room_name / identity）；
- LiveKit 未配置或签发失败 ⇒ **显式失败**（调用方返回 503），不降级、不猜地址。
"""
import logging

from django.conf import settings
from rest_framework.exceptions import APIException

from . import livekit

logger = logging.getLogger(__name__)


class LiveKitMediaUnavailable(APIException):
    """LiveKit 媒体面不可用（未配置 / 签发失败）。**不回退**，显式失败。"""

    status_code = 503
    detail = "语音媒体面暂不可用（LiveKit 未配置或签发失败）"


def livekit_config(user, channel) -> dict:
    """签发 LiveKit 媒体配置；未配置或失败一律抛 503（不再降级到中继）。"""
    try:
        issued = livekit.issue_token(user, channel.room_name)
    except livekit.LiveKitNotConfigured as error:
        logger.exception("LiveKit 未配置，语音媒体面不可用")
        raise LiveKitMediaUnavailable() from error
    except ValueError as error:
        # room_name 非法属数据异常：留痕并显式失败
        logger.exception("签发 LiveKit token 失败（room_name 非法）")
        raise LiveKitMediaUnavailable() from error
    return {
        "url": settings.LIVEKIT_WS_URL,
        "token": issued.token,
        "ttl": issued.ttl_seconds,
        "expires_at": issued.expires_at.isoformat(),
        "room_name": issued.room_name,
        "identity": issued.identity,
    }


def media_payload(user, channel) -> dict:
    """join 用的 `media` 旁路字段：**不抛异常**，不可用时 `livekit=None`。

    为什么要区分：join 还负责「落成员表 + 广播 voice.state」，媒体面不可用时
    不应连成员表都进不去（否则用户连谁在房里都看不到）。客户端拿到
    `media.livekit=null` 会**显式报错**（不猜地址、不回退），语义仍然是失败而不是降级。
    """
    try:
        return {"livekit": livekit_config(user, channel)}
    except LiveKitMediaUnavailable:
        return {"livekit": None}


def require_media_payload(user, channel) -> dict:
    """media-token 用：媒体面不可用即 503（该端点唯一职责就是发媒体凭据）。"""
    return {"livekit": livekit_config(user, channel)}
