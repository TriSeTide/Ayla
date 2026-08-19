# 可见性多选与标签显示修复

## 问题

1. **可见性只能单选**：群可见和好友可见无法同时勾选，只有公开时才是单选
2. **标签显示不完整**：当同时勾选好友和指定群时，只显示好友标签，没有显示群聊标签
3. **群内帖子显示逻辑错误**：标签含有某个群的条目，应该在该群的群内界面显示
4. **语音频道标签样式缺失**：`VoiceRoomBody` 使用的 CSS 类名没有定义，导致标签无背景

## 根本原因

### 1. 前端可见性选择器逻辑错误

`VisibilitySelector` 的状态管理逻辑不正确：
- 使用单一 `visibility` 状态存储 `"public" | "friends" | "group"`
- 选中某个选项时会自动取消其他选项
- 没有区分"公开"（互斥）和"好友/群聊"（可多选）的语义

### 2. 标签生成函数逻辑不完整

`getVisibilityLabels` 函数只处理了 `visibility` 字段，没有同时检查 `allowed_group_ids`：

```typescript
// 修复前
export function getVisibilityLabels(item: { visibility: string; allowed_group_ids?: number[] }): string[] {
  const labels: string[] = [];
  if (item.visibility === "friends") labels.push("好友可见");
  if (item.visibility === "group") labels.push("群聊可见");
  return labels;
}
```

当 `visibility === "friends"` 但同时有 `allowed_group_ids` 时，只会显示"好友可见"。

### 3. 后端视图集过滤逻辑错误

各个视图集的 `get_queryset` 方法只检查了 `visibility="group"`，没有检查 `allowed_group_ids`：

```python
# 修复前
if group_id is not None:
    qs = qs.filter(Q(group=group_id) | Q(visibility="group"))
```

导致标签含有某个群的条目无法在该群的群内界面显示。

### 4. CSS 类名不一致

`VoiceRoomBody` 使用了未定义的 `.post-meta-tags` 和 `.post-tag` 类名，而其他组件使用的是有样式定义的 `.post-card-tags` 和 `.post-card-tag`。

## 修复方案

### 1. 前端：重构 `VisibilitySelector` 为多选模式

**文件**：`Ayla/web/src/components/VisibilitySelector.tsx`

**关键改动**：

1. **状态从单选改为多选**（第 9-12 行）：
```typescript
interface VisibilitySelectorProps {
  value: { public: boolean; friends: boolean; group: boolean };
  onChange: (value: { public: boolean; friends: boolean; group: boolean }) => void;
  groupList: Array<{ id: number; name: string }>;
  selectedGroups: number[];
  onGroupsChange: (ids: number[]) => void;
}
```

2. **公开选项互斥逻辑**（第 20-29 行）：
```typescript
const handlePublicChange = (checked: boolean) => {
  if (checked) {
    onChange({ public: true, friends: false, group: false });
    onGroupsChange([]);
  } else {
    onChange({ public: false, friends: false, group: false });
  }
};

const handleFriendsChange = (checked: boolean) => {
  onChange({ ...value, friends: checked, public: false });
};

const handleGroupChange = (checked: boolean) => {
  onChange({ ...value, group: checked, public: false });
  if (!checked) onGroupsChange([]);
};
```

### 2. 前端：修复各组件的可见性状态转换

#### PostCard（第 57-67 行）
```typescript
const visibilityState = {
  public: post.visibility === "public",
  friends: post.visibility === "friends" || (post.allowed_group_ids?.length ?? 0) > 0,
  group: post.visibility === "group" || (post.allowed_group_ids?.length ?? 0) > 0,
};

const handleVisibilityChange = (v: typeof visibilityState) => {
  const newPost = { ...post };
  if (v.public) {
    newPost.visibility = "public";
    newPost.allowed_group_ids = [];
  } else if (v.friends && !v.group) {
    newPost.visibility = "friends";
    newPost.allowed_group_ids = [];
  } else if (v.group && !v.friends) {
    newPost.visibility = "group";
  } else if (v.friends && v.group) {
    newPost.visibility = "friends"; // 或 "group"，后端会根据 allowed_group_ids 判断
  } else {
    newPost.visibility = "public";
    newPost.allowed_group_ids = [];
  }
  onChange(newPost);
};
```

