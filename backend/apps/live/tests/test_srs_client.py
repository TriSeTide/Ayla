"""SRS 客户端契约测试（M4-6 §8.1）：响应解析、is_streaming 判定、失败降级（degraded）。"""
import pytest
import httpx

from apps.live.srs import FakeSrsClient, SrsClient, SrsUnavailable

STREAMS_OK = {"streams": [{"app": "live", "stream": "abc123", "vhost": "__defaultVhost__"}]}


def _mock_get(monkeypatch, payload=None, status_code=200, exc=None):
    """mock httpx.get：payload 或抛 exc。"""
    def _get(url, timeout):
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
    assert streams[0]["stream"] == "abc123"


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
    """is_streaming：存在 app+stream 匹配 → True；不匹配 → False。"""
    _mock_get(monkeypatch, payload=STREAMS_OK)
    client = SrsClient(api_url="http://srs:1985", timeout=0.1)
    assert client.is_streaming("live", "abc123") is True
    assert client.is_streaming("live", "nope") is False
    assert client.is_streaming("other", "abc123") is False


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

    client.set_streams([{"app": "live", "stream": "x"}])
    assert client.is_streaming("live", "x") is True

    client.set_fail(True)
    with pytest.raises(SrsUnavailable):
        client.is_streaming("live", "x")  # 查询失败必须抛异常，不能返回 False
    assert client.health() == "error"
