"""AylaInboundOutbox / next_seq 契约测试（D-2，REQUIREMENTS.zh.md §9）。

覆盖：
- 字段与默认值：seq / status / attempts / next_attempt_at / last_error / 时间戳；
- `next_seq()`：单调递增、与 Message.id 解耦、跨事务连续；
- `enqueue_inbound()`：取号与落库在同一事务，回滚时序号与 outbox 一起消失；
- 唯一约束：seq 唯一、message 一对一（同一消息不能重复入队）；
- 索引 `(status, seq)` 存在；
- 级联：消息删除时 outbox 行随之删除。

并发性（行锁串行化）在实现里用「专用序号行 + SELECT ... FOR UPDATE」保证，
本文件只做单进程语义验证；多进程/多线程压测见 models.py docstring 的实测记录。
"""
import pytest
from django.db import IntegrityError, transaction
from django.db.models import Q

from apps.chat.models import Conversation
from apps.chat.services import create_message
from apps.elysia_bridge.models import (
    AylaChannelSequence,
    AylaInboundOutbox,
    next_seq,
    enqueue_inbound,
)


def _conversation(owner):
    return Conversation.objects.create(type=Conversation.TYPE_PRIVATE, owner=owner)


def _message(user, conversation, key="k1"):
    return create_message(user, conversation, content="你好", idempotency_key=key)


@pytest.mark.django_db
class TestNextSeq:
    def test_starts_at_one(self):
        assert next_seq() == 1

    def test_monotonic(self):
        seqs = [next_seq() for _ in range(5)]
        assert seqs == [1, 2, 3, 4, 5]

    def test_independent_of_message_ids(self, user_factory):
        """通道序号不得复用 Message.id（全站主键、跨会话交错）。"""
        owner = user_factory(username="seq_owner")
        conv = _conversation(owner)
        # 先制造几条消息，把 Message.id 推高
        for i in range(3):
            _message(owner, conv, key=f"msg-{i}")
        assert next_seq() == 1

    def test_sequence_row_is_created_once(self):
        next_seq()
        next_seq()
        assert AylaChannelSequence.objects.filter(
            name=AylaChannelSequence.NAME_INBOUND
        ).count() == 1
        row = AylaChannelSequence.objects.get(name=AylaChannelSequence.NAME_INBOUND)
        assert row.last_seq == 2

    def test_rollback_does_not_consume_seq(self):
        """取号在同一事务内；回滚时序号与 outbox 一起消失（不产生空洞）。"""
        with pytest.raises(RuntimeError):
            with transaction.atomic():
                assert next_seq() == 1
                raise RuntimeError("boom")
        assert not AylaInboundOutbox.objects.exists()
        # 回滚后重新取号仍然是 1（序号未被永久消耗）
        assert next_seq() == 1