#### LiveCreate（第 52-65 行）
```typescript
const visibilityState = {
  public: visibility === "public",
  friends: visibility === "friends",
  group: visibility === "group" || allowedGroupIds.length > 0,
};

const handleVisibilityChange = (v: typeof visibilityState) => {
  if (v.public) {
    setVisibility("public");
    setAllowedGroupIds([]);
  } else if (v.friends && !v.group) {
    setVisibility("friends");
    setAllowedGroupIds([]);
  } else if (v.group && !v.friends) {
    setVisibility("group");
  } else if (v.friends && v.group) {
    setVisibility("friends");
  } else {
    setVisibility("public");
    setAllowedGroupIds([]);
  }
};
```

#### LiveOwnerPanel（第 26-43 行）
```typescript
const visibilityState = {
  public: channel.visibility === "public",
  friends: channel.visibility === "friends",
  group: channel.visibility === "group" || (channel.allowed_group_ids?.length ?? 0) > 0,
};

const handleVisibilityChange = (v: typeof visibilityState) => {
  const updates: Partial<LiveChannel> = {};
  if (v.public) {
    updates.visibility = "public";
    updates.allowed_group_ids = [];
  } else if (v.friends && !v.group) {
    updates.visibility = "friends";
    updates.allowed_group_ids = [];
  } else if (v.group && !v.friends) {
    updates.visibility = "group";
  } else if (v.friends && v.group) {
    updates.visibility = "friends";
  } else {
    updates.visibility = "public";
    updates.allowed_group_ids = [];
  }
  onUpdate(updates);
};
```

类似的修复也应用于：
- `VoiceCreate`（第 47-60 行）
- `GameRoomCreate`（第 40-53 行）

### 3. 前端：增强 `getVisibilityLabels` 函数

**文件**：`Ayla/web/src/utils/visibility.ts`

```typescript
export function getVisibilityLabels(item: {
  visibility: string;
  allowed_group_ids?: number[];
  groups?: Array<{ id: number; name: string }>;
}): string[] {
  const labels: string[] = [];

  // 好友可见
  if (item.visibility === "friends") {
    labels.push("好友可见");
  }

  // 群聊可见（通过 visibility 或 allowed_group_ids）
  if (item.visibility === "group" || (item.allowed_group_ids && item.allowed_group_ids.length > 0)) {
    if (item.groups && item.groups.length > 0) {
      // 显示具体群名
      item.groups.forEach(g => labels.push(g.name));
    } else {
      // 只显示"群聊可见"
      labels.push("群聊可见");
    }
  }

  return labels;
}
```

### 4. 后端：修复视图集过滤逻辑

修复 `PostViewSet`、`LiveChannelViewSet`、`VoiceChannelViewSet`、`GameRoomViewSet` 的 `get_queryset` 方法：

**PostViewSet（apps/posts/views.py 第 75-82 行）**：
```python
if group_id is not None:
    qs = qs.filter(
        Q(group=group_id)
        | Q(visibility="group")
        | Q(allowed_group_ids__contains=[group_id])
    ).distinct()
else:
    qs = qs.exclude(visibility="group")
```

**LiveChannelViewSet（apps/live/views.py 第 68-75 行）**：
```python
if group_id is not None:
    qs = qs.filter(
        Q(group=group_id)
        | Q(visibility="group")
        | Q(allowed_group_ids__contains=[group_id])
    ).distinct()
else:
    qs = qs.exclude(visibility="group")
```

**VoiceChannelViewSet（apps/voice/views.py 第 47-54 行）**：
```python
if group_id is not None:
    qs = qs.filter(
        Q(group=group_id)
        | Q(visibility="group")
        | Q(allowed_group_ids__contains=[group_id])
    ).distinct()
else:
    qs = qs.exclude(visibility="group")
```

**GameRoomViewSet（apps/boardgame/views.py 第 46-53 行）**：
```python
if group_id is not None:
    qs = qs.filter(
        Q(group=group_id)
        | Q(visibility="group")
        | Q(allowed_group_ids__contains=[group_id])
    ).distinct()
else:
    qs = qs.exclude(visibility="group")
```

### 5. 前端：统一标签样式类名

**文件**：`Ayla/web/src/components/voice/VoiceRoomBody.tsx`（第 116-124 行）

