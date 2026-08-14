"""搜索 REST 路由（挂载在 /api/v1/search/ 下，S5 聚合搜索）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("", views.SearchView.as_view(), name="search"),
]
