"""
收藏 REST 视图（挂 /api/v1/favorites/，S6）。

- GET  /favorites/：我的收藏列表，可选 ?type=post|live|voice|game|group 过滤；
- POST /favorites/：收藏 {target_type, target_id}，幂等（已收藏 200，新建 201）；
- DELETE /favorites/<id>/：取消收藏（仅本人，非本人 403，不存在 404）。

权限语义：全部 IsAuthenticated；跨类型 target 校验在 services.validate_target。
"""
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services
from .models import Favorite
from .serializers import FavoriteSerializer


def _bad_request(msg):
    return Response({"detail": msg}, status=status.HTTP_400_BAD_REQUEST)


def _forbidden(msg="无权操作"):
    return Response({"detail": msg}, status=status.HTTP_403_FORBIDDEN)


def _not_found(msg="收藏不存在"):
    return Response({"detail": msg}, status=status.HTTP_404_NOT_FOUND)


class FavoriteListView(APIView):
    """GET/POST /favorites/ —— 我的收藏列表 / 收藏。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        qs = Favorite.objects.filter(user=request.user)
        target_type = request.query_params.get("type")
        if target_type:
            if target_type not in {choice[0] for choice in Favorite.TARGET_CHOICES}:
                return _bad_request("target_type 非法")
            qs = qs.filter(target_type=target_type)
        serializer = FavoriteSerializer(qs, many=True, context={"request": request})
        return Response(serializer.data)

    def post(self, request):
        target_type = request.data.get("target_type")
        target_id = request.data.get("target_id")
        try:
            services.validate_target(request.user, target_type, target_id)
        except PermissionError as exc:
            return _forbidden(str(exc))
        except ValueError as exc:
            return _bad_request(str(exc))

        target_id = str(target_id).strip()
        favorite, created = services.add_favorite(request.user, target_type, target_id)
        serializer = FavoriteSerializer(favorite, context={"request": request})
        return Response(serializer.data, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


class FavoriteDetailView(APIView):
    """DELETE /favorites/<id>/ —— 取消收藏（仅本人）。"""

    permission_classes = [IsAuthenticated]

    def delete(self, request, favorite_id):
        try:
            favorite = Favorite.objects.get(pk=favorite_id)
        except (Favorite.DoesNotExist, ValueError, TypeError):
            return _not_found()
        try:
            services.remove_favorite(request.user, favorite)
        except PermissionError as exc:
            return _forbidden(str(exc))
        return Response({"detail": "已取消收藏"})
