"""elysia_bridge REST 路由（挂载在 /api/v1/elysia/ 下）。"""
from django.urls import path

from . import views

urlpatterns = [
    path(
        "profile/",
        views.ElysiaProfileView.as_view(),
        name="elysia-profile",
    ),
    path(
        "profile/:test",
        views.ElysiaProfileTestView.as_view(),
        name="elysia-profile-test",
    ),
    # 通道健康（只读，任意登录用户；DEVELOPMENT.zh.md §5）
    path(
        "bridge/health/",
        views.ElysiaBridgeHealthView.as_view(),
        name="elysia-bridge-health",
    ),
]
