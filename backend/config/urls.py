"""URL 路由 —— 全部 API 收敛在 /api/v1 下。"""
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/v1/", include("apps.accounts.urls")),
    # 后续里程碑追加：
    # path("api/v1/chat/", include("apps.chat.urls")),
    # path("api/v1/bridge/", include("apps.elysia_bridge.urls")),
]
