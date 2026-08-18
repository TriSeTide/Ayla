"""
帖子 REST 视图（挂 /api/v1/posts/，S3 开发文档 §1.3）。

- GET/POST /posts/：信息流（scope=feed|group:<id>|mine，游标分页）/ 发帖；
- GET/PATCH/DELETE /posts/<id>/：详情 / 编辑 / 删除（PATCH/DELETE 仅 author）；
- GET/POST /posts/<id>/comments/：评论列表 / 发评论（reply_to 须在本帖内）；
- DELETE /comments/<id>/：删评论（仅评论作者）。

权限语义（工程约束）：
- 列表/详情/评论按 apps/common/visibility.py 过滤与校验（不可见 → 403）；
- 仅 author 可改删帖子；仅评论作者可删评论。
"""
from django.db.models import Q
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.common.visibility import can_view, visible_queryset

from . import services
from .models import Comment, Post
from .serializers import (
    CommentSerializer,
    CreateCommentSerializer,
    CreatePostSerializer,
    PostSerializer,
    UpdatePostSerializer,
)

FEED_DEFAULT_LIMIT = 20
FEED_MAX_LIMIT = 100


def _get_post_or_404(post_id):
    try:
        return (
            Post.objects.select_related("owner", "group")
            .prefetch_related("images__media")
            .get(pk=post_id)
        )
    except (Post.DoesNotExist, ValueError, TypeError):
        return None


def _get_comment_or_404(post, comment_id):
    try:
        return Comment.objects.get(pk=comment_id, post=post)
    except (Comment.DoesNotExist, ValueError, TypeError):
        return None


def _forbidden(msg="无权访问"):
    return Response({"detail": msg}, status=status.HTTP_403_FORBIDDEN)


def _not_found(msg="不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


def _bad_request(msg):
    return Response({"detail": msg}, status=status.HTTP_400_BAD_REQUEST)


def _parse_limit(request) -> int:
    try:
        limit = int(request.query_params.get("limit", FEED_DEFAULT_LIMIT))
    except (TypeError, ValueError):
        limit = FEED_DEFAULT_LIMIT
    return max(1, min(limit, FEED_MAX_LIMIT))


class PostListView(APIView):
    """GET /posts/（信息流游标分页）/ POST /posts/（发帖）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        scope = request.query_params.get("scope") or "feed"
        qs = (
            visible_queryset(Post, request.user)
            .select_related("owner", "group")
            .prefetch_related("images__media")
        )

        if scope == "mine":
            qs = qs.filter(owner=request.user)
        elif scope == "feed":
            pass
        elif scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return _bad_request("group id 无效")
            qs = qs.filter(group_id=gid)
        else:
            return _bad_request("scope 无效")

        qs = qs.order_by("-created_at", "-id")

        cursor = request.query_params.get("cursor")
        if cursor:
            try:
                dt, pid = services.decode_cursor(cursor)
            except ValueError as exc:
                return _bad_request(str(exc))
            qs = qs.filter(Q(created_at__lt=dt) | Q(created_at=dt, id__lt=pid))

        limit = _parse_limit(request)
        rows = list(qs[: limit + 1])
        has_more = len(rows) > limit
        results = rows[:limit]
        next_cursor = services.encode_cursor(results[-1]) if has_more and results else None

        return Response(
            {
                "results": PostSerializer(
                    results, many=True, context={"request": request}
                ).data,
                "next_cursor": next_cursor,
                "has_more": has_more,
            }
        )

    def post(self, request):
        ser = CreatePostSerializer(data=request.data, context={"request": request})
        ser.is_valid(raise_exception=True)
        data = ser.validated_data

        group, group_err = _get_group_or_400(data.get("group"))
        if group_err:
            return _bad_request(group_err)
        try:
            post = services.create_post(
                request.user,
                title=data.get("title") or "",
                body=data["body"],
                images=data.get("images") or [],
                group=group,
                visibility=data.get("visibility"),
                allowed_group_ids=data.get("allowed_group_ids"),
            )
        except ValueError as exc:
            return _bad_request(str(exc))
        return Response(
            PostSerializer(post, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )


class PostDetailView(APIView):
    """GET/PATCH/DELETE /posts/<id>/ —— 详情 / 编辑 / 删除（PATCH/DELETE 仅 author）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, post_id):
        post = _get_post_or_404(post_id)
        if post is None:
            return _not_found("帖子不存在")
        if not can_view(request.user, post):
            return _forbidden("无权查看该帖子")
        return Response(PostSerializer(post, context={"request": request}).data)

    def patch(self, request, post_id):
        post = _get_post_or_404(post_id)
        if post is None:
            return _not_found("帖子不存在")
        if post.owner_id != request.user.id:
            return _forbidden("仅作者可修改")
        ser = UpdatePostSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        data = ser.validated_data
        if "title" in data:
            post.title = (data["title"] or "").strip()
        if "body" in data:
            post.body = (data["body"] or "").strip()
        if "visibility" in request.data:
            value = request.data.get("visibility")
            if value not in {"public", "friends", "group"}:
                return _bad_request("visibility 无效")
            post.visibility = value
        if "group" in request.data:
            group, group_err = _get_group_or_400(request.data.get("group"))
            if group_err:
                return _bad_request(group_err)
            post.group = group
        if "allowed_group_ids" in request.data:
            try:
                from apps.common.visibility import set_allowed_groups
                set_allowed_groups(post, request.data.get("allowed_group_ids"))
            except ValueError as exc:
                return _bad_request(str(exc))
        update_fields = ["title", "body"]
        if "visibility" in request.data:
            update_fields.append("visibility")
        if "group" in request.data:
            update_fields.append("group")
        post.save(update_fields=update_fields)
        return Response(PostSerializer(post, context={"request": request}).data)

    def delete(self, request, post_id):
        post = _get_post_or_404(post_id)
        if post is None:
            return _not_found("帖子不存在")
        if post.owner_id != request.user.id:
            return _forbidden("仅作者可删除")
        post.delete()
        return Response({"deleted": True})


