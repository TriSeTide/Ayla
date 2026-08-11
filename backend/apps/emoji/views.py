"""
表情包 REST 视图（M4-3，挂 /api/v1/emoji/）。

- GET /packs/ 我的 + 系统包；POST /packs/ 建个人包；
- POST /packs/{id}/items/ 收藏；DELETE /packs/{id}/items/{item_id}/ 取消收藏；
- GET /packs/{id}/items/ 包内列表；
- POST /search/ 按 tag/名称检索；
- POST /packs/{id}/set_system/ 系统包管理（管理员）。
"""
from django.db.models import Q
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.media.models import MediaObject
from apps.media.services import get_media_or_none

from . import services
from .models import EmojiItem, EmojiPack
from .serializers import (
    EmojiItemSerializer,
    EmojiPackBriefSerializer,
    EmojiPackSerializer,
)

# 幂等收藏的返回状态
STATUS_CREATED = status.HTTP_201_CREATED


def _pack_or_404(pack_id):
    try:
        return EmojiPack.objects.get(pk=int(pack_id))
    except (EmojiPack.DoesNotExist, ValueError, TypeError):
        return None


class EmojiPackListView(APIView):
    """GET /emoji/packs/ —— 我的 + 系统包。POST —— 建个人包。"""

    def get(self, request):
        packs = (
            EmojiPack.objects.filter(Q(is_system=True) | Q(owner=request.user))
            .prefetch_related("items__media")
            .order_by("-is_system", "-created_at")
        )
        return Response(EmojiPackSerializer(packs, many=True).data)

    def post(self, request):
        name = (request.data.get("name") or "").strip()
        if not name:
            return Response(
                {"detail": "表情包名必填"}, status=status.HTTP_400_BAD_REQUEST
            )
        pack = services.create_personal_pack(request.user, name)
        return Response(
            EmojiPackSerializer(pack).data, status=status.HTTP_201_CREATED
        )


class EmojiPackDetailView(APIView):
    """GET /emoji/packs/<id>/items/ —— 包内表情列表（包 owner 或系统包）。"""

    def get(self, request, pack_id):
        pack = _pack_or_404(pack_id)
        if pack is None:
            return Response({"detail": "表情包不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not services.can_view_pack(request.user, pack):
            return Response({"detail": "无权访问"}, status=status.HTTP_403_FORBIDDEN)
        items = pack.items.select_related("media").order_by("-created_at")
        return Response(EmojiItemSerializer(items, many=True).data)


class EmojiItemCreateView(APIView):
    """POST /emoji/packs/<pack_id>/items/ —— 收藏表情 {media_id, tag?}。"""

    def post(self, request, pack_id):
        pack = _pack_or_404(pack_id)
        if pack is None:
            return Response({"detail": "表情包不存在"}, status=status.HTTP_404_NOT_FOUND)
        media_id = request.data.get("media_id")
        if not media_id:
            return Response(
                {"detail": "需要 media_id"}, status=status.HTTP_400_BAD_REQUEST
            )
        media = get_media_or_none(str(media_id))
        if media is None:
            return Response(
                {"detail": "media_not_found"}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            item, created = services.add_item(
                request.user, pack, media, tag=request.data.get("tag", "")
            )
        except PermissionError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_403_FORBIDDEN)
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        return Response(
            EmojiItemSerializer(item).data,
            status=STATUS_CREATED if created else status.HTTP_200_OK,
        )


class EmojiItemDeleteView(APIView):
    """DELETE /emoji/packs/<pack_id>/items/<item_id>/ —— 取消收藏。"""

    def delete(self, request, pack_id, item_id):
        pack = _pack_or_404(pack_id)
        if pack is None:
            return Response({"detail": "表情包不存在"}, status=status.HTTP_404_NOT_FOUND)
        try:
            item = EmojiItem.objects.get(pk=int(item_id))
        except (EmojiItem.DoesNotExist, ValueError, TypeError):
            return Response({"detail": "表情项不存在"}, status=status.HTTP_404_NOT_FOUND)
        try:
            services.remove_item(request.user, pack, item)
        except PermissionError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_403_FORBIDDEN)
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=status.HTTP_400_BAD_REQUEST)
        return Response(status=status.HTTP_204_NO_CONTENT)


class EmojiSearchView(APIView):
    """POST /emoji/search/ —— 按 tag/名称检索（基础匹配）。"""

    def post(self, request):
        keyword = request.data.get("keyword", "")
        results = services.search_emoji(request.user, str(keyword))
        payload = [
            {
                "pack_id": r["pack"].id,
                "pack_name": r["pack"].name,
                "is_system": r["pack"].is_system,
                "hits": EmojiItemSerializer(r["hits"], many=True).data,
            }
            for r in results
        ]
        return Response(payload)


class EmojiSetSystemView(APIView):
    """POST /emoji/packs/<pack_id>/set_system/ —— 系统包管理（管理员，is_system 切换）。"""

    def post(self, request, pack_id):
        pack = _pack_or_404(pack_id)
        if pack is None:
            return Response({"detail": "表情包不存在"}, status=status.HTTP_404_NOT_FOUND)
        if not request.user.is_superuser:
            return Response(
                {"detail": "仅系统管理员可操作"}, status=status.HTTP_403_FORBIDDEN
            )
        is_system = bool(request.data.get("is_system", True))
        pack.is_system = is_system
        if is_system:
            pack.owner = None
        pack.save(update_fields=["is_system", "owner"])
        return Response(EmojiPackSerializer(pack).data)
