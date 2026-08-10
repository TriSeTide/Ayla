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


# ---------- 好友 ----------

class FriendListView(generics.ListAPIView):
    """好友列表。"""

    serializer_class = FriendshipSerializer

    def get_queryset(self):
        return Friendship.objects.filter(
            user=self.request.user, status=Friendship.STATUS_ACCEPTED
        ).select_related("user")


class FriendRequestListView(generics.ListCreateAPIView):
    """收到的待处理申请（GET）+ 发起好友申请（POST）。"""

    serializer_class = FriendRequestSerializer

    def get_queryset(self):
        return FriendRequest.objects.filter(
            to_user=self.request.user, status=FriendRequest.STATUS_PENDING
        ).select_related("from_user", "to_user")


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
