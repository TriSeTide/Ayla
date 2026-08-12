"""SRS 客户端契约测试（M4-6 §8.1）：响应解析、is_streaming 判定、失败降级（degraded）。"""
import pytest
import httpx

from apps.live.srs import FakeSrsClient, SrsClient, SrsUnavailable

# SRS 5 真实响应格式（2026-08-12 冒烟核对）：流名字段是 `name`（历史版本为 `stream`），
# 且带 publish.active 标记发布状态（停流后残留记录 active=false）
STREAMS_OK = {
    "streams": [
        {"app": "live", "name": "abc123", "vhost": "__defaultVhost__",
         "publish": {"active": True}},
    ]
}


def _mock_get(monkeypatch, payload=None, status_code=200, exc=None):
    """mock httpx.get：payload 或抛 exc（兼容 follow_redirects 等 kwargs）。"""
    def _get(url, timeout, **kwargs):
        if exc is not None:
            raise exc
        resp = httpx.Response(status_code=status_code, json=payload)
        return resp
    monkeypatch.setattr("httpx.get", _get)


def test_list_streams_parses(monkeypatch):
    """GET /api/v1/streams 解析出 streams 列表。"""
    _mock_get(monkeypatch, payload=STREAMS_OK)
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    streams = client.list_streams()
    assert streams[0]["app"] == "live"
    assert streams[0]["name"] == "abc123"


def test_list_streams_malformed_payload(monkeypatch):
    """响应缺 streams 字段 → SrsUnavailable（不静默当空列表）。"""
    _mock_get(monkeypatch, payload={"foo": "bar"})
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    with pytest.raises(SrsUnavailable):
        client.list_streams()


def test_list_streams_non_200(monkeypatch):
    """非 200 → SrsUnavailable（不伪装"未在播"）。"""
    _mock_get(monkeypatch, status_code=500)
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    with pytest.raises(SrsUnavailable):
        client.list_streams()


def test_list_streams_network_error(monkeypatch):
    """网络错误（超时/连接拒绝）→ SrsUnavailable。"""
    _mock_get(monkeypatch, exc=httpx.ConnectError("refused"))
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    with pytest.raises(SrsUnavailable):
        client.list_streams()


def test_is_streaming_match_and_miss(monkeypatch):
    """is_streaming：存在 app+name（SRS 5 字段）匹配 → True；不匹配 → False。"""
    _mock_get(monkeypatch, payload=STREAMS_OK)
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    assert client.is_streaming("live", "abc123") is True
    assert client.is_streaming("live", "nope") is False
    assert client.is_streaming("other", "abc123") is False


def test_is_streaming_legacy_stream_field(monkeypatch):
    """兼容：旧版响应用 `stream` 字段也能匹配（真实冒烟核对 name 字段的兼容兜底）。"""
    _mock_get(
        monkeypatch,
        payload={"streams": [{"app": "live", "stream": "legacy01"}]},
    )
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    assert client.is_streaming("live", "legacy01") is True


def test_is_streaming_inactive_residual_stream(monkeypatch):
    """停流后的残留记录（publish.active=false）不得误判为在播（冒烟实测 SRS 保留残留）。"""
    _mock_get(
        monkeypatch,
        payload={
            "streams": [
                {"app": "live", "name": "stale01", "publish": {"active": False}},
                {"app": "live", "name": "live01", "publish": {"active": True}},
            ]
        },
    )
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    assert client.is_streaming("live", "stale01") is False
    assert client.is_streaming("live", "live01") is True


def test_health_ok_and_error(monkeypatch):
    """health：/api/v1/versions 200 → ok；失败 → error（不抛）。"""
    _mock_get(monkeypatch, payload={"major": 5})
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    assert client.health() == "ok"

    _mock_get(monkeypatch, exc=httpx.ConnectError("down"))
    assert client.health() == "error"


def test_fake_srs_set_streams_and_fail():
    """FakeSrsClient：set_streams 模拟在播/不在播；set_fail 模拟不可用。"""
    client = FakeSrsClient()
    assert client.is_streaming("live", "x") is False

    client.set_streams([{"app": "live", "name": "x"}])
    assert client.is_streaming("live", "x") is True

    client.set_fail(True)
    with pytest.raises(SrsUnavailable):
        client.is_streaming("live", "x")  # 查询失败必须抛异常，不能返回 False
    assert client.health() == "error"
