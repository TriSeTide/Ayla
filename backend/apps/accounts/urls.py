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
    path("auth/login/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("auth/refresh/", TokenRefreshView.as_view(), name="token_refresh"),
    # 资料
    path("me/", views.MeView.as_view(), name="me"),
    path("me/profile/", views.ProfileView.as_view(), name="profile"),
    # 用户
    path("users/search/", views.UserSearchView.as_view(), name="user-search"),
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
