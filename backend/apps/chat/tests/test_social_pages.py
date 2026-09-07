"""Visible directories and subscription registrations are different contracts."""
from urllib.parse import urlencode

import pytest
from datetime import timedelta
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.chat.models import Conversation, ConversationMember, GroupJoinRequest, GroupSubGroup, Message


def page(client, path, **params):
    return client.get(path + "?" + urlencode({"pagination": "cursor", "limit": 2, **params}))


def group(owner, title="a group"):
    conversation = Conversation.objects.create(type="group", title=title, owner=owner)
    ConversationMember.objects.create(conversation=conversation, user=owner, role="owner")
    GroupSubGroup.objects.create(conversation=conversation, name="默认组", is_default=True)
    return conversation


@pytest.mark.django_db
def test_directory_rows_are_compact_and_legacy_detail_is_complete(auth_client, user_factory):
    client, actor = auth_client(username="directory_actor")
    target = group(actor)
    people = [user_factory(username=f"directory_member_{index}") for index in range(5)]
    for person in people:
        ConversationMember.objects.create(conversation=target, user=person)
    for index in range(3):
        group(actor, f"directory_{index}")
    first = page(client, "/api/v1/chat/conversations/", type="group").json()
    second = page(client, "/api/v1/chat/conversations/", type="group", cursor=first["next_cursor"]).json()
    assert first["total"] == 4 and len(first["results"]) == 2
    rows = first["results"] + second["results"]
    assert len({row["id"] for row in rows}) == 4
    row = next(row for row in rows if row["id"] == str(target.pk))
    assert row["members"] == [] and row["members_complete"] is False and row["member_count"] == 6
    assert row["my_role"] == "owner" and row["unread_seqs_complete"] is False
    assert "unread_seqs" not in row
    legacy = client.get(f"/api/v1/chat/conversations/{target.pk}/").json()
    metadata = client.get(f"/api/v1/chat/conversations/{target.pk}/?metadata=1").json()
    assert len(legacy["members"]) == 6
    assert metadata["members"] == [] and metadata["member_count"] == 6
    assert metadata["my_role"] == "owner" and metadata["my_muted"] is False
    assert isinstance(client.get("/api/v1/chat/conversations/").json(), list)


@pytest.mark.django_db
def test_member_pages_search_outside_first_page_and_recheck_authorization(auth_client, user_factory):
    client, actor = auth_client(username="members_actor")
    target = group(actor)
    another = group(actor, "another")
    people = [user_factory(username=f"member_{index}", nickname=f"candidate {index}") for index in range(5)]
    for person in people:
        ConversationMember.objects.create(conversation=target, user=person)
    path = f"/api/v1/chat/conversations/{target.pk}/members/"
    first = page(client, path, exclude_self="1").json()
    assert first["total"] == 5 and len(first["results"]) == 2
    search = page(client, path, q="candidate 4", exclude_self="1").json()
    assert search["total"] == 1 and search["results"][0]["id"] == people[4].id
    assert page(client, f"/api/v1/chat/conversations/{another.pk}/members/", exclude_self="1", cursor=first["next_cursor"]).status_code == 400
    ConversationMember.objects.filter(conversation=target, user=actor).delete()
    assert page(client, path, exclude_self="1", cursor=first["next_cursor"]).status_code == 403