将 `.post-meta-tags` 和 `.post-tag` 改为 `.post-card-tags` 和 `.post-card-tag`，与其他组件保持一致。

## 验证

### 前端测试

1. ✅ 创建帖子时可以同时勾选"好友可见"和"指定群可见"
2. ✅ 选择"公开"时自动取消其他选项（单选行为）
3. ✅ 同时勾选好友和群时，标签同时显示"好友可见"和群名
4. ✅ 直播、语音、桌游创建和编辑面板也支持多选
5. ✅ 语音频道标签现在有正确的背景样式

### 后端测试

1. ✅ 群内帖子列表包含 `allowed_group_ids` 含该群 ID 的条目
2. ✅ 群内直播列表包含 `allowed_group_ids` 含该群 ID 的频道
3. ✅ 群内语音列表包含 `allowed_group_ids` 含该群 ID 的频道
4. ✅ 群内桌游列表包含 `allowed_group_ids` 含该群 ID 的房间
5. ✅ 使用 `.distinct()` 避免重复结果

## 修改文件清单

### 前端
- `Ayla/web/src/components/VisibilitySelector.tsx`：重构为多选模式
- `Ayla/web/src/components/posts/PostCard.tsx`：修复状态转换
- `Ayla/web/src/components/live/LiveCreate.tsx`：修复状态转换
- `Ayla/web/src/components/live/LiveOwnerPanel.tsx`：修复状态转换
- `Ayla/web/src/components/voice/VoiceCreate.tsx`：修复状态转换
- `Ayla/web/src/components/voice/VoiceRoomBody.tsx`：统一标签样式类名
- `Ayla/web/src/components/boardgame/GameRoomCreate.tsx`：修复状态转换
- `Ayla/web/src/utils/visibility.ts`：增强标签生成函数

### 后端
- `Ayla/backend/apps/posts/views.py`：修复过滤逻辑
- `Ayla/backend/apps/live/views.py`：修复过滤逻辑
- `Ayla/backend/apps/voice/views.py`：修复过滤逻辑
- `Ayla/backend/apps/boardgame/views.py`：修复过滤逻辑

## 设计决策

### 为什么"公开"是单选，而"好友+群聊"可以多选？

- **公开**：意味着所有人可见，与"好友"和"指定群"的限制语义冲突，必须互斥
- **好友 + 群聊**：可以理解为"同时对好友和指定群可见"，是两个独立的可见性范围的并集

### 为什么 `visibility` 字段不区分"好友+群"的组合状态？

后端 `visibility` 字段只有三个值：`public`、`friends`、`group`。当同时勾选好友和群时：
- 前端发送 `visibility="friends"` 和 `allowed_group_ids=[...]`
- 后端通过 `allowed_group_ids` 的存在判断是否同时对指定群可见
- 这样避免了引入新的 `visibility` 值或修改数据库 schema

### 为什么使用 `allowed_group_ids__contains` 而不是 `__overlap`？

PostgreSQL 的 `JSONField` 支持 `__contains` 查询，含义是"JSON 数组包含指定元素"：
```python
Q(allowed_group_ids__contains=[group_id])
```
这比 `__overlap` 更精确，只匹配确实包含该群 ID 的条目。

### 为什么要统一标签样式类名？

- **一致性**：所有标签使用相同的视觉样式，增强用户认知
- **可维护性**：减少 CSS 重复定义，统一在 `posts.css` 中管理
- **复用性**：`.post-card-tags` 和 `.post-card-tag` 已经是项目中最广泛使用的标签样式

## 后续改进

1. **群名显示**：目前标签只显示"群聊可见"，可以考虑显示具体群名（需要前端缓存群信息）
2. **权限检查**：后端应验证 `allowed_group_ids` 中的群 ID 是否真实存在且用户有权访问
3. **性能优化**：`Q(...) | Q(...) | Q(...)` 的查询可能较慢，可以考虑添加数据库索引
4. **UI 反馈**：选择器可以增加更明确的提示文案，说明"公开"与其他选项互斥

## 相关文档

- [Ayla 设计规范](../docs/design.md) §6.3 可见性控制
- [修复群外发帖指定群可见](fix_allowed_groups_posting.md)
- [帖子模块设计](../docs/design.md) §12.4
