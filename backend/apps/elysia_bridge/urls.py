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
    # 爱莉 Voice Live 编排（M4-5 §5.2 基线方案）
    path(
        "voice-calls/",
        views.ElysiaVoiceCallView.as_view(),
        name="elysia-voice-calls",
    ),
    path(
        "voice-calls/<str:call_id>/",
        views.ElysiaVoiceCallDetailView.as_view(),
        name="elysia-voice-call-detail",
    ),
    path(
        "voice-calls/<str:call_id>/text/",
        views.ElysiaVoiceCallTextView.as_view(),
        name="elysia-voice-call-text",
    ),
    path(
        "voice-calls/<str:call_id>/end/",
        views.ElysiaVoiceCallEndView.as_view(),
        name="elysia-voice-call-end",
    ),
    path(
        "voice-calls/<str:call_id>/poll/",
        views.ElysiaVoiceCallPollView.as_view(),
        name="elysia-voice-call-poll",
    ),
]
