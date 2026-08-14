"""S5 聚合搜索 REST 契约测试。

覆盖：五类对象分组返回、可见性过滤（friends 帖子/直播间/桌游室对路人不可见）、
空结果、空关键字 400、每组截断（limit）、types 子集。
"""
import pytest

from apps.accounts.models import Friendship
from apps.boardgame.models import GameRoom
from apps.chat.models import Conversation, ConversationMember
from apps.common.visibility import Visibility
from apps.live.models import LiveChannel
from apps.posts.models import Post

SEARCH_URL = "/api/v1/search/"


def _make_group(owner, users=None, title="测试群"):
    conv = Conversation.objects.create(type="group", title=title, owner=owner)
    ConversationMember.objects.create(conversation=conv, user=owner, role="owner")
    for u in users or []:
        ConversationMember.objects.create(conversation=conv, user=u)
    return conv


def _make_friends(a, b):
    Friendship.objects.create(user=a, friend=b, status="accepted")
    Friendship.objects.create(user=b, friend=a, status="accepted")


def _make_post(owner, body="帖子正文", **kwargs):
    return Post.objects.create(owner=owner, body=body, **kwargs)


def _make_live(owner, title="直播间", **kwargs):
    return LiveChannel.objects.create(owner=owner, title=title, stream_key=f"sk-{title}", **kwargs)


def _make_room(owner, name="桌游室", **kwargs):
    return GameRoom.objects.create(owner=owner, name=name, **kwargs)


@pytest.mark.django_db
class TestAggregateSearch:
    def test_all_types_grouped(self, auth_client, user_factory):
        client, user = auth_client(username="s_me")
        owner = user_factory(username="s_alice", nickname="爱丽丝")
        user_factory(username="s_bob", nickname="张三")
        # 命中关键词 "爱"
        _make_group(owner, title="爱丽丝后援会")
        _make_post(owner, "爱丽丝的帖子", visibility=Visibility.PUBLIC)
        _make_live(owner, "爱丽丝直播", visibility=Visibility.PUBLIC)
        _make_room(owner, "爱丽丝桌游局", visibility=Visibility.PUBLIC)

        resp = client.get(SEARCH_URL, {"q": "爱"})
        assert resp.status_code == 200, resp.content
        data = resp.json()
        assert set(data.keys()) == {"users", "groups", "posts", "lives", "games"}
        assert data["users"]["total"] == 1
        assert data["users"]["items"][0]["nickname"] == "爱丽丝"
        assert data["groups"]["total"] == 1
        assert data["groups"]["items"][0]["title"] == "爱丽丝后援会"
        assert data["posts"]["total"] == 1
        assert data["posts"]["items"][0]["body"] == "爱丽丝的帖子"
        assert data["lives"]["total"] == 1
        assert data["lives"]["items"][0]["title"] == "爱丽丝直播"
        assert data["games"]["total"] == 1
        assert data["games"]["items"][0]["name"] == "爱丽丝桌游局"

    def test_visibility_filters_friends_content(self, auth_client, user_factory):
        client, viewer = auth_client(username="s_viewer")
        owner = user_factory(username="s_fowner")
        # friends 内容：路人不可见
        _make_post(owner, "好友私密帖", visibility=Visibility.FRIENDS)
        _make_live(owner, "好友直播间", visibility=Visibility.FRIENDS)
        _make_room(owner, "好友桌游房", visibility=Visibility.FRIENDS)
        # public 内容：可见
        _make_post(owner, "公开帖", visibility=Visibility.PUBLIC)
        _make_live(owner, "公开直播间", visibility=Visibility.PUBLIC)
        _make_room(owner, "公开桌游房", visibility=Visibility.PUBLIC)

        resp = client.get(SEARCH_URL, {"q": "友"})
        assert resp.status_code == 200
        data = resp.json()
        # "友" 只命中 friends 的三条（公开内容不含"友"），路人全不可见
        assert data["posts"]["total"] == 0
        assert data["lives"]["total"] == 0
        assert data["games"]["total"] == 0

        # 成为好友后可见 friends 内容
        _make_friends(viewer, owner)
        resp = client.get(SEARCH_URL, {"q": "友"})
        data = resp.json()
        assert data["posts"]["total"] == 1
        assert data["lives"]["total"] == 1
        assert data["games"]["total"] == 1

    def test_no_match_returns_empty_groups(self, auth_client):
        client, user = auth_client(username="s_nomatch")
        _make_post(user, "普通帖子", visibility=Visibility.PUBLIC)
        resp = client.get(SEARCH_URL, {"q": "不存在的关键字xyz"})
        assert resp.status_code == 200
        data = resp.json()
        for key in ("users", "groups", "posts", "lives", "games"):
            assert data[key] == {"items": [], "total": 0}

    def test_empty_q_400(self, auth_client):
        client, _ = auth_client(username="s_empty")
        assert client.get(SEARCH_URL, {"q": ""}).status_code == 400
        assert client.get(SEARCH_URL, {"q": "   "}).status_code == 400
        resp = client.get(SEARCH_URL)
        assert resp.status_code == 400
        assert resp.json()["detail"] == "q 不能为空"

    def test_limit_truncates(self, auth_client):
        client, user = auth_client(username="s_limit")
        for i in range(5):
            _make_post(user, f"截断帖子{i}", visibility=Visibility.PUBLIC)
        resp = client.get(SEARCH_URL, {"q": "截断", "limit": "2"})
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["posts"]["items"]) == 2
        assert data["posts"]["total"] == 5

    def test_types_subset(self, auth_client, user_factory):
        client, user = auth_client(username="s_types")
        owner = user_factory(username="s_towner")
        _make_post(owner, "子集帖子", visibility=Visibility.PUBLIC)
        _make_room(owner, "子集桌游", visibility=Visibility.PUBLIC)
        resp = client.get(SEARCH_URL, {"q": "子集", "types": "user,post"})
        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"users", "posts"}

    def test_types_invalid_ignored(self, auth_client):
        client, _ = auth_client(username="s_types_inv")
        resp = client.get(SEARCH_URL, {"q": "x", "types": "user,bogus,user"})
        assert resp.status_code == 200
        data = resp.json()
        # 去重 + 非法忽略 → 只剩 users
        assert set(data.keys()) == {"users"}
