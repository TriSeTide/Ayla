"""accounts REST 路由（挂载在 /api/v1/ 下）。"""
from django.urls import path
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from . import views
from .health import HealthView, LiveView

urlpatterns = [
    # 健康检查
    path("health/", HealthView.as_view(), name="health"),
    path("health/live/", LiveView.as_view(), name="health-live"),
    # 认证
    path("auth/register/", views.RegisterView.as_view(), name="register"),
    path(
        "auth/send-email-code/",
        views.SendEmailCodeView.as_view(),
        name="send-email-code",
    ),
    path("auth/login/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("auth/refresh/", TokenRefreshView.as_view(), name="token_refresh"),
    # 隐私设置（JWT）：邮箱验证码换绑/改密
    path("auth/change-password/", views.ChangePasswordView.as_view(), name="change-password"),
    path("auth/change-email/", views.ChangeEmailView.as_view(), name="change-email"),
    # 资料
    path("me/", views.MeView.as_view(), name="me"),
    path("me/profile/", views.ProfileView.as_view(), name="profile"),
    # 未读/待处理聚合（B9）
    path("me/badges/", views.BadgesView.as_view(), name="me-badges"),
    # 用户
    path("users/search/", views.UserSearchView.as_view(), name="user-search"),
    path("users/<str:user_id>/", views.UserDetailView.as_view(), name="user-detail"),
    # 好友
    path("friends/", views.FriendListView.as_view(), name="friend-list"),
    path(
        "friends/requests/",
        views.FriendRequestListView.as_view(),
        name="friend-request-list",
    ),
    path(
        "friends/requests/<int:request_id>/action/",
        views.FriendRequestActionView.as_view(),
        name="friend-request-action",
    ),
    path(
        "friends/<str:user_id>/",
        views.FriendDeleteView.as_view(),
        name="friend-delete",
    ),
]
