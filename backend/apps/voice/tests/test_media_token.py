"""语音媒体契约测试（M4-5）：LiveKit token 签发 + media 双下发 + 全局开关。

覆盖（task-3 验收）：
1. token 端点 401 / 403 / 404 / 503 各条件语义；
2. **identity 必须是裸 `str(user.pk)`**（`audio_consumer.py:93-95` 契约；被删的旧
   `livekit.py` 签的是 `f"user_{user.id}"`，绝不能照抄）；
3. 响应字段不叫 `token`（`test_channel_api.py:42-43` 锁死顶层无 token/ws_url）；
4. media 只下发 `livekit`（中继与回退路径 2026-10-28 已删除，未配置即 503）；
5. 两处 env 模板（`backend/.env.example` 与 `deploy/examples/backend.env.example`）
   的 LIVEKIT_* 都是"注释形态"，且键集合一致。
"""
import base64
import json
import re
from datetime import timedelta
from pathlib import Path

import pytest
from django.test import override_settings

from apps.voice import livekit, media_config
from apps.voice.models import VoiceChannel, VoiceChannelMember

BACKEND_ROOT = Path(__file__).resolve().parents[3]
AYLA_ROOT = BACKEND_ROOT.parent

CONFIGURED = dict(
    LIVEKIT_API_KEY="ayla-livekit",
    LIVEKIT_API_SECRET="test-secret-for-contract-tests-only",
    LIVEKIT_WS_URL="wss://frp-one.com:26211/livekit",
    LIVEKIT_TOKEN_TTL_SECONDS=600,
)


def _decode_jwt_payload(token: str) -> dict:
    """解出 JWT 的 claims（HS256 无加密，测试只读断言，不验签）。"""
    part = token.split(".")[1]
    part += "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part))


def _live_env_keys(path: Path) -> set:
    """返回 .env 模板里**未被注释**赋值的键集合。"""
    keys = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        keys.add(line.split("=", 1)[0].strip())
    return keys


def _mentioned_env_keys(path: Path, prefix: str) -> set:
    """返回模板里**出现过**的、以 prefix 开头的键（含注释行）。"""
    pattern = re.compile(rf"^\s*#?\s*({prefix}[A-Z0-9_]+)\s*=")
    keys = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        matched = pattern.match(raw)
        if matched:
            keys.add(matched.group(1))
    return keys


# ---------------------------------------------------------------- 模块级：签发


@pytest.mark.django_db
def test_issue_token_binds_bare_identity_room_and_grants(auth_client):
    """identity = 裸 str(user.pk)；room/grants/TTL 全部写进 token。"""
    _, user = auth_client(username="media_issue")
    with override_settings(**CONFIGURED):
        issued = livekit.issue_token(user, "room_media_issue")

    claims = _decode_jwt_payload(issued.token)
    # ★ 硬约束：裸 pk，无 "user_" 前缀（否则前端 members[identity] 全部失配）
    assert claims["sub"] == str(user.pk)
    assert not claims["sub"].startswith("user_")
    assert issued.identity == str(user.pk)

    assert claims["video"]["room"] == "room_media_issue"
    assert claims["video"]["roomJoin"] is True
    assert claims["video"]["canPublish"] is True
    assert claims["video"]["canSubscribe"] is True
    assert claims["iss"] == "ayla-livekit"
    assert claims["exp"] - claims["nbf"] == 600
    assert issued.ttl_seconds == 600
    assert issued.room_name == "room_media_issue"


@pytest.mark.django_db
def test_issue_token_respects_custom_ttl(auth_client):
    _, user = auth_client(username="media_ttl")
    with override_settings(LIVEKIT_TOKEN_TTL_SECONDS=1200, **{k: v for k, v in CONFIGURED.items() if k != "LIVEKIT_TOKEN_TTL_SECONDS"}):
        issued = livekit.issue_token(user, "room_ttl")
    assert issued.ttl_seconds == 1200
    claims = _decode_jwt_payload(issued.token)
    assert claims["exp"] - claims["nbf"] == 1200


