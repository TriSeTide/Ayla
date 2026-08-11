"""media 模型契约测试（8.1 清单：media_id/upload_id 唯一、约束）。"""
import pytest
from django.db import IntegrityError

from apps.media.models import MediaObject, MediaUploadSession


@pytest.mark.django_db
class TestMediaObjectModel:
    def test_media_id_unique_enforced(self, user_factory):
        u = user_factory()
        MediaObject.objects.create(
            media_id="dup-id-1", owner=u, kind="image", status="ready"
        )
        with pytest.raises(IntegrityError):
            MediaObject.objects.create(
                media_id="dup-id-1", owner=u, kind="image", status="ready"
            )

    def test_kind_choices(self, user_factory):
        u = user_factory()
        media = MediaObject.objects.create(
            media_id="kind-1", owner=u, kind="emoji", status="ready"
        )
        assert media.kind == "emoji"
        assert media.has_thumbnail is False
        assert media.has_waveform is False


@pytest.mark.django_db
class TestMediaUploadSessionModel:
    def test_upload_id_unique_enforced(self, user_factory):
        u = user_factory()
        MediaUploadSession.objects.create(
            upload_id="dup-up-1", owner=u, kind="image", status="pending"
        )
        with pytest.raises(IntegrityError):
            MediaUploadSession.objects.create(
                upload_id="dup-up-1", owner=u, kind="image", status="pending"
            )
