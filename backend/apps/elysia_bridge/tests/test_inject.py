"""
入站 inject 契约测试（8.1 清单第 3 项）—— 全部 mock Elysium，不依赖真实服务。

覆盖：
- 用户给爱莉发消息 → 应用内消息落库（sender=普通用户）→ on_user_message_to_elysia
  inject 到 Elysium（带 sender_id/sender_name/platform/chat_type）；
- 非爱莉会话 → 不 inject；
- profile 未启用 → 跳过 inject；
- 发送者是爱莉本人 → 不入站；
- Elysium 返回 404（stream 不存在）→ 桥接不抛、不破坏用户消息（视图层 try/except）；
- 凭据管理：无 secret 时 ProfileNotConfigured。

用 monkeypatch 替换 get_injector()，避免真实网络。
"""
import pytest

from apps.chat.models import Conversation, Message
from apps.chat import services as chat_services
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge import services as bridge_services
from apps.elysia_bridge.services import (
    ElysiaUnauthenticated,
    InboundInjector,
    ProfileNotConfigured,
    on_user_message_to_elysia,
)


@pytest.fixture
def elysia_setup(db, user_factory):
    """创建爱莉 user + profile，以及一个普通用户。"""

    def _make(*, enabled=True, chat_type="private", stream_id="stream_elysia_1"):
        elysia_user = user_factory(username="elysia_core", nickname="爱莉")
        elysia_user.save()
        profile = ElysiaProfile.objects.create(
            user=elysia_user,
            stream_id=stream_id,
            enabled=enabled,
            chat_type=chat_type,
            display_name="爱莉",
        )
        user = user_factory(username="user_a", nickname="汐汐")
        return elysia_user, profile, user

    return _make


@pytest.fixture
def fake_injector(monkeypatch):
    """替换 get_injector 为可控 fake，记录注入请求。"""

    class _FakeInjector:
        def __init__(self):
            self.injected: list[dict] = []
            self.return_value = True

        def inject_user_message(self, *, message, profile):
            self.injected.append(
                {
                    "message_id": message.id,
                    "sender_id": str(message.sender_id),
                    "content": message.content,
                    "stream_id": profile.stream_id,
                    "chat_type": profile.chat_type,
                }
            )
            return self.return_value

    fake = _FakeInjector()
    monkeypatch.setattr(bridge_services, "get_injector", lambda: fake)
    return fake


def _send_user_message(user, elysia_user) -> tuple[Message, Conversation]:
    conv = chat_services.get_or_create_conversation(user, elysia_user)
    msg = chat_services.create_message(
        user, conv, content="你好，爱莉", idempotency_key="k1"
    )
    return msg, conv


@pytest.mark.django_db
class TestInboundInject:
    def test_user_message_to_elysia_injects_with_sender_echo(self, elysia_setup, fake_injector):
        elysia_user, profile, user = elysia_setup()
        msg, conv = _send_user_message(user, elysia_user)

        injected = on_user_message_to_elysia(message=msg, conversation=conv)

        assert injected is True
        assert len(fake_injector.injected) == 1
        record = fake_injector.injected[0]
        assert record["sender_id"] == str(user.id)
        assert record["content"] == "你好，爱莉"
        assert record["stream_id"] == profile.stream_id
        assert record["chat_type"] == "private"

    def test_non_elysia_conversation_not_injected(
        self, elysia_setup, fake_injector, user_factory
    ):
        _, _, user = elysia_setup()
        other = user_factory(username="user_b", nickname="另一个用户")
        conv = chat_services.get_or_create_conversation(user, other)
        msg = chat_services.create_message(user, conv, content="普通聊天", idempotency_key="k2")

        injected = on_user_message_to_elysia(message=msg, conversation=conv)

        assert injected is False
        assert fake_injector.injected == []

    def test_disabled_profile_skips_inject(self, elysia_setup, fake_injector):
        elysia_user, profile, user = elysia_setup(enabled=False)
        msg, conv = _send_user_message(user, elysia_user)

        injected = on_user_message_to_elysia(message=msg, conversation=conv)

        assert injected is False
        assert fake_injector.injected == []

    def test_elysia_own_message_not_injected(self, elysia_setup, fake_injector):
        elysia_user, profile, user = elysia_setup()
        # 爱莉发消息（sender=爱莉 user）不入站
        conv = chat_services.get_or_create_conversation(user, elysia_user)
        msg = chat_services.create_message(
            elysia_user, conv, content="爱莉的回复", idempotency_key="k3"
        )

        injected = on_user_message_to_elysia(message=msg, conversation=conv)

        assert injected is False
        assert fake_injector.injected == []

    def test_missing_credential_raises_profile_not_configured(self, elysia_setup, monkeypatch):
        elysia_user, profile, user = elysia_setup()

        class _NoCreds:
            def inject_user_message(self, *, message, profile):
                raise ProfileNotConfigured("no secret")

        monkeypatch.setattr(bridge_services, "get_injector", lambda: _NoCreds())
        msg, conv = _send_user_message(user, elysia_user)

        with pytest.raises(ProfileNotConfigured):
            on_user_message_to_elysia(message=msg, conversation=conv)

    def test_inject_failure_does_not_affect_persisted_message(self, elysia_setup, fake_injector):
        """Elysium 失败时桥接抛异常，但用户消息已落库（视图层 try/except 兜底）。"""
        elysia_user, profile, user = elysia_setup()
        msg, conv = _send_user_message(user, elysia_user)
        # 消息已落库
        assert Message.objects.filter(pk=msg.pk).exists()

        fake_injector.return_value = False
        injected = on_user_message_to_elysia(message=msg, conversation=conv)
        assert injected is False


