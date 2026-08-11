"""
LiveKit 集成（M4-5 §7）：签发访问 token + 房间元数据解析（核心领域逻辑）。

- 依赖 `livekit-api`（Python 官方包，签发 `AccessToken` + `VideoGrants`）；
- `issue_token(user, room_name)`：identity 绑定稳定用户标识 + 房间 + publish/subscribe grants，
  TTL 取 `settings.LIVEKIT_TOKEN_TTL_SECONDS`（默认 600，前端在过期前重签）；
- **前端绝不直接拿应用后端签发 LiveKit token 之外的任何媒体凭据**；token 只绑定该用户 + 该房间；
- 无配置时显式失败（不生成裸 token，见 M4-5 §10.1）。

硬约束（继承 AGENTS.md + 阶段三 §12）：
- LiveKit key/secret 走本机配置（env），不提交仓库；
- 每个 token 签发失败必须显式报错，绝不静默降级为无授权 token。
"""
import logging

from django.conf import settings

logger = logging.getLogger(__name__)


class LiveKitNotConfigured(RuntimeError):
    """LiveKit API key/secret 未配置时签发 token 的显式失败。"""


def _configured() -> bool:
    """LIVEKIT_API_KEY / LIVEKIT_API_SECRET 均已配置才可签发。"""
    return bool(settings.LIVEKIT_API_KEY and settings.LIVEKIT_API_SECRET)


def issue_token(user, room_name: str, *, ttl_seconds: int | None = None) -> str:
    """为指定用户签发绑定到指定 LiveKit Room 的访问 token。

    identity 取稳定用户标识（user.id 为 uuid hex 字符串，符合应用内帧协议）。
    无配置时抛 ``LiveKitNotConfigured``（显式失败，不生成裸 token）。
    """
    if not _configured():
        raise LiveKitNotConfigured(
            "LIVEKIT_API_KEY / LIVEKIT_API_SECRET 未配置，拒绝签发 LiveKit token"
        )
    if not room_name:
        raise ValueError("room_name 不能为空")

    from livekit import api

    ttl = ttl_seconds if ttl_seconds is not None else settings.LIVEKIT_TOKEN_TTL_SECONDS
    token = (
        api.AccessToken(settings.LIVEKIT_API_KEY, settings.LIVEKIT_API_SECRET)
        .with_identity(f"user_{user.id}")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_subscribe=True,
            )
        )
        .with_ttl(ttl)
    )
    return token.to_jwt()


def parse_room_name_from_channel(room_name: str) -> str:
    """房间元数据解析：校验 room_name 合法性（仅字母数字/下划线/短横线）。

    应用内 `room_name` 由 services 自动生成（`room_<uuid hex>`），此处防御性校验
    非法字符，避免把不可控字符串直接拼进 LiveKit Room 名。
    """
    if not room_name or not room_name.replace("-", "").replace("_", "").isalnum():
        raise ValueError(f"非法 room_name: {room_name!r}")
    return room_name
