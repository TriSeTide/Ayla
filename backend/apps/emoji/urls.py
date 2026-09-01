"""emoji REST 路由（挂载在 /api/v1/emoji/ 下）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("packs/", views.EmojiPackListView.as_view(), name="emoji-pack-list"),
    path(
        "packs/<str:pack_id>/items/",
        views.EmojiPackDetailView.as_view(),
        name="emoji-pack-items",
    ),
    path(
        "packs/<str:pack_id>/items/add/",
        views.EmojiItemCreateView.as_view(),
        name="emoji-item-add",
    ),
    path(
        "packs/<str:pack_id>/items/<str:item_id>/",
        views.EmojiItemDeleteView.as_view(),
        name="emoji-item-delete",
    ),
    path(
        "packs/<str:pack_id>/set_system/",
        views.EmojiSetSystemView.as_view(),
        name="emoji-set-system",
    ),
    path("search/", views.EmojiSearchView.as_view(), name="emoji-search"),
    # 任务 03：群内表情包
    path(
        "groups/<str:conv_id>/pack/",
        views.GroupEmojiPackView.as_view(),
        name="emoji-group-pack",
    ),
    path(
        "groups/<str:conv_id>/pack/items/",
        views.GroupEmojiItemCreateView.as_view(),
        name="emoji-group-item-add",
    ),
    path(
        "groups/<str:conv_id>/pack/items/<str:item_id>/",
        views.GroupEmojiItemDeleteView.as_view(),
        name="emoji-group-item-delete",
    ),
]
