"""apps/live/tests 共享 fixtures：FakeSrsClient 注入（不依赖真实 SRS）+ 全局通用工厂。"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401

from apps.live.srs import FakeSrsClient


@pytest.fixture
def fake_srs(monkeypatch):
    """FakeSrsClient 注入：monkeypatch apps.live.services.get_srs 返回 fake。

    测试通过 `fake_srs.set_streams([...])` 模拟在播/不在播、`fake_srs.set_fail(True)`
    模拟 SRS 不可用；保证契约测试不触网。
    """
    client = FakeSrsClient()
    monkeypatch.setattr("apps.live.services.get_srs", lambda: client)
    return client


@pytest.fixture
def live_channel_factory(db, user_factory):
    """直接创建 LiveChannel 的工厂（绕过 services.create_channel 的随机 key）。"""

    def _make(**kwargs):
        from apps.live.models import LiveChannel

        kwargs.setdefault("title", "测试直播间")
        kwargs.setdefault("owner", user_factory())
        if "stream_key" not in kwargs:
            from apps.live.services import gen_stream_key

            kwargs["stream_key"] = gen_stream_key()
        return LiveChannel.objects.create(**kwargs)

    return _make
