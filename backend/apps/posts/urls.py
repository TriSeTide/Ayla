"""帖子 REST 路由（挂载在 /api/v1/posts/ 下，S3 开发文档 §1.3）。"""
from django.urls import path

from . import views

urlpatterns = [
    path("", views.PostListView.as_view(), name="post-list"),
    path("views/", views.PostViewBulkView.as_view(), name="post-views"),
    path("<int:post_id>/", views.PostDetailView.as_view(), name="post-detail"),
    path(
        "<int:post_id>/comments/",
        views.CommentListView.as_view(),
        name="post-comments",
    ),
    path(
        "comments/<int:comment_id>/",
        views.CommentDetailView.as_view(),
        name="comment-detail",
    ),
]
