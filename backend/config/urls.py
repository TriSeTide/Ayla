"""URL 路由 —— 全部 API 收敛在 /api/v1 下。"""
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/v1/", include("apps.accounts.urls")),
    path("api/v1/chat/", include("apps.chat.urls")),
    path("api/v1/elysia/", include("apps.elysia_bridge.urls")),
    path("api/v1/media/", include("apps.media.urls")),
    path("api/v1/emoji/", include("apps.emoji.urls")),
    path("api/v1/voice/", include("apps.voice.urls")),
    path("api/v1/live/", include("apps.live.urls")),
]
