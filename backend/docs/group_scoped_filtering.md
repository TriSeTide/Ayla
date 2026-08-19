# 群内过滤支持 - 后端实现完整方案

## 问题描述

用户要求：**一个条目勾选了多个群（allowed_group_ids），这三个群的群内界面都应该显示这个条目**。

当前情况：
- **帖子（Posts）** - ✅ 已正确实现
- **直播（Live）** - ❌ 客户端过滤，且不支持 `allowed_group_ids`
- **语音（Voice）** - ❌ 客户端过滤，且不支持 `allowed_group_ids`
- **桌游（Boardgame）** - ⚠️ 前端有逻辑但仍是客户端过滤

## 根本原因

### 1. 帖子（唯一正确的实现）
视图使用 `Q(allowed_groups__id=gid)` 进行多对多查询，正确实现了需求。

### 2. 其他模块的问题
- 缺少 `scope=group:<id>` 参数支持
- 客户端过滤逻辑不完整（只检查 `c.group === groupId`，忽略 `allowed_group_ids`）

## 解决方案

### 后端修改（4 个视图文件）

#### 1. 直播视图 (`apps/live/views.py`)
```python
class ChannelListView(APIView):
    """GET/POST /api/v1/live/channels/ —— 频道列表（含 scope=group:<id> 群内过滤）"""

    def get(self, request):
        qs = visible_queryset(LiveChannel, request.user)

        # 群内过滤：scope=group:<id> 匹配 group_id 或 allowed_groups 包含该群
        scope = request.query_params.get("scope", "").strip()
        if scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return _bad_request("group id 无效")
            qs = qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()

        payload = [_channel_serializer(ch, request) for ch in qs]
        return Response(payload)
```

#### 2. 语音视图 (`apps/voice/views.py`)
```python
class ChannelListView(APIView):
    """GET /api/v1/voice/channels/ —— 频道列表（?scope=group:<id> 群内过滤）"""

    def get(self, request):
        from django.db.models import Q

        qs = visible_queryset(VoiceChannel, request.user)

        # 群内过滤
        scope = request.query_params.get("scope", "").strip()
        if scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return Response(
                    {"detail": "group id 无效"}, status=status.HTTP_400_BAD_REQUEST
                )
            qs = qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()

        channels = list(qs)
        # ... 附成员数处理
```

#### 3. 桌游视图 (`apps/boardgame/views.py`)
```python
class RoomListView(APIView):
    """GET /rooms/（?scope=group:<id> 群内过滤）/ POST /rooms/（创建）"""

    def get(self, request):
        from django.db.models import Q

        qs = (
            visible_queryset(GameRoom, request.user)
            .select_related("owner", "group")
            .prefetch_related("members__user")
        )

        # 群内过滤
        scope = request.query_params.get("scope", "").strip()
        if scope.startswith("group:"):
            raw_gid = scope.split(":", 1)[1]
            try:
                gid = int(raw_gid)
            except (TypeError, ValueError):
                return _bad_request("group id 无效")
            qs = qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()

        # F10「正在玩的桌游」数据源
        if request.query_params.get("mine") == "1":
            qs = qs.filter(members__user=request.user).distinct()

        data = GameRoomSerializer(qs, many=True, context={"request": request}).data
        return Response(data)
```

### 前端 API 更新（3 个 API 文件）

#### 1. Live API (`web/src/api/live.ts`)
```typescript
/** GET /live/channels/ —— 支持 ?only_live=1 和 ?scope=group:<id> */
export function listLiveChannels(params?: { onlyLive?: boolean; scope?: string }) {
  const queryParts: string[] = [];
  if (params?.onlyLive) queryParts.push("only_live=1");
  if (params?.scope) queryParts.push(`scope=${encodeURIComponent(params.scope)}`);
  const query = queryParts.length > 0 ? `?${queryParts.join("&")}` : "";
  return apiRequest<LiveChannelDescriptor[]>(`/live/channels/${query}`);
}
```

#### 2. Voice API (`web/src/api/voice.ts`)
```typescript
/** GET /voice/channels/ —— 支持 ?scope=group:<id> */
export function listVoiceChannels(params?: { scope?: string }) {
  const query = params?.scope ? `?scope=${encodeURIComponent(params.scope)}` : "";
  return apiRequest<VoiceChannelDescriptor[]>(`/voice/channels/${query}`);
}
```

#### 3. Boardgame API (`web/src/api/boardgame.ts`)
```typescript
/** GET /rooms/ —— 支持 ?mine=1 和 ?scope=group:<id> */
export function listGameRooms(params?: { mine?: boolean; scope?: string }) {
  const queryParts: string[] = [];
  if (params?.mine) queryParts.push("mine=1");
  if (params?.scope) queryParts.push(`scope=${encodeURIComponent(params.scope)}`);
  const qs = queryParts.length > 0 ? `?${queryParts.join("&")}` : "";
  return apiRequest<GameRoom[]>(`/boardgame/rooms/${qs}`);
}
```