@pytest.mark.django_db
def test_issue_token_fails_when_not_configured(auth_client):
    """无配置时显式失败，绝不签发裸 token。"""
    _, user = auth_client(username="media_noconf")
    with override_settings(LIVEKIT_API_KEY="", LIVEKIT_API_SECRET="", LIVEKIT_WS_URL=""):
        with pytest.raises(livekit.LiveKitNotConfigured):
            livekit.issue_token(user, "room_home")


@pytest.mark.django_db
def test_issue_token_requires_ws_url(auth_client):
    """只配 key/secret 不算配齐：客户端连不上会给假的成功。"""
    _, user = auth_client(username="media_nourl")
    with override_settings(**{**CONFIGURED, "LIVEKIT_WS_URL": ""}):
        with pytest.raises(livekit.LiveKitNotConfigured):
            livekit.issue_token(user, "room_home")


def test_parse_room_name_rejects_invalid():
    with pytest.raises(ValueError):
        livekit.parse_room_name_from_channel("")
    with pytest.raises(ValueError):
        livekit.parse_room_name_from_channel("bad room/name")
    assert livekit.parse_room_name_from_channel("room_home") == "room_home"
    assert livekit.parse_room_name_from_channel("room-abc123") == "room-abc123"


# ---------------------------------------------------------------- 端点：media-token


@pytest.mark.django_db
def test_media_token_requires_auth():
    from rest_framework.test import APIClient

    resp = APIClient().post("/api/v1/voice/channels/1/media-token/")
    assert resp.status_code in (401, 403)


@pytest.mark.django_db
def test_media_token_channel_not_found(auth_client):
    client, _ = auth_client(username="media_404")
    resp = client.post("/api/v1/voice/channels/9999/media-token/")
    assert resp.status_code == 404


@pytest.mark.django_db
def test_media_token_forbidden_when_cannot_join(auth_client):
    """好友可见频道 + 非好友 → 403（媒体准入 = can_join，不是 can_view 的副作用）。"""
    _, owner = auth_client(username="media_owner403")
    outsider_client, _ = auth_client(username="media_outsider")
    ch = VoiceChannel.objects.create(
        name="好友房", room_name="room_media_403", owner=owner, visibility="friends"
    )
    with override_settings(**CONFIGURED):
        resp = outsider_client.post(f"/api/v1/voice/channels/{ch.id}/media-token/")
    assert resp.status_code == 403, resp.content


@pytest.mark.django_db
def test_media_token_503_when_livekit_not_configured(auth_client):
    """LIVEKIT_* 缺失 → 503 显式失败，不签发裸 token（不回退中继）。"""
    client, user = auth_client(username="media_token_unconfigured")
    ch = VoiceChannel.objects.create(name="vc-u", room_name="room_vc_u", owner=user)
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/media-token/", {}, format="json")
    assert resp.status_code == 503


@pytest.mark.django_db
def test_media_token_returns_livekit_only_media_shape(auth_client):
    """配置齐全 → {"media": {"livekit": {...}}}；不含 transport / ws_relay。"""
    client, user = auth_client(username="media_token_shape")
    ch = VoiceChannel.objects.create(name="vc-s", room_name="room_vc_s", owner=user)
    with override_settings(**CONFIGURED):
        resp = client.post(f"/api/v1/voice/channels/{ch.id}/media-token/", {}, format="json")
    assert resp.status_code == 200, resp.content
    body = resp.json()
    # 顶层只有 media（既有契约：无顶层 token / ws_url）
    assert set(body) == {"media"}
    media = body["media"]
    # 中继配置与 transport 字段已彻底移除
    assert set(media) == {"livekit"}
    livekit_payload = media["livekit"]
    assert set(livekit_payload) == {
        "url", "token", "ttl", "expires_at", "room_name", "identity",
    }
    assert livekit_payload["url"] == CONFIGURED["LIVEKIT_WS_URL"]
    assert livekit_payload["identity"] == str(user.pk)
    assert livekit_payload["room_name"] == ch.room_name


