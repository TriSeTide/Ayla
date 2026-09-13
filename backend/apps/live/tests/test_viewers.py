"""在看人数（Viewer Presence）契约测试。

覆盖：
- `viewers` 存储层：加入/离开/心跳/过期剔除/存储不可用降级（不伪装 0 人）；
- 序列化：列表整页预取 `viewer_count`，presence 不可用时为 null；
- REST：`GET /channels/<id>/viewers/` 权限、名单与截断标注、presence 不可用 → 503；
- WS：连接即登记在看并广播房内 viewers 帧，断开移除、其他观众收到人数更新；
- chat 消费者：`live.viewers.changed` 帧格式（客户端据此 patch 列表人数）。
"""
import time

import pytest
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from apps.live import consumers, services, viewers
from apps.live.models import LiveChannel
from apps.live.services import gen_stream_key


class FakeRedis:
    """最小 Redis ZSET 假实现（只实现 presence 用到的方法）。

    `zrevrange` 返回 bytes，与真实 redis-py 一致——解码路径必须被真正走到。
    """

    def __init__(self):
        self.zsets: dict[str, dict[str, float]] = {}
        self.expires: dict[str, int] = {}

    def zadd(self, key, mapping):
        bucket = self.zsets.setdefault(key, {})
        for member, score in mapping.items():
            bucket[member] = float(score)
        return len(mapping)

    def zrem(self, key, *members):
        bucket = self.zsets.get(key, {})
        removed = 0
        for member in members:
            if member in bucket:
                del bucket[member]
                removed += 1
        return removed

    def zremrangebyscore(self, key, minimum, maximum):
        bucket = self.zsets.get(key, {})
        low = float("-inf") if minimum == "-inf" else float(minimum)
        high = float(maximum)
        drop = [m for m, score in bucket.items() if low <= score <= high]
        for member in drop:
            del bucket[member]
        return len(drop)

    def zcard(self, key):
        return len(self.zsets.get(key, {}))

    def zrevrange(self, key, start, end):
        rows = sorted(self.zsets.get(key, {}).items(), key=lambda kv: kv[1], reverse=True)
        window = rows[start:] if end == -1 else rows[start : end + 1]
        return [member.encode() for member, _ in window]

    def zscore(self, key, member):
        bucket = self.zsets.get(key)
        if not bucket or member not in bucket:
            return None
        return bucket[member]

    def expire(self, key, ttl):
        self.expires[key] = ttl
        return True

    def pipeline(self):
        return FakePipeline(self)


class FakePipeline:
    def __init__(self, client: FakeRedis):
        self.client = client
        self.ops: list[tuple[str, tuple]] = []

    def zremrangebyscore(self, *args):
        self.ops.append(("zremrangebyscore", args))
        return self

    def zcard(self, *args):
        self.ops.append(("zcard", args))
        return self

    def execute(self):
        return [getattr(self.client, name)(*args) for name, args in self.ops]


@pytest.fixture
def fake_redis(monkeypatch):
    """注入假 Redis（测试不依赖真实 Redis，与 FakeSrsClient 同款做法）。"""
    fake = FakeRedis()
    monkeypatch.setattr("apps.live.viewers._client", lambda: fake)
    return fake


@pytest.fixture
def broken_redis(monkeypatch):
    """presence 存储不可用：任何读取都抛错 → 调用方必须降级而非伪装 0 人。"""

    class _Broken:
        def __getattr__(self, name):
            def _boom(*args, **kwargs):
                raise ConnectionError("redis down")

            return _boom

    monkeypatch.setattr("apps.live.viewers._client", lambda: _Broken())


# ---------- 存储层 ----------


def test_presence_add_remove_and_order(fake_redis):
    """加入/离开改变人数；名单按最近活跃优先，且 id 已解码为 str。"""
    assert viewers.add_viewer(7, "u1") == 1
    assert viewers.add_viewer(7, "u2") == 2
    # 重复加入同一用户（多端/重连）幂等，不重复计数
    assert viewers.add_viewer(7, "u1") == 2

    ids = viewers.viewer_ids(7)
    assert ids == ["u1", "u2"]  # u1 最近活跃优先
    assert all(isinstance(i, str) for i in ids)

    assert viewers.remove_viewer(7, "u1") == 1
    assert viewers.remove_viewer(7, "u2") == 0
    assert viewers.viewer_count(7) == 0


def test_presence_counts_are_batched(fake_redis):
    """整页预取：一次 pipeline 读多个频道，互不串号。"""
    viewers.add_viewer(1, "a")
    viewers.add_viewer(1, "b")
    viewers.add_viewer(2, "c")

    assert viewers.viewer_counts([1, 2, 3]) == {1: 2, 2: 1, 3: 0}
    assert viewers.viewer_counts([]) == {}


