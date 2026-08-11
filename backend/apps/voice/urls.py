"""语音频道 REST 路由（挂载在 /api/v1/voice/ 下，M4-5 §6）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("channels/", views.ChannelListView.as_view(), name="voice-channel-list"),
    path(
        "channels/<int:channel_id>/",
        views.ChannelDetailView.as_view(),
        name="voice-channel-detail",
    ),
    path(
        "channels/<int:channel_id>/join/",
        views.ChannelJoinView.as_view(),
        name="voice-channel-join",
    ),
    path(
        "channels/<int:channel_id>/leave/",
        views.ChannelLeaveView.as_view(),
        name="voice-channel-leave",
    ),
    path(
        "channels/<int:channel_id>/heartbeat/",
        views.ChannelHeartbeatView.as_view(),
        name="voice-channel-heartbeat",
    ),
    path(
        "channels/<int:channel_id>/members/",
        views.ChannelMembersView.as_view(),
        name="voice-channel-members",
    ),
]
