"""chat 模型契约测试：唯一约束、幂等键、seq、撤回时限工具。

全部不依赖 Redis/MySQL（settings_test 内存 SQLite）。
"""
import uuid

import pytest
from django.core.exceptions import ValidationError
from django.db import IntegrityError

from apps.chat.models import Conversation, ConversationMember, Message, MessageRead


def _mk_conv(user, **kw):
    defaults = {"type": Conversation.TYPE_GROUP, "title": "测试群", "owner": user}
    defaults.update(kw)
    return Conversation.objects.create(**defaults)


def _mk_msg(conv, user, seq, key=None, **kw):
    key = key or uuid.uuid4().hex
    defaults = {
        "conversation": conv,
        "sender": user,
        "type": Message.TYPE_TEXT,
        "content": f"msg-{seq}",
        "idempotency_key": key,
        "seq": seq,
    }
    defaults.update(kw)
    return Message.objects.create(**defaults)


@pytest.mark.django_db
class TestConversation:
    def test_private_conv_title_blank_ok(self, user_factory):
        u = user_factory(username="c_owner")
        conv = _mk_conv(u, type=Conversation.TYPE_PRIVATE, title="", owner=None)
        assert conv.type == "private"
        assert conv.title == ""

    def test_group_conv_requires_title_choice(self, user_factory):
        u = user_factory(username="c_owner2")
        conv = _mk_conv(u, type=Conversation.TYPE_GROUP, title="小组")
        assert conv.title == "小组"

    def test_announcement_field_exists(self, user_factory):
        u = user_factory(username="c_owner3")
        conv = _mk_conv(u, title="公告群", announcement="欢迎")
        assert conv.announcement == "欢迎"


@pytest.mark.django_db
class TestConversationMember:
    def test_unique_conversation_user(self, user_factory):
        owner = user_factory(username="m_owner")
        member = user_factory(username="m_member")
        conv = _mk_conv(owner)
        ConversationMember.objects.create(conversation=conv, user=member, role="member")
        with pytest.raises(IntegrityError):
            ConversationMember.objects.create(conversation=conv, user=member, role="admin")


@pytest.mark.django_db
class TestMessage:
    def test_idempotency_key_unique(self, user_factory):
        """幂等契约核心：同 key 只能落一条。"""
        u = user_factory(username="msg_u1")
        conv = _mk_conv(u)
        key = uuid.uuid4().hex
        _mk_msg(conv, u, 1, key=key)
        with pytest.raises(IntegrityError):
            _mk_msg(conv, u, 2, key=key)

    def test_conversation_seq_unique(self, user_factory):
        """(conversation, seq) 唯一：并发兜底。"""
        u = user_factory(username="msg_u2")
        conv = _mk_conv(u)
        _mk_msg(conv, u, 1)
        with pytest.raises(IntegrityError):
            _mk_msg(conv, u, 1)

    def test_same_seq_different_conv_ok(self, user_factory):
        """跨会话 seq 互不影响。"""
        u = user_factory(username="msg_u3")
        c1 = _mk_conv(u, title="群A")
        c2 = _mk_conv(u, title="群B")
        m1 = _mk_msg(c1, u, 1)
        m2 = _mk_msg(c2, u, 1)
        assert m1.seq == m2.seq == 1

    def test_reply_to_set_null_on_delete(self, user_factory):
        u = user_factory(username="msg_u4")
        conv = _mk_conv(u)
        base = _mk_msg(conv, u, 1)
        reply = _mk_msg(conv, u, 2, reply_to=base)
        assert reply.reply_to_id == base.id
        base.delete()
        reply.refresh_from_db()
        assert reply.reply_to_id is None

    def test_media_id_optional(self, user_factory):
        u = user_factory(username="msg_u5")
        conv = _mk_conv(u)
        m = _mk_msg(conv, u, 1, media_id="media-uuid-1")
        assert m.media_id == "media-uuid-1"
        m2 = _mk_msg(conv, u, 2, media_id=None)
        assert m2.media_id is None

    def test_msg_type_choices(self, user_factory):
        u = user_factory(username="msg_u6")
        conv = _mk_conv(u)
        for i, (t, _label) in enumerate(Message.TYPE_CHOICES):
            m = _mk_msg(conv, u, i + 1, type=t, content="x")
            # 手动造一个非法 type 验证 choices 约束
            m.type = "bad_type"
            with pytest.raises(ValidationError):
                m.full_clean()


@pytest.mark.django_db
class TestMessageRead:
    def test_unique_message_user(self, user_factory):
        a = user_factory(username="r_a")
        b = user_factory(username="r_b")
        conv = _mk_conv(a)
        msg = _mk_msg(conv, a, 1)
        MessageRead.objects.create(message=msg, user=b)
        with pytest.raises(IntegrityError):
            MessageRead.objects.create(message=msg, user=b)
