"""apps/posts/tests 共享 fixtures：转发通用工厂 + 测试媒体工厂。"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401


@pytest.fixture(autouse=True)
def _reset_storage():
    """每个测试前重置存储单例，保证 FakeStorage 隔离（与 media/chat conftest 一致）。"""
    from apps.media import storage

    storage.reset_storage_cache()
    yield
    storage.reset_storage_cache()


def make_image_media(owner, media_id="post-img-1"):
    """直接创建一个 READY 的图片 MediaObject（绕过三步上传，供配图引用测试）。"""
    from apps.media import storage
    from apps.media.models import MediaObject

    store = storage.get_storage()
    media = MediaObject.objects.create(
        media_id=media_id,
        owner=owner,
        kind=MediaObject.KIND_IMAGE,
        content_hash=f"h-{media_id}",
        mime_type="image/png",
        size=100,
        storage_path=storage.original_key("image", media_id),
        status=MediaObject.STATUS_READY,
    )
    # FakeStorage put 不校验真实字节；给一点占位内容即可
    store.put(media.storage_path, b"\x89PNG\r\n\x1a\n" + b"x" * 20, "image/png")
    return media
