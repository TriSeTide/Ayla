"""chat REST 路由（挂载在 /api/v1/chat/ 下）。"""
from django.urls import path

from . import views

urlpatterns = [
    # 会话
    path("conversations/", views.ConversationListView.as_view(), name="chat-conv-list"),
    path(
        "conversations/private/",
        views.PrivateConversationView.as_view(),
        name="chat-conv-private",
    ),
    path("conversations/group/", views.GroupCreateView.as_view(), name="chat-conv-group"),
    # 群动态 highlights（S6）：批量路由放前面，避免与 <int:conv_id> 歧义
    path(
        "conversations/highlights/",
        views.ConversationHighlightsBatchView.as_view(),
        name="chat-conv-highlights-batch",
    ),
    path(
        "conversations/<int:conv_id>/highlights/",
        views.ConversationHighlightsView.as_view(),
        name="chat-conv-highlights",
    ),
    path(
        "conversations/<int:conv_id>/",
        views.ConversationDetailView.as_view(),
        name="chat-conv-detail",
    ),
    # 消息
    path(
        "conversations/<int:conv_id>/read/",
        views.ConversationReadView.as_view(),
        name="chat-conv-read",
    ),
    path(
        "conversations/<int:conv_id>/messages/",
        views.MessageView.as_view(),
        name="chat-messages",
    ),
    path(
        "conversations/<int:conv_id>/messages/<int:mid>/read/",
        views.MessageReadView.as_view(),
        name="chat-msg-read",
    ),
    path(
        "conversations/<int:conv_id>/messages/<int:mid>/recall/",
        views.MessageRecallView.as_view(),
        name="chat-msg-recall",
    ),
    path(
        "conversations/<int:conv_id>/typing/",
        views.TypingView.as_view(),
        name="chat-typing",
    ),
    # 群管理
    path(
        "conversations/<int:conv_id>/members/",
        views.MemberAddView.as_view(),
        name="chat-member-add",
    ),
    path(
        "conversations/<int:conv_id>/members/<str:user_id>/",
        views.MemberRemoveView.as_view(),
        name="chat-member-remove",
    ),
    path(
        "conversations/<int:conv_id>/members/<str:user_id>/mute/",
        views.MemberMuteView.as_view(),
        name="chat-member-mute",
    ),
    # 群申请/邀请（S2，开发文档 §1.2）
    path(
        "conversations/<int:conv_id>/join-requests/",
        views.GroupJoinRequestView.as_view(),
        name="chat-join-requests",
    ),
    path(
        "join-requests/<int:request_id>/action/",
        views.GroupJoinRequestActionView.as_view(),
        name="chat-join-request-action",
    ),
    path(
        "conversations/<int:conv_id>/invites/",
        views.GroupInviteView.as_view(),
        name="chat-group-invite",
    ),
    path("me/invites/", views.MyInvitesView.as_view(), name="chat-my-invites"),
    path(
        "invites/<int:invite_id>/action/",
        views.GroupInviteActionView.as_view(),
        name="chat-group-invite-action",
    ),
]
