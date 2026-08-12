"""直播 REST 契约测试（M4-6 §8.1）：创建/stream_key 权限/CRUD/start-stop/status 判定/越权。"""
import pytest

from apps.live.models import LiveChannel


def _create_via_api(client, title="爱莉的午后"):
    return client.post("/api/v1/live/channels/", {"title": title}, format="json")


@pytest.mark.django_db
def test_create_channel_returns_stream_urls(auth_client):
    """创建 → 201，返回 stream_key/rtmp/hls/flv；status=idle。"""
    client, user = auth_client()
    resp = _create_via_api(client)
    assert resp.status_code == 201, resp.content
    data = resp.json()
    assert data["title"] == "爱莉的午后"
    assert data["status"] == "idle"
    assert data["owner_id"] == user.id
    assert data["is_owner"] is True
    assert len(data["stream_key"]) == 48
    assert data["rtmp_url"] == f"rtmp://127.0.0.1:1935/live/{data['stream_key']}"
    assert data["hls_url"] == f"http://127.0.0.1:8080/live/{data['stream_key']}.m3u8"
    assert data["flv_url"] == f"http://127.0.0.1:8080/live/{data['stream_key']}.flv"


@pytest.mark.django_db
def test_create_requires_title(auth_client):
    client, _ = auth_client()
    resp = client.post("/api/v1/live/channels/", {"title": "  "}, format="json")
    assert resp.status_code == 400


@pytest.mark.django_db
def test_stream_key_only_owner_visible(auth_client, live_channel_factory):
    """stream_key 最小权限：owner 详情可见；非 owner 一律 null；列表不泄露。"""
    owner_client, owner = auth_client()
    other_client, _ = auth_client(username="other")
    ch = live_channel_factory(owner=owner)

    # owner 详情：stream_key/rtmp_url 可见
    resp = owner_client.get(f"/api/v1/live/channels/{ch.id}/")
    assert resp.status_code == 200
    assert resp.json()["stream_key"] == ch.stream_key
    assert resp.json()["rtmp_url"] is not None

    # 非 owner 详情：stream_key/rtmp_url = null，播放地址可见
    resp = other_client.get(f"/api/v1/live/channels/{ch.id}/")
    assert resp.status_code == 200
    data = resp.json()
    assert data["stream_key"] is None
    assert data["rtmp_url"] is None
    assert data["hls_url"] is not None
    assert data["flv_url"] is not None
    assert data["is_owner"] is False


@pytest.mark.django_db
def test_channel_list_and_only_live_filter(auth_client, live_channel_factory):
    """列表含乐观 status；?only_live=1 只返回 status=live。"""
    client, owner = auth_client()
    live_channel_factory(owner=owner, title="A")
    ch2 = live_channel_factory(owner=owner, title="B")
    ch2.status = "live"
    ch2.save(update_fields=["status"])

    resp = client.get("/api/v1/live/channels/")
    assert resp.status_code == 200
    assert len(resp.json()) == 2

    resp = client.get("/api/v1/live/channels/?only_live=1")
    assert resp.status_code == 200
    assert len(resp.json()) == 1
    assert resp.json()[0]["title"] == "B"


@pytest.mark.django_db
def test_start_stop_transition(auth_client, live_channel_factory):
    """:start/:stop 状态流转 idle→live→ended；started_at/ended_at 更新；仅 owner。"""
    client, owner = auth_client()
    ch = live_channel_factory(owner=owner)

    resp = client.post(f"/api/v1/live/channels/{ch.id}:start/")
    assert resp.status_code == 200, resp.content
    ch.refresh_from_db()
    assert ch.status == "live"
    assert ch.started_at is not None
    assert resp.json()["status"] == "live"

    resp = client.post(f"/api/v1/live/channels/{ch.id}:stop/")
    assert resp.status_code == 200
    ch.refresh_from_db()
    assert ch.status == "ended"
    assert ch.ended_at is not None


@pytest.mark.django_db
def test_start_stop_requires_owner(auth_client, live_channel_factory):
    """非 owner :start/:stop → 403。"""
    owner_client, owner = auth_client()
    other_client, _ = auth_client(username="other")
    ch = live_channel_factory(owner=owner)

    resp = other_client.post(f"/api/v1/live/channels/{ch.id}:start/")
    assert resp.status_code == 403
    resp = other_client.post(f"/api/v1/live/channels/{ch.id}:stop/")
    assert resp.status_code == 403


@pytest.mark.django_db
def test_status_live_idle_degraded(auth_client, live_channel_factory, fake_srs):
    """/status SRS 判定：在播→live；不在播→idle；查询失败→degraded（不伪装未在播）。"""
    client, owner = auth_client()
    ch = live_channel_factory(owner=owner)

    # 未在播 → idle
    resp = client.get(f"/api/v1/live/channels/{ch.id}/status/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "idle"

    # SRS 在播 → live
    fake_srs.set_streams([{"app": "live", "stream": ch.stream_key}])
    resp = client.get(f"/api/v1/live/channels/{ch.id}/status/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "live"

    # SRS 查询失败 → degraded（不是 idle）
    fake_srs.set_fail(True)
    resp = client.get(f"/api/v1/live/channels/{ch.id}/status/")
    assert resp.status_code == 200
    assert resp.json()["status"] == "degraded"
    assert resp.json()["detail"] == "srs_unavailable"


@pytest.mark.django_db
def test_delete_channel_rules(auth_client, live_channel_factory):
    """删除：owner 可删（非直播中）；非 owner 403；直播中 400；不存在 404。"""
    owner_client, owner = auth_client()
    other_client, _ = auth_client(username="other")

    # 非 owner 删除 → 403
    ch = live_channel_factory(owner=owner)
    resp = other_client.delete(f"/api/v1/live/channels/{ch.id}/")
    assert resp.status_code == 403

    # 直播中删除 → 400
    ch.status = "live"
    ch.save(update_fields=["status"])
    resp = owner_client.delete(f"/api/v1/live/channels/{ch.id}/")
    assert resp.status_code == 400

    # 停止后删除 → 200
    owner_client.post(f"/api/v1/live/channels/{ch.id}:stop/")
    resp = owner_client.delete(f"/api/v1/live/channels/{ch.id}/")
    assert resp.status_code == 200
    assert not LiveChannel.objects.filter(pk=ch.id).exists()

    # 不存在 → 404
    resp = owner_client.get("/api/v1/live/channels/9999/")
    assert resp.status_code == 404
    resp = owner_client.post("/api/v1/live/channels/9999:start/")
    assert resp.status_code == 404


@pytest.mark.django_db
def test_unauthenticated_rejected():
    """未登录 → 401（创建/列表/详情/状态）。"""
    from rest_framework.test import APIClient

    client = APIClient()
    resp = client.get("/api/v1/live/channels/")
    assert resp.status_code in (401, 403)
    resp = client.post("/api/v1/live/channels/", {"title": "x"}, format="json")
    assert resp.status_code in (401, 403)
