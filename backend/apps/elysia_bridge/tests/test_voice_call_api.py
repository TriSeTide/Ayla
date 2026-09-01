"""
爱莉 Voice Live 编排端点契约测试（M4-5 §5.2 基线方案，挂 /api/v1/elysia/voice-calls/）。

覆盖（mock Elysium 侧，不依赖真实 Elysium/LiveKit）：
- POST create：profile 未初始化/禁用 → 503；正常 → 200（call + connection + reused）；
- POST create 复用：进程内活跃通话未结束 → reused=True；
- GET detail：通话状态读取；
- POST text：空 text → 400；正常注入 → 200；
- POST end：结束通话 + 从活跃表移除；
- POST poll：转写投影（projected/total）→ 200；
- 越权：未登录 → 401。

mock 方式：patch `apps.elysia_bridge.services.<编排函数>`（view 通过 services 模块调用），
保持与 test_profile_api 相同的 APIClient 风格。
"""
from unittest import mock

import pytest
from rest_framework.test import APIClient

from apps.elysia_bridge.elysia_client import (
    CommandAccepted,
    VoiceCallStatus,
    VoiceCallTicket,
)
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge import services as bridge_services

CREATE_URL = "/api/v1/elysia/voice-calls/"


def _profile(user_factory):
    elysia_user = user_factory(username="elysia_vc_api", nickname="爱莉")
    return ElysiaProfile.objects.create(
        user=elysia_user, stream_id="stream_vc_api", display_name="爱莉"
    )


def _status(**kw):
    base = dict(call_id="call_api_1", state="active", resumable=True)
    base.update(kw)
    return VoiceCallStatus.from_mapping(base)


def _ticket():
    return VoiceCallTicket.from_mapping(
        {
            "ticket": "t-secret",
            "url": "ws://localhost/ws",
            "resource": "/api/v1/voice-calls/call_api_1/ws",
            "subprotocol": "elysium.voice-call.participant.v1",
            "expires_at": "2026-08-11T08:05:00Z",
        }
    )


def _command(**kw):
    return CommandAccepted.from_mapping(
        {"command": {"command_id": kw.get("command_id", "cmd_1"),
                     "status": kw.get("status", "accepted")}}
    )


@pytest.mark.django_db
class TestVoiceCallAPI:
    def test_unauthenticated_gets_401(self, api_client):
        resp = api_client.post(CREATE_URL, {}, format="json")
        assert resp.status_code == 401
        resp_get = api_client.get(f"{CREATE_URL}call_1/")
        assert resp_get.status_code == 401

    def test_no_profile_returns_503(self, auth_client):
        client, user = auth_client()
        resp = client.post(CREATE_URL, {"mode": "auto"}, format="json")
        assert resp.status_code == 503
        assert "未初始化" in resp.data["detail"]

    def test_disabled_profile_returns_503(self, auth_client, user_factory):
        client, user = auth_client()
        profile = _profile(user_factory)
        profile.enabled = False
        profile.save(update_fields=["enabled"])
        resp = client.post(CREATE_URL, {}, format="json")
        assert resp.status_code == 503

    def test_create_voice_call_returns_200(self, auth_client, user_factory):
        client, user = auth_client()
        profile = _profile(user_factory)
        with mock.patch.object(
            bridge_services,
            "ensure_elysia_voice_call",
            return_value={
                "call": _status(),
                "connection": _ticket(),
                "reused": False,
            },
        ) as ensure:
            resp = client.post(CREATE_URL, {"mode": "auto"}, format="json")
        ensure.assert_called_once()
        assert resp.status_code == 200
        assert resp.data["call"]["call_id"] == "call_api_1"
        assert resp.data["call"]["state"] == "active"
        assert resp.data["connection"]["subprotocol"].startswith("elysium.voice-call")
        assert resp.data["reused"] is False

    def test_create_reuses_active_call(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        with mock.patch.object(
            bridge_services,
            "ensure_elysia_voice_call",
            return_value={"call": _status(), "connection": None, "reused": True},
        ):
            resp = client.post(CREATE_URL, {}, format="json")
        assert resp.status_code == 200
        assert resp.data["reused"] is True
        assert resp.data["connection"] is None

    def test_detail_returns_status(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        with mock.patch.object(
            bridge_services,
            "get_voice_call_status",
            return_value=_status(state="active"),
        ):
            resp = client.get(f"{CREATE_URL}call_api_1/")
        assert resp.status_code == 200
        assert resp.data["call"]["call_id"] == "call_api_1"
        assert resp.data["call"]["state"] == "active"

    def test_detail_error_maps_502(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        with mock.patch.object(
            bridge_services, "get_voice_call_status", side_effect=RuntimeError("boom")
        ):
            resp = client.get(f"{CREATE_URL}call_api_1/")
        assert resp.status_code == 502
        assert "Elysium 侧错误" in resp.data["detail"]

    def test_text_blank_returns_400(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        resp = client.post(
            f"{CREATE_URL}call_api_1/text/", {"text": "   "}, format="json"
        )
        assert resp.status_code == 400

    def test_text_injects(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        with mock.patch.object(
            bridge_services,
            "send_voice_text",
            return_value=_command(command_id="cmd_text_1"),
        ) as send:
            resp = client.post(
                f"{CREATE_URL}call_api_1/text/", {"text": "你好爱莉"}, format="json"
            )
        send.assert_called_once()
        args = send.call_args
        assert args.args[1] == "call_api_1"
        assert args.args[2] == "你好爱莉"
        assert resp.status_code == 200
        assert resp.data["command_id"] == "cmd_text_1"

    def test_end_voice_call(self, auth_client, user_factory):
        client, user = auth_client()
        profile = _profile(user_factory)
        bridge_services._register_active_voice_call(profile, "call_api_1")
        try:
            with mock.patch.object(
                bridge_services,
                "end_voice_call",
                return_value=_command(command_id="cmd_end_1"),
            ) as end:
                resp = client.post(f"{CREATE_URL}call_api_1/end/", {}, format="json")
            end.assert_called_once()
            assert resp.status_code == 200
            # 结束后从活跃表移除（再次 ensure 不会复用）
            assert "call_api_1" not in bridge_services._ACTIVE_VOICE_CALLS
        finally:
            bridge_services._unregister_active_voice_call("call_api_1")

    def test_poll_projects_transcripts(self, auth_client, user_factory):
        client, user = auth_client()
        _profile(user_factory)
        with mock.patch.object(
            bridge_services,
            "poll_voice_transcripts",
            return_value={
                "projected": ["1"],
                "total": 2,
                "projected_total": 1,
            },
        ) as poll:
            resp = client.post(f"{CREATE_URL}call_api_1/poll/", {}, format="json")
        poll.assert_called_once()
        assert resp.status_code == 200
        assert resp.data["projected"] == ["1"]
        assert resp.data["total"] == 2
        assert resp.data["projected_total"] == 1