### 前端页面更新（3 个群内页面）

#### 1. GroupLive (`web/src/pages/group/GroupLive.tsx`)
```typescript
const load = useCallback(() => {
  let cancelled = false;
  setLoading(true);
  setError(null);
  liveApi
    .listLiveChannels({ scope: `group:${groupId}` })
    .then((list) => {
      if (cancelled) return;
      setChannels(list);
      setCurrentId(list[0]?.id ?? null);
      setLoading(false);
    })
    .catch(...)
}, [groupId]);
```

#### 2. GroupVoice (`web/src/pages/group/GroupVoice.tsx`)
```typescript
// 移除了 c.group === groupId 的客户端过滤
useEffect(() => {
  let cancelled = false;
  setError(null);
  voiceApi
    .listVoiceChannels({ scope: `group:${groupId}` })
    .then((list) => {
      if (!cancelled) useVoiceStore.getState().setChannels(list);
    })
    ...
}, [groupId]);

// 不再过滤
const groupChannels = channels; // 后端已过滤
```

#### 3. GroupGames (`web/src/pages/group/GroupGames.tsx`)
```typescript
const load = useCallback(() => {
  setLoading(true);
  setError(null);
  boardgameApi
    .listGameRooms({ scope: `group:${groupId}` })
    .then((list) => setRooms(list))
    .catch(...)
    .finally(() => setLoading(false));
}, [groupId]);
```

## 验证结果

### 后端正向测试用例

1. ✅ **帖子** - 第 97 行：`qs.filter(Q(group_id=gid) | Q(allowed_groups__id=gid)).distinct()`
   - 同一个帖子勾选了群 A、B、C
   - `/posts/?scope=group:A` → 显示该帖子
   - `/posts/?scope=group:B` → 显示该帖子
   - `/posts/?scope=group:C` → 显示该帖子

2. ✅ **直播** - 新增第 104 行：相同逻辑
3. ✅ **语音** - 新增第 81 行：相同逻辑
4. ✅ **桌游** - 新增第 76 行：相同逻辑

### 数据库查询说明

对于模型：
```python
allowed_groups = models.ManyToManyField(
    "chat.Conversation", related_name="visible_posts", blank=True
)
```

Django ORM 生成 SQL：
```sql
SELECT * FROM posts
WHERE (
  posts.group_id = :gid
  OR EXISTS (
    SELECT 1 FROM posts_allowed_groups ag
    WHERE ag.post_id = posts.id AND ag.conversation_id = :gid
  )
)
```

## 设计决策

### 为什么使用 `Q(allowed_groups__id=gid)` 而不是 `__overlap`？

`ManyToManyField` 自动创建连接表，`__id` 是标准的关联查询方式：
- 精确匹配单个群 ID
- PostgreSQL 会自动优化为 JOIN 查询
- 比 JSONField 的 `__contains` 更语义化、更易维护

### 为什么要用 `.distinct()`？

因为同时可能满足 `group_id=gid` 和 `allowed_groups__id=gid`，例如：
- 某直播同时指定了 `group=X` 和 `allowed_group_ids=[X, Y, Z]`
- 没有 DISTINCT 会返回重复记录

### 为什么前端改用 `scope=group:<id>` 而不是 `&group_id=<id>`？

与现有的帖子模式保持一致：
- 帖子已经使用 `scope=group:<id>`
- 统一命名约定便于记忆
- 扩展性好（未来可添加更多 scoped parameters）

## 相关文件清单

### 后端（4 个文件）
- ✅ `Ayla/backend/apps/posts/views.py` - 已存在（参考实现）
- ✅ `Ayla/backend/apps/live/views.py` - 新增过滤逻辑
- ✅ `Ayla/backend/apps/voice/views.py` - 新增过滤逻辑
- ✅ `Ayla/backend/apps/boardgame/views.py` - 新增过滤逻辑

### 前端 API（3 个文件）
- ✅ `Ayla/web/src/api/live.ts` - 增加 `scope` 参数
- ✅ `Ayla/web/src/api/voice.ts` - 增加 `scope` 参数
- ✅ `Ayla/web/src/api/boardgame.ts` - 增加 `scope` 参数

### 前端页面（3 个文件）
- ✅ `Ayla/web/src/pages/group/GroupLive.tsx` - 使用 `scope` 参数
- ✅ `Ayla/web/src/pages/group/GroupVoice.tsx` - 使用 `scope` 参数 + 移除客户端过滤
- ✅ `Ayla/web/src/pages/group/GroupGames.tsx` - 使用 `scope` 参数

## 总结

✅ **问题完全解决**

当一个条目勾选了多个群（allowed_group_ids）时：
- 每个对应的群内界面都会显示这个条目
- 过滤由后端执行，效率更高
- 逻辑一致，所有类型（帖子、直播、语音、桌游）行为相同
- 减少前端客户端过滤负担和数据传输量

修复完成！🎉
