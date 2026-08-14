"""桌游 REST 路由（挂载在 /api/v1/boardgame/ 下，S4 开发文档 §1.4）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("rooms/", views.RoomListView.as_view(), name="boardgame-room-list"),
    # `:join`/`:leave` 后缀路径排在裸 `<int:room_id>/` 之前，与 media `:complete` 同理保持可读。
    path(
        "rooms/<int:room_id>:join/",
        views.RoomJoinView.as_view(),
        name="boardgame-room-join",
    ),
    path(
        "rooms/<int:room_id>:leave/",
        views.RoomLeaveView.as_view(),
        name="boardgame-room-leave",
    ),
    path(
        "rooms/<int:room_id>/",
        views.RoomDetailView.as_view(),
        name="boardgame-room-detail",
    ),
]