@pytest.mark.django_db
def test_subscription_pages_include_hidden_groups_and_have_bounded_sql(auth_client, user_factory):
    client, actor = auth_client(username="subscriptions_actor")
    groups = [group(actor, f"subscription {index}") for index in range(5)]
    ConversationMember.objects.filter(conversation=groups[0], user=actor).update(hidden=True)
    outsider = user_factory(username="subscription_outsider")
    group(outsider, "not authorized")
    Message.objects.create(conversation=groups[0], sender=actor, seq=7, content="fixture")
    with CaptureQueriesContext(connection) as queries:
        first = page(client, "/api/v1/chat/subscriptions/").json()
    assert first["total"] == 5 and any("LIMIT 3" in query["sql"] for query in queries)
    second = page(client, "/api/v1/chat/subscriptions/", cursor=first["next_cursor"]).json()
    third = page(client, "/api/v1/chat/subscriptions/", cursor=second["next_cursor"]).json()
    rows = first["results"] + second["results"] + third["results"]
    assert {row["id"] for row in rows} == {str(item.pk) for item in groups}
    assert rows[0] == {"id": str(groups[0].pk), "last_message_seq": 7}
    assert all(set(row) == {"id", "last_message_seq"} for row in rows)
    assert client.get("/api/v1/chat/subscriptions/").status_code == 400


@pytest.mark.django_db
def test_subgroup_pages_keep_default_and_selected_can_be_read(auth_client):
    client, actor = auth_client(username="subgroup_actor")
    target = group(actor)
    extra = [GroupSubGroup.objects.create(conversation=target, name=f"room {index}") for index in range(4)]
    path = f"/api/v1/chat/conversations/{target.pk}/subgroups/"
    first = page(client, path).json()
    second = page(client, path, cursor=first["next_cursor"]).json()
    assert first["total"] == 5 and second["default"]["is_default"]
    selected = client.get(path + f"{extra[-1].pk}/").json()
    assert selected["id"] == str(extra[-1].pk)


@pytest.mark.django_db
def test_managed_requests_aggregate_all_groups_before_paging(auth_client, user_factory):
    client, actor = auth_client(username="moderation_actor")
    applicant = user_factory(username="moderation_applicant")
    managed = [group(actor, f"moderated {index}") for index in range(4)]
    for conversation in managed:
        GroupJoinRequest.objects.create(conversation=conversation, applicant=applicant)
    outsider = user_factory(username="moderation_outsider")
    hidden = group(outsider)
    GroupJoinRequest.objects.create(conversation=hidden, applicant=applicant)
    first = page(client, "/api/v1/chat/me/join-requests/").json()
    second = page(client, "/api/v1/chat/me/join-requests/", cursor=first["next_cursor"]).json()
    rows = first["results"] + second["results"]
    assert first["total"] == 4
    assert {row["conversation_id"] for row in rows} == {str(item.pk) for item in managed}
    assert all(row["status"] == "pending" for row in rows)


@pytest.mark.django_db
@pytest.mark.parametrize("kind", ["group", "private"])
def test_old_pinned_and_recently_active_conversations_precede_thirty_new_empty_rows(auth_client, user_factory, kind):
    client, actor = auth_client(username=f"sorting_{kind}")
    peer = user_factory(username=f"sorting_peer_{kind}")
    def make(title):
        item = group(actor, title)
        if kind == "private":
            item.type = "private"
            item.save(update_fields=["type"])
            ConversationMember.objects.create(conversation=item, user=peer)
        return item
    pinned = make("old pin")
    active = make("old active")
    Conversation.objects.filter(pk__in=[pinned.pk, active.pk]).update(created_at=timezone.now() - timedelta(days=10))
    ConversationMember.objects.filter(conversation=pinned, user=actor).update(is_pinned=True)
    Message.objects.create(conversation=active, sender=actor, seq=1, content="recent activity")
    for index in range(31):
        make(f"new empty {index}")
    result = page(client, "/api/v1/chat/conversations/", type=kind).json()
    assert [row["id"] for row in result["results"]] == [str(pinned.pk), str(active.pk)]
    assert result["total"] == 33
    second = page(client, "/api/v1/chat/conversations/", type=kind, cursor=result["next_cursor"]).json()
    assert len(second["results"]) == 2
    assert not {row["id"] for row in second["results"]} & {str(pinned.pk), str(active.pk)}


