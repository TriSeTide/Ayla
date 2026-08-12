"""直播 REST 路由（挂载在 /api/v1/live/ 下，M4-6 §5）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("channels/", views.ChannelListView.as_view(), name="live-channel-list"),
    path(
        "channels/<int:channel_id>/",
        views.ChannelDetailView.as_view(),
        name="live-channel-detail",
    ),
    path(
        "channels/<int:channel_id>:start/",
        views.ChannelStartView.as_view(),
        name="live-channel-start",
    ),
    path(
        "channels/<int:channel_id>:stop/",
        views.ChannelStopView.as_view(),
        name="live-channel-stop",
    ),
    path(
        "channels/<int:channel_id>/status/",
        views.ChannelStatusView.as_view(),
        name="live-channel-status",
    ),
    path(
        "channels/<int:channel_id>/danmaku/",
        views.DanmakuListView.as_view(),
        name="live-danmaku-list",
    ),
]
