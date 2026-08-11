"""apps/chat/tests 共享 fixtures：复用 backend/tests/conftest.py 的通用工厂。

pytest conftest 按目录作用域，apps/ 目录下看不到 tests/ 的 fixtures，
这里显式转发，避免重复定义。

chat 测试（真实媒体发图等）会经三步上传 API 写入 FakeStorage 单例，
每个测试前必须重置，保证存储隔离（与 media/emoji conftest 一致）。
"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401


@pytest.fixture(autouse=True)
def _reset_storage():
    """每个测试前重置存储单例，保证 FakeStorage 隔离。"""
    from apps.media import storage

    storage.reset_storage_cache()
    yield
    storage.reset_storage_cache()
