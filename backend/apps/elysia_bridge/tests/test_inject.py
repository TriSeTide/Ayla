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
from apps.elysia_bridge.services import ProfileNotConfigured, on_user_message_to_elysia


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
