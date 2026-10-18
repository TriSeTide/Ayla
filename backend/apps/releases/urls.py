"""客户端发布 REST 路由（挂载在 /api/v1/updates/ 下）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("check/", views.UpdateCheckView.as_view(), name="update-check"),
]
