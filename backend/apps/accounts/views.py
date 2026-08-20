"""accounts 视图。"""
from django.contrib.auth import get_user_model
from django.db.models import Q
from django.utils import timezone
from rest_framework import generics, permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken

from .models import FriendRequest, Friendship
from .serializers import (
    FriendRequestActionSerializer,
    FriendRequestSerializer,
    FriendshipSerializer,
    ProfileSerializer,
    RegisterSerializer,
    UserPublicSerializer,
)
User = get_user_model()


# ---------- 注册 / 令牌 ----------

class RegisterView(generics.CreateAPIView):
    """注册：返回用户 + access/refresh。"""

    permission_classes = [permissions.AllowAny]
    serializer_class = RegisterSerializer

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = serializer.save()
        refresh = RefreshToken.for_user(user)
        payload = {
            "user": UserPublicSerializer(user, context={"request": request}).data,
            "access": str(refresh.access_token),
            "refresh": str(refresh),
        }
        return Response(payload, status=status.HTTP_201_CREATED)


# ---------- 资料 ----------

class ProfileView(generics.RetrieveUpdateAPIView):
    """读取/修改本人资料。"""

    serializer_class = ProfileSerializer

    def get_object(self):
        return self.request.user


class MeView(APIView):
    """当前登录用户信息。"""

    def get(self, request):
        data = UserPublicSerializer(request.user, context={"request": request}).data
        return Response(data)


class BadgesView(APIView):
    """GET /me/badges/ —— 全站未读与待处理聚合（开发文档 §1.8，B9）。

    返回 {private_unread, group_unread, friend_requests, group_invites, join_requests_pending}。
    未读口径与 ConversationSerializer.get_unread_count 一致：非本人发送、非撤回、
    且无我的 MessageRead 记录的消息。（conversation__members__user=user 的 join
    不会产生重复行：ConversationMember 的 (conversation, user) 唯一。）
    """

    def get(self, request):
        from apps.chat.models import (
            Conversation,
            ConversationMember,
            GroupInvite,
            GroupJoinRequest,
            Message,
        )

        user = request.user
        unread = (
            Message.objects.filter(conversation__members__user=user)
            .exclude(sender=user)
            .exclude(status=Message.STATUS_RECALLED)
            .exclude(reads__user=user)
        )
        friend_requests = FriendRequest.objects.filter(
            to_user=user, status=FriendRequest.STATUS_PENDING
        ).count()
        group_invites = GroupInvite.objects.filter(
            invitee=user, status=GroupInvite.STATUS_PENDING
        ).count()
        # 我作为 owner/admin 的群收到的待审批入群申请
        managed_group_ids = ConversationMember.objects.filter(
            user=user,
            role__in=[ConversationMember.ROLE_ADMIN, ConversationMember.ROLE_OWNER],
            conversation__type=Conversation.TYPE_GROUP,
        ).values_list("conversation_id", flat=True)
        join_requests_pending = GroupJoinRequest.objects.filter(
            conversation_id__in=managed_group_ids,
            status=GroupJoinRequest.STATUS_PENDING,
        ).count()
        return Response(
            {
                "private_unread": unread.filter(
                    conversation__type=Conversation.TYPE_PRIVATE
                ).count(),
                "group_unread": unread.filter(
                    conversation__type=Conversation.TYPE_GROUP
                ).count(),
                "friend_requests": friend_requests,
                "group_invites": group_invites,
                "join_requests_pending": join_requests_pending,
            }
        )


# ---------- 用户搜索 ----------

class UserSearchView(generics.ListAPIView):
    """按用户名/昵称搜索用户。"""

    serializer_class = UserPublicSerializer

    def get_queryset(self):
        q = self.request.query_params.get("q", "").strip()
        qs = User.objects.exclude(pk=self.request.user.pk)
        if not q:
            return qs.none()
        return qs.filter(Q(username__icontains=q) | Q(nickname__icontains=q))[:20]


class UserDetailView(APIView):
    """GET /users/<id>/ —— 他人主页：公开资料 + 与我（当前用户）的好友关系。

    关系 relation 取值：
    - self：目标就是当前用户；
    - friend：已是好友；
    - pending_sent：我向对方发出的待处理申请；
    - pending_received：对方向我发出的待处理申请；
    - none：无任何关系（可发起加好友）。
    """

    permission_classes = [permissions.IsAuthenticated]

    def get(self, request, user_id):
        try:
            target = User.objects.get(pk=user_id)
        except (User.DoesNotExist, ValueError, TypeError):
            return Response({"detail": "用户不存在"}, status=status.HTTP_404_NOT_FOUND)

        if str(target.pk) == str(request.user.pk):
            relation = "self"
        elif Friendship.objects.filter(
            user=request.user, friend=target, status=Friendship.STATUS_ACCEPTED
        ).exists():
            relation = "friend"
        elif FriendRequest.objects.filter(
            from_user=request.user, to_user=target, status=FriendRequest.STATUS_PENDING
        ).exists():
            relation = "pending_sent"
        elif FriendRequest.objects.filter(
            from_user=target, to_user=request.user, status=FriendRequest.STATUS_PENDING
        ).exists():
            relation = "pending_received"
        else:
            relation = "none"

        data = UserPublicSerializer(target, context={"request": request}).data
        data["relation"] = relation
        return Response(data)


# ---------- 好友 ----------

class FriendListView(generics.ListAPIView):
    """好友列表。"""

    serializer_class = FriendshipSerializer

    def get_queryset(self):
        return Friendship.objects.filter(
            user=self.request.user, status=Friendship.STATUS_ACCEPTED
        ).select_related("friend")


class FriendRequestListView(generics.ListCreateAPIView):
    """收到的待处理申请（GET）+ 发起好友申请（POST）。"""

    serializer_class = FriendRequestSerializer

    def get_queryset(self):
        return FriendRequest.objects.filter(
            Q(to_user=self.request.user) | Q(from_user=self.request.user)
        ).select_related("from_user", "to_user").order_by("-created_at")


class FriendRequestActionView(APIView):
    """同意/拒绝好友申请。"""

    def post(self, request, request_id):
        try:
            req = FriendRequest.objects.get(
                pk=request_id, to_user=request.user, status="pending"
            )
        except FriendRequest.DoesNotExist:
            return Response({"detail": "申请不存在或已处理"}, status=status.HTTP_404_NOT_FOUND)

        ser = FriendRequestActionSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        action = ser.validated_data["action"]

        if action == "accept":
            req.status = FriendRequest.STATUS_ACCEPTED
            req.handled_at = timezone.now()
            req.save(update_fields=["status", "handled_at"])
            # 建立双向好友关系
            Friendship.objects.get_or_create(
                user=request.user, friend=req.from_user, defaults={"status": "accepted"}
            )
            Friendship.objects.get_or_create(
                user=req.from_user, friend=request.user, defaults={"status": "accepted"}
            )
            return Response({"detail": "已同意", "status": "accepted"})
        else:
            req.status = FriendRequest.STATUS_REJECTED
            req.handled_at = timezone.now()
            req.save(update_fields=["status", "handled_at"])
            return Response({"detail": "已拒绝", "status": "rejected"})


class FriendDeleteView(APIView):
    """删除好友（双向删除）。"""

    def delete(self, request, user_id):
        deleted = Friendship.objects.filter(
            Q(user=request.user, friend_id=user_id)
            | Q(user_id=user_id, friend=request.user)
        ).delete()
        if deleted[0] == 0:
            return Response({"detail": "不是好友"}, status=status.HTTP_404_NOT_FOUND)
        return Response(status=status.HTTP_204_NO_CONTENT)