def test_presence_prunes_expired_scores(fake_redis):
    """活跃分超过 TTL 的观众被剔除：只有心跳刷新的人算在看。"""
    stale = time.time() - viewers.VIEWER_TTL_SECONDS - 5
    fake_redis.zadd(viewers._key(9), {"old": stale, "fresh": time.time()})

    assert viewers.viewer_count(9) == 1
    assert viewers.viewer_ids(9) == ["fresh"]


def test_heartbeat_reports_rejoin_only_when_counted_again(fake_redis):
    """心跳：正常刷新返回 False；此前已被判为离开返回 True（必须补播人数）。"""
    viewers.add_viewer(5, "u1")
    assert viewers.touch_viewer(5, "u1") is False

    fake_redis.zadd(viewers._key(5), {"u1": time.time() - viewers.VIEWER_TTL_SECONDS - 1})
    assert viewers.touch_viewer(5, "u1") is True

    # 从未登记过的连接心跳 → 视为重新计入
    assert viewers.touch_viewer(5, "u2") is True


def test_store_unavailable_degrades_to_none(broken_redis):
    """存储不可用必须返回 None（读不到 ≠ 0 人在看），不得伪造空房间。"""
    assert viewers.add_viewer(1, "u1") is None
    assert viewers.remove_viewer(1, "u1") is None
    assert viewers.touch_viewer(1, "u1") is None
    assert viewers.viewer_ids(1) is None
    assert viewers.viewer_count(1) is None
    assert viewers.viewer_counts([1, 2]) is None

    assert services.viewer_snapshot(1) == (None, [])
    assert services.viewer_page(1) is None


# ---------- 序列化 / REST ----------


@pytest.mark.django_db
def test_list_prefetches_viewer_count(auth_client, live_channel_factory, fake_redis):
    """列表 descriptor 带在看人数；无人观看是 0（而不是 null）。"""
    client, user = auth_client()
    watched = live_channel_factory(owner=user, title="有观众")
    live_channel_factory(owner=user, title="没人")
    viewers.add_viewer(watched.id, user.id)

    resp = client.get("/api/v1/live/channels/")
    assert resp.status_code == 200, resp.content
    by_title = {row["title"]: row for row in resp.json()}
    assert by_title["有观众"]["viewer_count"] == 1
    assert by_title["没人"]["viewer_count"] == 0


@pytest.mark.django_db
def test_list_viewer_count_is_null_when_store_down(
    auth_client, live_channel_factory, broken_redis
):
    """presence 不可用 → viewer_count=null（前端隐藏人数），不得回落到 0。"""
    client, user = auth_client()
    live_channel_factory(owner=user, title="A")

    resp = client.get("/api/v1/live/channels/")
    assert resp.status_code == 200
    assert resp.json()[0]["viewer_count"] is None


@pytest.mark.django_db
def test_viewer_page_marks_truncation(live_channel_factory, user_factory, fake_redis):
    """名单被上限截断时 has_more=True，count 仍是真实总数（不静默截断）。"""
    ch = live_channel_factory()
    watchers = [user_factory() for _ in range(5)]
    for watcher in watchers:
        viewers.add_viewer(ch.id, watcher.id)

    page = services.viewer_page(ch.id, limit=2)
    assert page is not None
    assert page["count"] == 5
    assert len(page["viewers"]) == 2
    assert page["has_more"] is True


@pytest.mark.django_db
def test_viewer_page_omits_deleted_accounts(live_channel_factory, fake_redis):
    """presence 里有已被删除的账号 id → 展示投影省略它，但人数仍按运行事实计。

    展示层不凭空造成员，也不因为投影缺失而改写"当时确实有人在看"这一事实。
    """
    ch = live_channel_factory()
    viewers.add_viewer(ch.id, "no-such-user-id")

    page = services.viewer_page(ch.id)
    assert page is not None
    assert page["count"] == 1
    assert page["viewers"] == []


@pytest.mark.django_db
def test_viewers_endpoint_returns_list(auth_client, live_channel_factory, fake_redis):
    """在看名单：人数 + 描述（最近活跃优先）。"""
    client, user = auth_client()
    other_client, other = auth_client(username="watcher")
    ch = live_channel_factory(owner=user)
    viewers.add_viewer(ch.id, other.id)
    viewers.add_viewer(ch.id, user.id)

    resp = client.get(f"/api/v1/live/channels/{ch.id}/viewers/")
    assert resp.status_code == 200, resp.content
    data = resp.json()
    assert data["channel_id"] == ch.id
    assert data["count"] == 2
    assert data["has_more"] is False
    assert [item["user_id"] for item in data["viewers"]] == [user.id, other.id]
    assert data["viewers"][0]["nickname"] == (user.nickname or user.username)
    assert other_client is not None


