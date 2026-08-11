"""apps/emoji/tests 共享 fixtures：转发 backend/tests 与 media 的通用工具。

pytest conftest 按目录作用域，emoji 目录看不到 media 的 fixtures/helpers，
这里显式转发 upload_emoji 与通用工厂。
"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401


@pytest.fixture(autouse=True)
def _reset_storage():
    """每个测试前重置存储单例（与 media 一致，FakeStorage 隔离）。"""
    from apps.media import storage

    storage.reset_storage_cache()
    yield
    storage.reset_storage_cache()


def upload_emoji(client, data=None, mime_type="image/png"):
    """通过三步上传 API 上传 emoji 媒体，返回 (media_id, descriptor)。"""
    from apps.media.tests.conftest import upload_image

    return upload_image(client, data=data, kind="emoji", mime_type=mime_type)