class CommentListView(APIView):
    """GET/POST /posts/<id>/comments/ —— 评论列表 / 发评论。"""

    permission_classes = [IsAuthenticated]

    def get(self, request, post_id):
        post = _get_post_or_404(post_id)
        if post is None:
            return _not_found("帖子不存在")
        if not can_view(request.user, post):
            return _forbidden("无权查看该帖子")
        qs = post.comments.select_related("author").order_by("created_at", "id")
        return Response(
            CommentSerializer(qs, many=True, context={"request": request}).data
        )

    def post(self, request, post_id):
        post = _get_post_or_404(post_id)
        if post is None:
            return _not_found("帖子不存在")
        if not can_view(request.user, post):
            return _forbidden("无权评论该帖子")
        ser = CreateCommentSerializer(data=request.data, context={"request": request})
        ser.is_valid(raise_exception=True)
        data = ser.validated_data

        reply_to = None
        if data.get("reply_to"):
            reply_to = _get_comment_or_404(post, data["reply_to"])
            if reply_to is None:
                return _not_found("回复的评论不存在")
        comment = services.create_comment(
            post, request.user, data["body"], reply_to, data.get("media_id")
        )
        return Response(
            CommentSerializer(comment, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )


class CommentDetailView(APIView):
    """DELETE /comments/<id>/ —— 删评论（仅评论作者）。"""

    permission_classes = [IsAuthenticated]

    def delete(self, request, comment_id):
        try:
            comment = Comment.objects.get(pk=comment_id)
        except (Comment.DoesNotExist, ValueError, TypeError):
            return _not_found("评论不存在")
        if comment.author_id != request.user.id:
            return _forbidden("仅评论作者可删除")
        comment.delete()
        return Response({"deleted": True})


def _get_group_or_400(group_id):
    """解析创建参数里的群归属：必须是存在的群聊会话；非法值返回 (None, error) 或 (obj, None)。"""
    from apps.chat.models import Conversation

    if group_id in (None, "", "null"):
        return None, None
    conv = Conversation.objects.filter(pk=group_id).first()
    if conv is None:
        return None, "群不存在"
    if conv.type != Conversation.TYPE_GROUP:
        return None, "群归属必须是群聊会话"
    return conv, None
