"""
LiveKit 集成（M4-5 §2.3）—— 签发媒体访问 token。

- 依赖 `livekit-api`（Python 官方 SDK，签发 `AccessToken` + `VideoGrants`）；
- **identity 必须是应用内裸 `str(user.pk)`**：`audio_consumer.py:93-95` 明确
  "identity = 应用 user_id（裸 id，与 LiveKit 时代契约一致）：前端成员表 / 音量调节 /
  说话指示都以 user_id 为 key，用 username 会导致全部失配"。被 9746c6b 删掉的旧实现
  签的是 `f"user_{user.id}"`，**绝不能照抄**——那会让 `members[identity]` 全部失配；
- room 直接复用 `VoiceChannel.room_name`（唯一、`room_<uuid hex>`）。请求体不接受
  room 参数，房间与身份全部由服务端裁决，防止客户端指定他人房间；
- 无配置时抛 `LiveKitNotConfigured` 显式失败，绝不签发无授权 token（M4-5 §10.1）。

硬约束（AGENTS.md §9）：
- key/secret 只走环境变量（本机 .env），不提交仓库；
- token 只在响应体中传输，**不打日志、不落库**。
"""
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta

from django.conf import settings
from django.utils import timezone

logger = logging.getLogger(__name__)


class LiveKitNotConfigured(RuntimeError):
    """LiveKit API key/secret 未配置时签发 token 的显式失败。"""


@dataclass(frozen=True)
class IssuedToken:
    """一次签发结果（token 本体 + 可观测调试面）。

    `room_name` / `identity` 已写进 token 的 grants，这里一并返回便于客户端
    与 e2e 断言"签给我的 token 到底绑定到哪个房间/哪个身份"。
    """

    token: str
    identity: str
    room_name: str
    ttl_seconds: int
    expires_at: datetime


def is_configured() -> bool:
    """LIVEKIT_API_KEY / LIVEKIT_API_SECRET / LIVEKIT_WS_URL 均已配置才可签发。"""
    return bool(
        settings.LIVEKIT_API_KEY
        and settings.LIVEKIT_API_SECRET
        and settings.LIVEKIT_WS_URL
    )


def parse_room_name_from_channel(room_name: str) -> str:
    """校验 room_name 合法性（仅字母数字/下划线/短横线）。

    应用内 `room_name` 由 services 自动生成（`room_<uuid hex>`），此处防御性校验非法
    字符，避免把不可控字符串直接拼进 LiveKit Room 名（LiveKit 侧 room 名会进 ICE/JWT）。
    """
    if not room_name:
        raise ValueError("room_name 不能为空")
    if not room_name.replace("-", "").replace("_", "").isalnum():
        raise ValueError(f"非法 room_name: {room_name!r}")
    return room_name


def issue_token(user, room_name: str, *, ttl_seconds: int | None = None) -> IssuedToken:
    """为指定用户签发绑定到指定 LiveKit Room 的访问 token。

    identity 取裸 `str(user.pk)`（应用内 user id 是 32 位 hex 字符串）。
    无配置时抛 `LiveKitNotConfigured`（显式失败，不生成裸 token）。
    """
    if not is_configured():
        raise LiveKitNotConfigured(
            "LIVEKIT_API_KEY / LIVEKIT_API_SECRET / LIVEKIT_WS_URL 未配置，拒绝签发 LiveKit token"
        )
    room = parse_room_name_from_channel(room_name)

    ttl = int(
        ttl_seconds if ttl_seconds is not None else settings.LIVEKIT_TOKEN_TTL_SECONDS
    )
    if ttl <= 0:
        raise ValueError("LIVEKIT_TOKEN_TTL_SECONDS 必须为正整数")

    # 延迟导入：未启用 LiveKit 的部署不因缺少 livekit-api 而在启动期失败
    # （VOICE_MEDIA_TRANSPORT=ws_relay 是合法生产形态，见 media_config）。
    from livekit import api

    identity = str(user.pk)
    token = (
        api.AccessToken(settings.LIVEKIT_API_KEY, settings.LIVEKIT_API_SECRET)
        .with_identity(identity)
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room,
                can_publish=True,
                can_subscribe=True,
            )
        )
        # livekit-api>=1.0 的 with_ttl 接受 timedelta（传 int 秒会在 to_jwt 崩溃）
        .with_ttl(timedelta(seconds=ttl))
        .to_jwt()
    )
    return IssuedToken(
        token=token,
        identity=identity,
        room_name=room,
        ttl_seconds=ttl,
        expires_at=timezone.now() + timedelta(seconds=ttl),
    )