@pytest.mark.django_db
def test_viewers_endpoint_permissions(auth_client, live_channel_factory, fake_redis):
    """非可见 → 403；不存在 → 404；owner 可见。"""
    from apps.common.visibility import Visibility

    client, _ = auth_client()
    owner_client, owner = auth_client(username="owner")
    hidden = live_channel_factory(
        title="仅好友", visibility=Visibility.FRIENDS, owner=owner
    )

    assert client.get(f"/api/v1/live/channels/{hidden.id}/viewers/").status_code == 403
    assert client.get("/api/v1/live/channels/99999/viewers/").status_code == 404
    assert owner_client.get(f"/api/v1/live/channels/{hidden.id}/viewers/").status_code == 200


@pytest.mark.django_db
def test_viewers_endpoint_503_when_store_down(auth_client, live_channel_factory, broken_redis):
    """presence 不可用 → 503：读不到就说读不到，不返回空名单冒充没人看。"""
    client, user = auth_client()
    ch = live_channel_factory(owner=user)
    resp = client.get(f"/api/v1/live/channels/{ch.id}/viewers/")
    assert resp.status_code == 503
    assert resp.json()["detail"] == "viewer_presence_unavailable"


@pytest.mark.django_db
def test_viewers_endpoint_requires_auth(live_channel_factory, fake_redis):
    ch = live_channel_factory()
    resp = APIClient().get(f"/api/v1/live/channels/{ch.id}/viewers/")
    assert resp.status_code in (401, 403)


# ---------- WS ----------


def _jwt_query(user) -> str:
    token = RefreshToken.for_user(user).access_token
    return f"token={token}"


def _live_ws_app():
    from channels.routing import URLRouter
    from django.urls import re_path

    return URLRouter(
        [
            re_path(
                r"^ws/live/(?P<channel_id>\d+)/$",
                consumers.DanmakuConsumer.as_asgi(),
            )
        ]
    )


@database_sync_to_async
def _mk_user(auth_client, **kwargs):
    _, user = auth_client(**kwargs)
    return user


@database_sync_to_async
def _make_channel(owner, title="直播间"):
    return LiveChannel.objects.create(title=title, owner=owner, stream_key=gen_stream_key())


@database_sync_to_async
def _viewer_ids(channel_id):
    return viewers.viewer_ids(channel_id)


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_connect_registers_viewer_and_broadcasts(
    auth_client, transactional_db, fake_redis
):
    """连接即在看：房内收到 viewers 帧（人数 + 头像预览）；断开后人数归零。"""
    user = await _mk_user(auth_client)
    ch = await _make_channel(user)

    communicator = WebsocketCommunicator(_live_ws_app(), f"/ws/live/{ch.id}/?{_jwt_query(user)}")
    connected, _ = await communicator.connect()
    assert connected

    frame = await communicator.receive_json_from(timeout=2)
    assert frame["type"] == "viewers"
    assert frame["channel_id"] == ch.id
    assert frame["count"] == 1
    assert [item["user_id"] for item in frame["viewers"]] == [user.id]

    await communicator.disconnect()
    assert await _viewer_ids(ch.id) == []


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_ws_second_viewer_updates_room(auth_client, transactional_db, fake_redis):
    """第二位观众加入 → 房内既有观众收到更新后的人数帧。"""
    user_a = await _mk_user(auth_client, username="room_a")
    user_b = await _mk_user(auth_client, username="room_b")
    ch = await _make_channel(user_a)

    first = WebsocketCommunicator(_live_ws_app(), f"/ws/live/{ch.id}/?{_jwt_query(user_a)}")
    assert (await first.connect())[0]
    await first.receive_json_from(timeout=2)  # 本人加入的 viewers 帧

    second = WebsocketCommunicator(_live_ws_app(), f"/ws/live/{ch.id}/?{_jwt_query(user_b)}")
    assert (await second.connect())[0]

    update = await first.receive_json_from(timeout=2)
    assert update["type"] == "viewers"
    assert update["count"] == 2
    assert {item["user_id"] for item in update["viewers"]} == {user_a.id, user_b.id}

    await second.disconnect()
    await first.disconnect()


# ---------- chat 消费者目录帧 ----------


class _FrameRecorder:
    def __init__(self):
        self.sent: list[dict] = []

    async def send_json(self, payload):
        self.sent.append(payload)


@pytest.mark.django_db
@pytest.mark.asyncio
async def test_chat_consumer_forwards_viewer_count_frame():
    """`live.viewers.changed` → 客户端可 patch 的 {channel_id, viewer_count} 帧。

    帧不带 name/visibility 等目录元数据，也不属于 `live.channel.*` 命名空间——
    前端目录对账/活动排序不因此失效（见 web/src/api/types.ts 注释）。
    """
    from apps.chat.consumers import ChatConsumer

    recorder = _FrameRecorder()
    await ChatConsumer.live_viewers_changed(
        recorder, {"channel_id": 12, "viewer_count": 3}
    )
    assert recorder.sent == [
        {
            "type": "live.viewers.changed",
            "data": {"channel_id": 12, "viewer_count": 3},
        }
    ]