@pytest.mark.django_db
def test_join_delivers_livekit_only(auth_client):
    """join 的 media 同样只有 livekit（不再双下发）。"""
    client, user = auth_client(username="join_media_shape")
    ch = VoiceChannel.objects.create(name="vc-j", room_name="room_vc_j", owner=user)
    with override_settings(**CONFIGURED):
        resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/", {}, format="json")
    assert resp.status_code == 200, resp.content
    media = resp.json()["media"]
    assert set(media) == {"livekit"}
    assert media["livekit"]["url"] == CONFIGURED["LIVEKIT_WS_URL"]


@pytest.mark.django_db
def test_join_ok_with_null_livekit_when_unconfigured(auth_client):
    """媒体面不可用 ⇒ join 仍 200（成员表/广播照旧），但 media.livekit=null。"""
    client, user = auth_client(username="join_unconfigured")
    ch = VoiceChannel.objects.create(name="vc-n", room_name="room_vc_n", owner=user)
    resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/", {}, format="json")
    assert resp.status_code == 200, resp.content
    assert resp.json()["media"] == {"livekit": None}
    assert VoiceChannelMember.objects.filter(channel=ch, user=user).exists()


@pytest.mark.django_db
def test_join_still_succeeds_without_media_payload_after_member_landed(auth_client):
    """配置齐全时 join 返回三字段 + media，且成员确实落表。"""
    client, user = auth_client(username="join_ok")
    ch = VoiceChannel.objects.create(name="vc-ok", room_name="room_vc_ok", owner=user)
    with override_settings(**CONFIGURED):
        resp = client.post(f"/api/v1/voice/channels/{ch.id}/join/", {}, format="json")
    assert resp.status_code == 200
    body = resp.json()
    assert set(body) == {"channel_id", "room_name", "joined", "media"}
    assert VoiceChannelMember.objects.filter(channel=ch, user=user).exists()

# ---------------------------------------------------------------- env 模板一致性


def test_backend_env_example_has_no_live_livekit_lines():
    """backend/.env.example 不得留下"活"的 LIVEKIT_* 赋值（历史残留会误导部署）。"""
    live = _live_env_keys(BACKEND_ROOT / ".env.example")
    live_livekit = {k for k in live if k.startswith("LIVEKIT_")}
    assert live_livekit == set(), f"仍有活配置：{sorted(live_livekit)}"
    # 2026-10-28 起不再有传输开关/中继基址（整体删除，不留回退）
    assert "VOICE_MEDIA_TRANSPORT" not in live
    assert "VOICE_RELAY_WS_BASE" not in live


def test_env_templates_declare_same_livekit_keys():
    """两处模板的 LIVEKIT_* 键集合一致（backend 与 deploy 不许各说各的）。"""
    backend_keys = _mentioned_env_keys(BACKEND_ROOT / ".env.example", "LIVEKIT_")
    deploy_keys = _mentioned_env_keys(
        AYLA_ROOT / "deploy" / "examples" / "backend.env.example", "LIVEKIT_"
    )
    assert backend_keys == deploy_keys, (
        f"模板不一致 backend={sorted(backend_keys)} deploy={sorted(deploy_keys)}"
    )
    assert backend_keys == {
        "LIVEKIT_API_KEY",
        "LIVEKIT_API_SECRET",
        "LIVEKIT_TOKEN_TTL_SECONDS",
        "LIVEKIT_WS_URL",
    }


def test_deploy_env_example_livekit_lines_are_commented():
    """deploy 模板里 LIVEKIT_* 也只能是注释形态。"""
    live = _live_env_keys(AYLA_ROOT / "deploy" / "examples" / "backend.env.example")
    assert {k for k in live if k.startswith("LIVEKIT_")} == set()
