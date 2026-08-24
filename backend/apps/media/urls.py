"""media REST 路由（挂载在 /api/v1/media/ 下）。"""
from django.urls import path

from . import views

urlpatterns = [
    # 三步上传
    path("uploads", views.UploadSessionView.as_view(), name="media-upload-create"),
    # 注意：带 `:complete`/`:save` 的路径必须排在裸 `<str:upload_id>`/`<str:media_id>` 之前，
    # 否则 str 转换器会贪婪吞掉 `:complete`/`:save` 后缀，POST/后续方法被 405。
    path(
        "uploads/<str:upload_id>:complete",
        views.UploadCompleteView.as_view(),
        name="media-upload-complete",
    ),
    path("uploads/<str:upload_id>", views.UploadBinaryView.as_view(), name="media-upload-put"),
    # 下载 / 派生 / descriptor
    path(
        "<str:media_id>:save",
        views.MediaSaveView.as_view(),
        name="media-save",
    ),
    path(
        "<str:media_id>:sign",
        views.MediaSignView.as_view(),
        name="media-sign",
    ),
    path("<str:media_id>/", views.MediaDetailView.as_view(), name="media-detail"),
    path(
        "<str:media_id>/content",
        views.MediaContentView.as_view(),
        name="media-content",
    ),
    path(
        "<str:media_id>/thumbnail",
        views.MediaThumbnailView.as_view(),
        name="media-thumbnail",
    ),
    path(
        "<str:media_id>/waveform",
        views.MediaWaveformView.as_view(),
        name="media-waveform",
    ),
]