@pytest.mark.django_db
def test_group_activity_uses_whitelisted_content_before_pagination(auth_client):
    from apps.posts.models import Post
    client, actor = auth_client(username="post_sorting")
    active = group(actor, "old active post")
    unrelated = group(actor, "unrelated origin")
    Conversation.objects.filter(pk__in=[active.pk, unrelated.pk]).update(created_at=timezone.now() - timedelta(days=10))
    post = Post.objects.create(owner=actor, group=unrelated, title="fresh", body="fixture")
    post.allowed_groups.add(active)
    for index in range(31):
        group(actor, f"new group {index}")
    result = page(client, "/api/v1/chat/conversations/", type="group").json()
    assert result["results"][0]["id"] == str(active.pk)
    assert result["results"][0]["directory_activity_at"]
    assert unrelated.pk not in {int(row["id"]) for row in result["results"]}


@pytest.mark.django_db
def test_subgroup_activity_sorting_occurs_before_page_boundary(auth_client):
    client, actor = auth_client(username="subgroup_sort")
    target = group(actor)
    default = target.subgroups.get(is_default=True)
    extras = [GroupSubGroup.objects.create(conversation=target, name=f"subgroup {index}") for index in range(33)]
    Message.objects.create(conversation=target, subgroup=extras[-1], sender=actor, seq=50, content="latest")
    first = page(client, f"/api/v1/chat/conversations/{target.pk}/subgroups/").json()
    assert [row["id"] for row in first["results"]] == [str(default.pk), str(extras[-1].pk)]
    second = page(client, f"/api/v1/chat/conversations/{target.pk}/subgroups/", cursor=first["next_cursor"]).json()
    assert [row["id"] for row in second["results"]] == [str(extras[0].pk), str(extras[1].pk)]


@pytest.mark.django_db
def test_group_presence_aggregates_page_outside_rooms_and_rechecks_access(auth_client, user_factory):
    from apps.voice.models import VoiceChannel, VoiceChannelMember
    from apps.live.models import LiveChannel
    client, actor = auth_client(username="presence_actor")
    target = group(actor)
    hidden = group(user_factory(username="presence_other"))
    channels = [VoiceChannel.objects.create(name=f"room {i}", room_name=f"presence_{i}", owner=actor) for i in range(31)]
    channels[-1].allowed_groups.add(target)
    VoiceChannelMember.objects.create(channel=channels[-1], user=actor)
    live = LiveChannel.objects.create(title="late live", stream_key="test-presence-stream", owner=actor, status="live")
    live.allowed_groups.add(target)
    ids = [str(target.pk), str(hidden.pk), "999999"]
    result = client.post("/api/v1/chat/group-presence/", {"conversation_ids": ids}, format="json")
    assert result.status_code == 200
    assert result.json()["presences"] == {str(target.pk): {"live": True, "voice": True, "game": False}, str(hidden.pk): None, "999999": None}
    directory = page(client, "/api/v1/chat/conversations/", type="group").json()
    assert directory["results"][0]["group_presence"] == {"live": True, "voice": True, "game": False}
    VoiceChannelMember.objects.filter(channel=channels[-1]).delete()
    live.status = "ended"
    live.save(update_fields=["status"])
    refreshed = client.post("/api/v1/chat/group-presence/", {"conversation_ids": [str(target.pk)]}, format="json").json()
    assert refreshed["presences"][str(target.pk)] == {"live": False, "voice": False, "game": False}
    ConversationMember.objects.filter(conversation=target, user=actor).delete()
    assert client.post("/api/v1/chat/group-presence/", {"conversation_ids": [str(target.pk)]}, format="json").json()["presences"][str(target.pk)] is None


@pytest.mark.django_db
@pytest.mark.parametrize("ids", [[], ["1"] * 101, [True], [1], ["01"], ["-1"], ["1 OR 1=1"], ["9223372036854775808"]])
def test_group_presence_rejects_unbounded_or_invalid_ids(auth_client, ids):
    client, _ = auth_client(username="presence_bad_ids")
    assert client.post("/api/v1/chat/group-presence/", {"conversation_ids": ids}, format="json").status_code == 400
