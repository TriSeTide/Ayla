"""群聊可见消息的精确已读确认；使用隔离 ORM 数据避开会话序列化。"""

from unittest.mock import AsyncMock

import pytest

from apps.chat import services
from apps.chat.consumers import ChatConsumer
from apps.chat.models import Conversation, ConversationMember, GroupSubGroup, Message, MessageRead


pytestmark = pytest.mark.django_db


@pytest.fixture
def read_group(auth_client, user_factory, monkeypatch):
    client, reader = auth_client(username="read_receipt_reader")
    sender = user_factory(username="read_receipt_sender")
    conversation = Conversation.objects.create(type=Conversation.TYPE_GROUP, owner=reader)
    for user in (reader, sender):
        ConversationMember.objects.create(conversation=conversation, user=user)
    default = GroupSubGroup.objects.create(
        conversation=conversation, name="默认组", is_default=True
    )
    subgroup = GroupSubGroup.objects.create(conversation=conversation, name="子群")
    events = []
    monkeypatch.setattr(services, "_group_send_sync", lambda conv_id, event: events.append(event))
    return client, reader, sender, conversation, default, subgroup, events


def _message(conversation, subgroup, sender, seq, **extra):
    return Message.objects.create(
        conversation=conversation,
        subgroup=subgroup,
        sender=sender,
        seq=seq,
        idempotency_key=f"read-receipt-{conversation.pk}-{seq}",
        **extra,
    )


def _exact_read(client, conversation, message):
    return client.post(
        f"/api/v1/chat/conversations/{conversation.pk}/messages/{message.pk}/read/",
        {"exact": True},
        format="json",
    )


def _subgroup_read(client, conversation, subgroup):
    return client.post(
        f"/api/v1/chat/conversations/{conversation.pk}/subgroups/{subgroup.pk}/read/"
    )


def test_exact_read_only_confirms_seen_message_and_retries_repair_lost_ack(read_group):
    client, reader, sender, conversation, default, subgroup, events = read_group
    earlier = _message(conversation, subgroup, sender, 1)
    elsewhere = _message(conversation, default, sender, 2)
    seen = _message(conversation, subgroup, sender, 3)
    later = _message(conversation, subgroup, sender, 4)

    response = _exact_read(client, conversation, seen)

    assert response.status_code == 200
    assert response.json()["marked_seqs"] == [3]
    assert response.json()["subgroup_id"] == str(subgroup.pk)
    assert list(MessageRead.objects.filter(user=reader).values_list("message_id", flat=True)) == [seen.pk]
    assert not MessageRead.objects.filter(message__in=[earlier, elsewhere, later], user=reader).exists()
    subgroup_events = [event for event in events if event["type"] == "chat.subgroup.read"]
    assert subgroup_events[-1] == {
        "type": "chat.subgroup.read",
        "conversation_id": str(conversation.pk),
        "subgroup_id": str(subgroup.pk),
        "user_id": reader.pk,
        "marked": 1,
        "marked_seqs": [3],
    }

    # 首次响应/事件即使丢失，重试不能只返回空集合，否则客户端无法收敛红点。
    retried = _exact_read(client, conversation, seen)
    assert retried.json()["marked_seqs"] == [3]
    subgroup_events = [event for event in events if event["type"] == "chat.subgroup.read"]
    assert subgroup_events[-1]["marked"] == 0
    assert subgroup_events[-1]["marked_seqs"] == [3]
    assert MessageRead.objects.filter(message=seen, user=reader).count() == 1


@pytest.mark.parametrize("legacy", [False, True])
def test_exact_default_and_legacy_messages_broadcast_default_subgroup(read_group, legacy):
    client, reader, sender, conversation, default, _, events = read_group
    message = _message(conversation, None if legacy else default, sender, 1)
    unseen = _message(conversation, default, sender, 2)

    response = _exact_read(client, conversation, message)
    assert response.json()["marked_seqs"] == [1]
    assert response.json()["subgroup_id"] == str(default.pk)
    assert not MessageRead.objects.filter(message=unseen, user=reader).exists()
    subgroup_events = [event for event in events if event["type"] == "chat.subgroup.read"]
    assert subgroup_events[-1]["subgroup_id"] == str(default.pk)
    assert subgroup_events[-1]["marked_seqs"] == [1]


def test_explicit_full_read_keeps_legacy_count_and_confirms_precise_scope(read_group):
    client, reader, sender, conversation, default, subgroup, events = read_group
    already = _message(conversation, subgroup, sender, 1)
    MessageRead.objects.create(message=already, user=reader)
    _message(conversation, subgroup, sender, 2)
    _message(conversation, default, sender, 3)
    _message(conversation, subgroup, reader, 4)
    _message(conversation, subgroup, sender, 5, status=Message.STATUS_RECALLED)
    _message(conversation, subgroup, sender, 6, type=Message.TYPE_POKE)

    response = _subgroup_read(client, conversation, subgroup)

    assert response.status_code == 200
    assert response.json() == {"marked": 1, "marked_seqs": [1, 2]}
    assert set(MessageRead.objects.filter(user=reader).values_list("message__seq", flat=True)) == {1, 2}
    assert events[-1]["marked_seqs"] == [1, 2]
    assert _subgroup_read(client, conversation, subgroup).json() == {"marked": 0, "marked_seqs": [1, 2]}


