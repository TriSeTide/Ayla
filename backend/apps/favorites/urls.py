"""收藏 REST 路由（挂载在 /api/v1/favorites/ 下，S6）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("", views.FavoriteListView.as_view(), name="favorite-list"),
    path("<int:favorite_id>/", views.FavoriteDetailView.as_view(), name="favorite-detail"),
]