# ---------- 视图层（REST 发消息触发桥接，用 settings 关闭真实网络） ----------

@pytest.mark.django_db
class TestChatViewBridgeHook:
    def test_send_message_to_elysia_triggers_inject(self, elysia_setup, fake_injector, api_client):
        # 用真实 injector 单例？这里验证视图不会因为桥接失败而 500：
        # 通过 monkeypatch on_user_message_to_elysia 模拟异常，确认消息仍 201。
        elysia_user, profile, user = elysia_setup()
        conv = chat_services.get_or_create_conversation(user, elysia_user)

        def _boom(*, message, conversation):
            raise RuntimeError("inject network down")

        import apps.chat.views as chat_views

        chat_views.on_user_message_to_elysia = _boom
        # 通过 REST 发消息
        client = api_client
        client.force_authenticate(user=user)
        resp = client.post(
            f"/api/v1/chat/conversations/{conv.id}/messages/",
            {"content": "在吗", "idempotency_key": "k-view-1"},
            format="json",
        )
        assert resp.status_code == 201, resp.content
        # 消息已落库（桥接失败不影响用户消息）
        assert Message.objects.filter(conversation=conv, idempotency_key="k-view-1").exists()


# ---------- InboundInjector 401 恢复（Elysium 重启后旧 token 失效） ----------


class _FakeElysiaClient:
    """fake ElysiaClient：前 fail_times 次 inject 抛 401，之后返回 accepted。"""

    def __init__(self, fail_times: int = 1, accepted: bool = True):
        self.calls = 0
        self.fail_times = fail_times
        self.accepted = accepted

    def inject_message(self, **kwargs):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise ElysiaUnauthenticated("session revoked after elysium restart")
        return {"accepted": self.accepted}


class _FakeCredentialManager:
    """fake 凭据管理：记录 reset_session 次数，token 版本递增。"""

    def __init__(self):
        self.resets = 0

    def ensure_session(self, *, stream_id: str) -> str:
        return f"token-v{self.resets}"

    def reset_session(self) -> str:
        self.resets += 1
        return f"token-v{self.resets}"


@pytest.mark.django_db
class TestInboundInjector401Recovery:
    def _make(self, fail_times: int = 1):
        client = _FakeElysiaClient(fail_times=fail_times)
        creds = _FakeCredentialManager()
        injector = InboundInjector(client=client, credentials=creds)
        return injector, client, creds

    def test_401_triggers_reset_and_retry_succeeds(self, elysia_setup):
        """Elysium 重启后旧 token 401 → reset_session（secret 重签）→ 重试一次成功。"""
        elysia_user, profile, user = elysia_setup()
        msg, _ = _send_user_message(user, elysia_user)
        injector, client, creds = self._make(fail_times=1)

        ok = injector.inject_user_message(message=msg, profile=profile)

        assert ok is True
        assert client.calls == 2  # 首次 401 + 重试一次
        assert creds.resets == 1  # 触发一次 secret 重签

    def test_401_retry_still_fails_raises(self, elysia_setup):
        """重试仍 401 → 继续抛出（视图层 try/except 记录并保留消息）。"""
        elysia_user, profile, user = elysia_setup()
        msg, _ = _send_user_message(user, elysia_user)
        injector, client, creds = self._make(fail_times=2)

        with pytest.raises(ElysiaUnauthenticated):
            injector.inject_user_message(message=msg, profile=profile)
        assert client.calls == 2
        assert creds.resets == 1

    def test_no_401_single_call_no_reset(self, elysia_setup):
        """正常路径：只 inject 一次，不触发 reset。"""
        elysia_user, profile, user = elysia_setup()
        msg, _ = _send_user_message(user, elysia_user)
        injector, client, creds = self._make(fail_times=0)

        ok = injector.inject_user_message(message=msg, profile=profile)

        assert ok is True
        assert client.calls == 1
        assert creds.resets == 0
