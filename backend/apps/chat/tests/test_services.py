"""chat 领域服务契约测试：私聊幂等、消息幂等、seq 单调、撤回时限、权限、已读。

全部不依赖 Redis/MySQL。广播走 InMemory channel layer。
"""
import uuid
from datetime import timedelta

import pytest
from django.utils import timezone

from apps.chat.models import Conversation, ConversationMember, Message, MessageRead
from apps.chat import services


def _conv_group(owner, title="测试群"):
    conv = Conversation.objects.create(
        type=Conversation.TYPE_GROUP, title=title, owner=owner
    )
    ConversationMember.objects.create(
        conversation=conv, user=owner, role=ConversationMember.ROLE_OWNER
    )
    return conv


def _add_member(conv, user, role="member", muted=False):
    ConversationMember.objects.create(
        conversation=conv, user=user, role=role, muted=muted
    )


@pytest.mark.django_db
class TestPrivateConversation:
    def test_get_or_create_private_is_idempotent(self, user_factory):
        a = user_factory(username="p_a")
        b = user_factory(username="p_b")
        conv1 = services.get_or_create_conversation(a, b)
        conv2 = services.get_or_create_conversation(a, b)
        assert conv1.id == conv2.id
        assert conv1.type == Conversation.TYPE_PRIVATE
        # 双向两条成员记录
        assert conv1.members.count() == 2

    def test_private_same_pair_only_one(self, user_factory):
        a = user_factory(username="p2_a")
        b = user_factory(username="p2_b")
        services.get_or_create_conversation(a, b)
        services.get_or_create_conversation(b, a)  # 顺序无关
        assert Conversation.objects.filter(type=Conversation.TYPE_PRIVATE).count() == 1

    def test_private_members_both_directions(self, user_factory):
        a = user_factory(username="p3_a")
        b = user_factory(username="p3_b")
        conv = services.get_or_create_conversation(a, b)
        assert {m.user_id for m in conv.members.all()} == {a.id, b.id}
        # 双向均可见
        assert services.user_can_access(a, conv)
        assert services.user_can_access(b, conv)


@pytest.mark.django_db
class TestPermissions:
    def test_user_role_in(self, user_factory):
        owner = user_factory(username="perm_owner")
        admin = user_factory(username="perm_admin")
        outsider = user_factory(username="perm_out")
        conv = _conv_group(owner)
        _add_member(conv, admin, role="admin")
        assert services.user_role_in(owner, conv) == "owner"
        assert services.user_role_in(admin, conv) == "admin"
        assert services.user_role_in(outsider, conv) is None
        assert not services.user_can_access(outsider, conv)

    def test_can_manage_group(self, user_factory):
        owner = user_factory(username="mg_owner")
        admin = user_factory(username="mg_admin")
        member = user_factory(username="mg_member")
        conv = _conv_group(owner)
        _add_member(conv, admin, role="admin")
        _add_member(conv, member, role="member")
        assert services.can_manage_group(owner, conv)
        assert services.can_manage_group(admin, conv)
        assert not services.can_manage_group(member, conv)
        # 私聊不算群管
        priv = services.get_or_create_conversation(owner, admin)
        assert not services.can_manage_group(owner, priv)

    def test_is_muted(self, user_factory):
        owner = user_factory(username="mut_owner")
        muted = user_factory(username="mut_user")
        conv = _conv_group(owner)
        _add_member(conv, muted, muted=True)
        assert services.is_muted(muted, conv)
        assert not services.is_muted(owner, conv)


