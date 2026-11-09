"""入站注入语义的保留部分契约测试。

背景：旧爱莉桥接（`on_user_message_to_elysia` / `InboundInjector` / service
credential）已按 REQUIREMENTS.zh.md §13 整体删除，旧 inject 测试随之作废。
本文件只保留与"谁的消息应该进入爱莉通道"有关的**判定语义**，不测已不存在的
传输实现：

- 非爱莉会话 → 不进爱莉通道；
- 爱莉本人发的消息 → 不入站（她自己的发言不是给她的输入）；
- 爱莉私聊的判定只看身份绑定（ElysiaProfile 存在），不看 enabled 开关。

旧文件里 `:172-174` 的 monkeypatch 是无效的（`chat/views.py` 是函数内 import，
模块级没有该属性），原先"通过"是因为异常被 `except` 吞掉。这里不再复制该模式。
"""
import pytest

from apps.chat import services as chat_services
from apps.chat.models import Message
from apps.elysia_bridge.models import ElysiaProfile


@pytest.fixture
def elysia_setup(db, user_factory):
    """创建爱莉 user + profile，以及一个普通用户。"""

    def _make(*, enabled: bool = True):
        elysia_user = user_factory(username="elysia_core", nickname="爱莉")
        elysia_user.save()
        profile = ElysiaProfile.objects.create(
            user=elysia_user, enabled=enabled, display_name="爱莉"
        )
        user = user_factory(username="user_a", nickname="汐汐")
        return elysia_user, profile, user

    return _make


def _send(user, conversation, content: str, key: str) -> Message:
    """直接经 service 层落库（本文件只验判定语义，不走 HTTP）。"""
    return chat_services.create_message(
        user, conversation, content=content, idempotency_key=key
    )


@pytest.mark.django_db
class TestElysiaPrivateChannelSemantics:
    def test_non_elysia_conversation_is_not_elysia_channel(self, elysia_setup, user_factory):
        """非爱莉会话：双方都不是爱莉 → 不进入爱莉通道。"""
        _, _, user = elysia_setup()
        other = user_factory(username="user_b", nickname="另一个用户")
        conv = chat_services.get_or_create_conversation(user, other)

        assert chat_services.is_elysia_user(user) is False
        assert chat_services.is_elysia_user(other) is False
        assert _conversation_has_elysia(conv) is False

    def test_elysia_conversation_is_detected(self, elysia_setup):
        """爱莉参与的会话 → 识别为爱莉通道，普通用户侧判定为"可投递"。"""
        elysia_user, profile, user = elysia_setup()
        conv = chat_services.get_or_create_conversation(user, elysia_user)

        assert chat_services.is_elysia_user(elysia_user) is True
        assert chat_services.is_elysia_user(user) is False
        assert _conversation_has_elysia(conv) is True

    def test_elysia_own_message_is_not_inbound(self, elysia_setup):
        """爱莉本人发的消息不入站：sender 是爱莉 → 不是给她的输入。"""
        elysia_user, profile, user = elysia_setup()
        conv = chat_services.get_or_create_conversation(user, elysia_user)
        msg = _send(elysia_user, conv, "爱莉的回复", "k-own")

        assert msg.sender_id == elysia_user.id
        assert _is_inbound_candidate(msg, elysia_profile=profile) is False

    def test_user_message_is_inbound_candidate(self, elysia_setup):
        """普通用户发给爱莉的消息是入站候选（sender 不是爱莉）。"""
        elysia_user, profile, user = elysia_setup()
        conv = chat_services.get_or_create_conversation(user, elysia_user)
        msg = _send(user, conv, "你好，爱莉", "k-in")

        assert msg.sender_id == user.id
        assert _is_inbound_candidate(msg, elysia_profile=profile) is True

    def test_disabled_profile_keeps_private_send_allowed(self, elysia_setup):
        """enabled=False 只影响通道投递，不影响"爱莉私聊免好友校验"。"""
        elysia_user, profile, user = elysia_setup(enabled=False)

        assert chat_services.is_elysia_user(elysia_user) is True
        assert chat_services.can_send_private_message(user, elysia_user) is True
        assert chat_services.can_send_private_message(elysia_user, user) is True

    def test_non_elysia_private_still_requires_friendship(self, elysia_setup, user_factory):
        """没有爱莉参与的私聊仍走好友校验（本任务不得放宽）。"""
        _, _, user = elysia_setup()
        other = user_factory(username="user_c", nickname="第三者")

        assert chat_services.can_send_private_message(user, other) is False


# ---------- 判定辅助（本地实现，不依赖任何已删除的传输层） ----------


def _conversation_has_elysia(conversation) -> bool:
    """该会话的参与者里是否有爱莉（是否属于爱莉通道）。"""
    return any(
        chat_services.is_elysia_user(member.user)
        for member in conversation.members.select_related("user")
    )


def _is_inbound_candidate(message, *, elysia_profile) -> bool:
    """该消息是否应作为"给爱莉的输入"进入爱莉通道。

    判定只有两条，且都不是认知裁决：
    1. 发送者不是爱莉本人（她自己说的话不是给她的输入）；
    2. 会话对端是爱莉。
    """
    if message.sender_id == elysia_profile.user_id:
        return False
    return _conversation_has_elysia(message.conversation)