@pytest.mark.django_db
class TestEnqueueInbound:
    def test_defaults(self, user_factory):
        owner = user_factory(username="outbox_owner")
        msg = _message(owner, _conversation(owner))
        row = enqueue_inbound(msg)

        assert row.message_id == msg.id
        assert row.seq == 1
        assert row.status == AylaInboundOutbox.STATUS_PENDING
        assert row.attempts == 0
        assert row.next_attempt_at is None
        assert row.last_error == ""
        assert row.created_at is not None
        assert row.updated_at is not None
        # 反向关系可用（DSH 侧据此拿 message）
        assert msg.ayla_outbox.seq == 1

    def test_seq_unique(self, user_factory):
        owner = user_factory(username="outbox_uniq")
        conv = _conversation(owner)
        m1 = _message(owner, conv, key="a")
        m2 = _message(owner, conv, key="b")
        enqueue_inbound(m1)
        with pytest.raises(IntegrityError):
            # 手工塞重复序号：必须由 DB 唯一约束拒绝
            AylaInboundOutbox.objects.create(message=m2, seq=1)

    def test_message_one_to_one(self, user_factory):
        owner = user_factory(username="outbox_ooo")
        conv = _conversation(owner)
        msg = _message(owner, conv)
        enqueue_inbound(msg)
        with pytest.raises(IntegrityError):
            AylaInboundOutbox.objects.create(message=msg, seq=99)

    def test_same_transaction_with_message(self, user_factory):
        """Message 与 outbox 同事务：整体回滚后两者都不存在。"""
        owner = user_factory(username="outbox_tx")
        conv = _conversation(owner)
        before_msg = 0
        with pytest.raises(RuntimeError):
            with transaction.atomic():
                msg = _message(owner, conv, key="tx-1")
                enqueue_inbound(msg)
                assert AylaInboundOutbox.objects.filter(message=msg).exists()
                raise RuntimeError("rollback both")
        assert not AylaInboundOutbox.objects.exists()
        # 消息随事务一起回滚（chat.services 内部 atomic 是 savepoint）
        assert conv.messages.count() == before_msg

    def test_seq_not_committed_when_outbox_write_fails(self, user_factory):
        """outbox 写失败时，取号必须一起回滚（不留「已分配但无对应消息」的序号）。

        这正是 `enqueue_inbound()` 自己包 `transaction.atomic()` 的理由：取号依赖
        行锁，若取号单独提交，锁会当场释放而 outbox 尚未写入，崩溃即产生空洞。
        """
        owner = user_factory(username="outbox_atomic")
        conv = _conversation(owner)
        first = _message(owner, conv, key="first")
        enqueue_inbound(first)  # 占用 seq=1 与它的 message
        second = _message(owner, conv, key="second")

        # 强制 outbox 插入失败（模拟唯一键冲突）：同一 message 重复登记
        with pytest.raises(IntegrityError):
            enqueue_inbound(first)

        # 失败的取号没有留下痕迹：序号未推进到 2
        row = AylaChannelSequence.objects.get(name=AylaChannelSequence.NAME_INBOUND)
        assert row.last_seq == 1
        assert not AylaInboundOutbox.objects.filter(message=second).exists()
        # 下一次取号仍从 2 开始（无空洞）
        assert enqueue_inbound(second).seq == 2

    def test_cascade_delete_with_message(self, user_factory):
        owner = user_factory(username="outbox_cascade")
        msg = _message(owner, _conversation(owner))
        row = enqueue_inbound(msg)
        row_id = row.id
        msg.delete()
        assert not AylaInboundOutbox.objects.filter(pk=row_id).exists()

    def test_multiple_messages_get_ordered_seqs(self, user_factory):
        owner = user_factory(username="outbox_multi")
        conv = _conversation(owner)
        seqs = []
        for i in range(3):
            msg = _message(owner, conv, key=f"m-{i}")
            seqs.append(enqueue_inbound(msg).seq)
        assert seqs == [1, 2, 3]

    def test_status_transitions_persist(self, user_factory):
        owner = user_factory(username="outbox_status")
        row = enqueue_inbound(_message(owner, _conversation(owner)))
        row.status = AylaInboundOutbox.STATUS_DELIVERED
        row.attempts = 1
        row.save(update_fields=["status", "attempts", "updated_at"])
        row.refresh_from_db()
        assert row.status == "delivered"
        assert row.attempts == 1

    def test_status_code_values(self):
        """状态码是协议契约（DSH ack / 重投上限），不得随意改名。"""
        assert AylaInboundOutbox.STATUS_PENDING == "pending"
        assert AylaInboundOutbox.STATUS_DELIVERED == "delivered"
        assert AylaInboundOutbox.STATUS_FAILED == "failed"
        assert AylaInboundOutbox.STATUS_DEAD == "dead"


@pytest.mark.django_db
class TestOutboxIndex:
    def test_status_seq_index_exists(self):
        """(status, seq) 索引供补投扫描使用（DEVELOPMENT §3）。"""
        from django.db import connection

        with connection.cursor() as cursor:
            constraints = connection.introspection.get_constraints(
                cursor, AylaInboundOutbox._meta.db_table
            )
        indexed_columns = [
            tuple(info["columns"])
            for info in constraints.values()
            if info["index"] and info.get("columns")
        ]
        assert ("status", "seq") in indexed_columns