def test_explicit_default_read_includes_legacy_but_not_other_subgroups(read_group):
    client, reader, sender, conversation, default, subgroup, _ = read_group
    _message(conversation, None, sender, 1)
    _message(conversation, default, sender, 2)
    _message(conversation, subgroup, sender, 3)

    response = _subgroup_read(client, conversation, default)

    assert response.json() == {"marked": 2, "marked_seqs": [1, 2]}
    assert set(MessageRead.objects.filter(user=reader).values_list("message__seq", flat=True)) == {1, 2}


def test_message_arriving_during_receipt_write_stays_unread(read_group, monkeypatch):
    client, reader, sender, conversation, _, subgroup, events = read_group
    _message(conversation, subgroup, sender, 1)
    original_bulk_create = MessageRead.objects.bulk_create

    def create_after_snapshot(rows, **kwargs):
        _message(conversation, subgroup, sender, 2)
        return original_bulk_create(rows, **kwargs)

    monkeypatch.setattr(MessageRead.objects, "bulk_create", create_after_snapshot)

    response = _subgroup_read(client, conversation, subgroup)

    assert response.json() == {"marked": 1, "marked_seqs": [1]}
    assert events[-1]["marked_seqs"] == [1]
    assert list(services.subgroup_unread_queryset(subgroup, reader).values_list("seq", flat=True)) == [2]


def test_write_failure_does_not_broadcast_success(read_group, monkeypatch):
    _, reader, sender, conversation, _, subgroup, events = read_group
    seen = _message(conversation, subgroup, sender, 1)

    def fail_write(*args, **kwargs):
        raise RuntimeError("receipt write unavailable")

    monkeypatch.setattr(MessageRead.objects, "bulk_create", fail_write)
    with pytest.raises(RuntimeError, match="receipt write unavailable"):
        services.mark_read(reader, seen, through=False)
    assert events == []
    assert not MessageRead.objects.filter(user=reader).exists()


def test_read_permissions_and_foreign_message_subgroup_are_enforced(read_group, auth_client):
    client, reader, sender, conversation, _, subgroup, _ = read_group
    seen = _message(conversation, subgroup, sender, 1)
    outsider_client, outsider = auth_client(username="read_receipt_outsider")
    assert _exact_read(outsider_client, conversation, seen).status_code == 403
    assert _subgroup_read(outsider_client, conversation, subgroup).status_code == 403

    foreign = Conversation.objects.create(type=Conversation.TYPE_GROUP, owner=outsider)
    foreign_subgroup = GroupSubGroup.objects.create(conversation=foreign, name="外群")
    foreign_message = _message(foreign, foreign_subgroup, outsider, 1)
    assert _exact_read(client, conversation, foreign_message).status_code == 404
    assert _subgroup_read(client, conversation, foreign_subgroup).status_code == 404
    assert not MessageRead.objects.filter(user=reader).exists()


def test_private_exact_and_legacy_through_semantics_are_unchanged(read_group):
    client, reader, sender, _, _, _, events = read_group
    private = services.get_or_create_conversation(reader, sender)
    messages = [_message(private, None, sender, seq) for seq in range(1, 5)]

    exact_response = _exact_read(client, private, messages[2])
    assert exact_response.json()["marked_seqs"] == [3]
    assert "subgroup_id" not in exact_response.json()
    assert set(MessageRead.objects.filter(user=reader).values_list("message__seq", flat=True)) == {3}
    response = client.post(
        f"/api/v1/chat/conversations/{private.pk}/messages/{messages[1].pk}/read/"
    )
    assert response.json()["marked_seqs"] == [1, 2]
    assert set(MessageRead.objects.filter(user=reader).values_list("message__seq", flat=True)) == {1, 2, 3}
    assert [event["type"] for event in events] == ["chat.message.read", "chat.message.read"]


@pytest.mark.asyncio
@pytest.mark.parametrize("receipt", [{"marked_seqs": [4, 9]}, {}])
async def test_subgroup_read_consumer_preserves_exact_confirmation(receipt):
    consumer = ChatConsumer()
    consumer.send_json = AsyncMock()
    await consumer.chat_subgroup_read({
        "conversation_id": "10", "subgroup_id": "20", "user_id": 30,
        "marked": 0, **receipt,
    })
    consumer.send_json.assert_awaited_once_with({
        "type": "subgroup.read",
        "data": {
            "conversation_id": "10", "subgroup_id": "20", "user_id": "30",
            "marked": 0, **receipt,
        },
    })
