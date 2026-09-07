"""子群最近消息序号契约；只用隔离 ORM 数据，不经过会话序列化。"""

import pytest

from apps.chat.models import Conversation, ConversationMember, GroupSubGroup, Message, MessageRead


pytestmark = pytest.mark.django_db


def _make_group(owner):
    conversation = Conversation.objects.create(type=Conversation.TYPE_GROUP, owner=owner)
    ConversationMember.objects.create(
        conversation=conversation, user=owner, role=ConversationMember.ROLE_OWNER
    )
    default = GroupSubGroup.objects.create(
        conversation=conversation, name="默认组", is_default=True
    )
    return conversation, default


@pytest.fixture
def activity_group(auth_client, user_factory):
    client, owner = auth_client(username="activity_owner")
    peer = user_factory(username="activity_peer")
    conversation, default = _make_group(owner)
    ConversationMember.objects.create(conversation=conversation, user=peer)
    return client, owner, peer, conversation, default


def _message(conversation, subgroup, sender, seq, **extra):
    return Message.objects.create(
        conversation=conversation,
        subgroup=subgroup,
        sender=sender,
        seq=seq,
        idempotency_key=f"subgroup-activity-{conversation.pk}-{seq}",
        **extra,
    )


def _subgroups(client, conversation):
    response = client.get(f"/api/v1/chat/conversations/{conversation.pk}/subgroups/")
    assert response.status_code == 200, response.content
    return {item["id"]: item for item in response.json()}


def test_empty_subgroups_report_zero(activity_group):
    client, _, _, conversation, default = activity_group
    empty = GroupSubGroup.objects.create(conversation=conversation, name="空子群")

    items = _subgroups(client, conversation)

    assert items[str(default.pk)]["last_message_seq"] == 0
    assert items[str(empty.pk)]["last_message_seq"] == 0


@pytest.mark.parametrize("latest_kind", ["own", "read", "recalled", "poke"])
def test_latest_activity_does_not_depend_on_unread(activity_group, latest_kind):
    client, owner, peer, conversation, _ = activity_group
    subgroup = GroupSubGroup.objects.create(conversation=conversation, name="聊天")
    _message(conversation, subgroup, owner, 2)
    latest = _message(
        conversation,
        subgroup,
        owner if latest_kind == "own" else peer,
        9,
        type=Message.TYPE_POKE if latest_kind == "poke" else Message.TYPE_TEXT,
        status=Message.STATUS_RECALLED if latest_kind == "recalled" else Message.STATUS_SENT,
    )
    if latest_kind == "read":
        MessageRead.objects.create(message=latest, user=owner)

    item = _subgroups(client, conversation)[str(subgroup.pk)]

    assert item["unread_count"] == 0
    assert item["last_message_seq"] == 9


@pytest.mark.parametrize("default_seq,legacy_seq", [(8, 13), (13, 8)])
def test_default_merges_legacy_messages_without_cross_group_leak(
    activity_group, default_seq, legacy_seq
):
    client, owner, _, conversation, default = activity_group
    other = GroupSubGroup.objects.create(conversation=conversation, name="其他子群")
    _message(conversation, default, owner, default_seq)
    _message(conversation, None, owner, legacy_seq)
    _message(conversation, other, owner, 20)
    foreign_conversation, foreign_default = _make_group(owner)
    _message(foreign_conversation, None, owner, 99)
    _message(foreign_conversation, foreign_default, owner, 100)

    items = _subgroups(client, conversation)

    assert set(items) == {str(default.pk), str(other.pk)}
    assert items[str(default.pk)]["last_message_seq"] == 13
    assert items[str(other.pk)]["last_message_seq"] == 20


def test_read_and_reload_keep_activity_then_observe_new_message(activity_group):
    client, _, peer, conversation, _ = activity_group
    subgroup = GroupSubGroup.objects.create(conversation=conversation, name="聊天")
    _message(conversation, subgroup, peer, 3)
    first = _subgroups(client, conversation)[str(subgroup.pk)]
    assert first["unread_count"] == 1
    assert first["last_message_seq"] == 3

    response = client.post(
        f"/api/v1/chat/conversations/{conversation.pk}/subgroups/{subgroup.pk}/read/"
    )
    assert response.status_code == 200, response.content
    read = _subgroups(client, conversation)[str(subgroup.pk)]
    assert read["unread_count"] == 0
    assert read["last_message_seq"] == 3

    _message(conversation, subgroup, peer, 12)
    refreshed = _subgroups(client, conversation)[str(subgroup.pk)]
    assert refreshed["unread_count"] == 1
    assert refreshed["last_message_seq"] == 12


def test_create_and_update_return_activity(activity_group):
    client, owner, _, conversation, default = activity_group
    endpoint = f"/api/v1/chat/conversations/{conversation.pk}/subgroups/"
    response = client.post(endpoint, {"name": "新子群"}, format="json")
    assert response.status_code == 201, response.content
    created = response.json()
    assert created["last_message_seq"] == 0

    subgroup = GroupSubGroup.objects.get(pk=created["id"])
    _message(conversation, subgroup, owner, 7)
    response = client.patch(
        f"{endpoint}{subgroup.pk}/", {"name": "更名子群"}, format="json"
    )
    assert response.status_code == 200, response.content
    assert response.json()["last_message_seq"] == 7

    _message(conversation, None, owner, 11)
    response = client.patch(
        f"{endpoint}{default.pk}/", {"muted": True}, format="json"
    )
    assert response.status_code == 200, response.content
    assert response.json()["last_message_seq"] == 11