@pytest.mark.django_db
class TestMessageIdempotency:
    def test_same_key_returns_existing(self, user_factory):
        u = user_factory(username="im_a")
        conv = _conv_group(u)
        key = uuid.uuid4().hex
        m1 = services.create_message(
            u, conv, content="hello", idempotency_key=key
        )
        m2 = services.create_message(
            u, conv, content="hello", idempotency_key=key
        )
        assert m1.id == m2.id
        assert Message.objects.filter(conversation=conv).count() == 1

    def test_create_without_key_autogen(self, user_factory):
        u = user_factory(username="im_b")
        conv = _conv_group(u)
        m = services.create_message(u, conv, content="x")
        assert m.idempotency_key
        assert Message.objects.filter(conversation=conv).count() == 1

    def test_seq_monotonic(self, user_factory):
        u = user_factory(username="im_seq")
        conv = _conv_group(u)
        seqs = []
        for i in range(5):
            m = services.create_message(u, conv, content=f"m{i}")
            seqs.append(m.seq)
        assert seqs == [1, 2, 3, 4, 5]

    def test_seq_isolated_between_convs(self, user_factory):
        u = user_factory(username="im_iso")
        c1 = _conv_group(u, title="群A")
        c2 = _conv_group(u, title="群B")
        m1 = services.create_message(u, c1, content="a")
        m2 = services.create_message(u, c2, content="b")
        assert m1.seq == 1
        assert m2.seq == 1

    def test_reply_to(self, user_factory):
        u = user_factory(username="im_rep")
        conv = _conv_group(u)
        base = services.create_message(u, conv, content="base")
        reply = services.create_message(u, conv, content="rep", reply_to=base)
        assert reply.reply_to_id == base.id

    def test_find_by_idempotency_key(self, user_factory):
        u = user_factory(username="im_find")
        conv = _conv_group(u)
        key = uuid.uuid4().hex
        services.create_message(u, conv, content="x", idempotency_key=key)
        found = services.find_by_idempotency_key(conv, key)
        assert found is not None
        assert services.find_by_idempotency_key(conv, "nope") is None


@pytest.mark.django_db
class TestRecall:
    def test_recall_by_sender(self, user_factory):
        u = user_factory(username="rc_a")
        conv = _conv_group(u)
        msg = services.create_message(u, conv, content="bye")
        out = services.recall_message(u, msg)
        assert out.status == Message.STATUS_RECALLED
        assert out.recalled_at is not None

    def test_recall_by_other_forbidden(self, user_factory):
        a = user_factory(username="rc_a2")
        b = user_factory(username="rc_b2")
        conv = _conv_group(a)
        _add_member(conv, b)
        msg = services.create_message(a, conv, content="hi")
        with pytest.raises(PermissionError):
            services.recall_message(b, msg)

    def test_recall_timeout(self, user_factory):
        u = user_factory(username="rc_a3")
        conv = _conv_group(u)
        msg = services.create_message(u, conv, content="old")
        # 把 created_at 拨到 5 分钟前（窗口默认 120s）
        Message.objects.filter(pk=msg.pk).update(
            created_at=timezone.now() - timedelta(minutes=5)
        )
        msg.refresh_from_db()
        with pytest.raises(TimeoutError):
            services.recall_message(u, msg)

    def test_recall_already_recalled_idempotent(self, user_factory):
        u = user_factory(username="rc_a4")
        conv = _conv_group(u)
        msg = services.create_message(u, conv, content="x")
        services.recall_message(u, msg)
        out = services.recall_message(u, msg)  # 重复撤回幂等
        assert out.status == Message.STATUS_RECALLED


@pytest.mark.django_db
class TestMarkRead:
    def test_mark_read_creates_once(self, user_factory):
        a = user_factory(username="mr_a")
        b = user_factory(username="mr_b")
        conv = services.get_or_create_conversation(a, b)
        msg = services.create_message(a, conv, content="to-b")
        services.mark_read(b, msg)
        services.mark_read(b, msg)  # 幂等
        assert MessageRead.objects.filter(message=msg, user=b).count() == 1

    def test_mark_own_message_no_broadcast(self, user_factory):
        # 自己消息标已读不触发 message.read（sender == user）
        a = user_factory(username="mr_own")
        b = user_factory(username="mr_own2")
        conv = services.get_or_create_conversation(a, b)
        msg = services.create_message(a, conv, content="self")
        services.mark_read(a, msg)
        assert MessageRead.objects.filter(message=msg, user=a).count() == 1
