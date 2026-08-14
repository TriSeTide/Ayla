"""
S5 聚合搜索视图 —— `GET /api/v1/search/`。

查询参数：
- `q`：关键字，必填；strip 后为空 → 400 `{"detail": "q 不能为空"}`；
- `types`：逗号分隔类型子集（user/group/post/live/game），缺省=全部，非法忽略；
- `limit`：每组截断条数，默认 10，上限 50，下限 1。

返回：按请求类型给出 `{items, total}` 分组（只含被请求的类型）。
"""
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services


class SearchView(APIView):
    """聚合搜索入口（只读，无写路径、无模型）。"""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        q = request.query_params.get("q")
        if not (q or "").strip():
            return Response({"detail": "q 不能为空"}, status=status.HTTP_400_BAD_REQUEST)
        q = q.strip()

        types = services.parse_types(request.query_params.get("types"))
        limit = services.parse_limit(request.query_params.get("limit"))

        payload: dict = {}
        # 顺序与契约一致：users/groups/posts/lives/games，仅输出被请求的类型
        for type_name in types:
            if type_name == services.TYPE_USERS:
                payload["users"] = services.search_users(q, limit, request)
            elif type_name == services.TYPE_GROUPS:
                payload["groups"] = services.search_groups(q, limit)
            elif type_name == services.TYPE_POSTS:
                payload["posts"] = services.search_posts(q, limit, request)
            elif type_name == services.TYPE_LIVES:
                payload["lives"] = services.search_lives(q, limit, request)
            elif type_name == services.TYPE_GAMES:
                payload["games"] = services.search_games(q, limit, request)
        return Response(payload)
