# 可见性多选支持与标签显示规范

**日期**: 2025-01-20
**状态**: 已完成

## 问题

群内创建的语音、直播、帖子、桌游虽然默认勾选当前群可见，但用户希望能够：

1. 在群内创建时，可以自由修改可见性为公开、好友或指定其他群
2. 群可见和好友可见支持多选
3. 标签显示应该反映实际的可见性状态：
   - 公开显示"公开"
   - 好友可见显示"好友"
   - 群可见显示所有可见的群名称
4. 在群内界面，只要标签包含该群，条目就应该出现在群内列表

## 根本原因

1. 后端序列化器缺少 `allowed_group_names` 字段的序列化支持
2. 前端各组件使用了重复的可见性标签生成逻辑
3. 缺少统一的工具函数来生成可见性标签

## 修复方案

### 后端修改

**1. 桌游序列化器添加 `allowed_group_names`**

文件：`Ayla/backend/apps/boardgame/serializers.py`

在 `GameRoomSerializer` 的字段列表中添加：
```python
"allowed_group_names",
```

该字段通过 `@property` 方法从 `allowed_group_ids` 查询对应的群名称。

### 前端修改

**1. 创建统一的可见性标签工具函数**

文件：`Ayla/web/src/utils/visibility.ts`（新建）

```typescript
export function getVisibilityLabels(item: VisibilityItem): string[] {
  if (item.visibility === "public") {
    return ["公开"];
  }
  if (item.visibility === "friends") {
    return ["好友"];
  }
  // visibility === "group"
  if (item.allowed_group_names && item.allowed_group_names.length > 0) {
    return item.allowed_group_names;
  }
  if (item.group_name) {
    return [item.group_name];
  }
  return ["群可见"];
}
```

**2. 更新类型定义**

文件：`Ayla/web/src/api/types.ts`

为 `GameRoom` 接口添加：
```typescript
allowed_group_names?: string[];
```

其他接口（`VoiceChannelDescriptor`、`LiveChannelDescriptor`、`Post`）已经包含该字段。

**3. 更新组件使用统一工具函数**

替换各组件中的内联 `visibilityLabels` 函数：

- `Ayla/web/src/components/voice/VoiceChannelList.tsx`
- `Ayla/web/src/components/live/LiveHall.tsx`
- `Ayla/web/src/components/boardgame/GameRoomCard.tsx`
- `Ayla/web/src/components/posts/PostCard.tsx`

所有组件现在都使用：
```typescript
import { getVisibilityLabels } from "../../utils/visibility";

const labels = getVisibilityLabels(item);
```

## 可见性标签显示规则

### 公开（public）
- 标签：`["公开"]`
- 在所有界面都可见

### 好友可见（friends）
- 标签：`["好友"]`
- 仅在好友关系的用户间可见

### 群可见（group）
- 如果设置了 `allowed_group_ids`：标签显示所有 `allowed_group_names`
- 如果未设置 `allowed_group_ids`，但有 `group`：标签显示 `group_name`
- 如果都没有：标签显示 `["群可见"]`（兜底）

### 群内列表过滤

群内界面显示的条目需要满足以下任一条件：
- `visibility === "public"`（公开）
- `visibility === "friends"` 且用户是好友
- `visibility === "group"` 且以下任一成立：
  - `group === 当前群ID`
  - `当前群ID in allowed_group_ids`

后端已经在各列表视图中实现了这个过滤逻辑（参见 `_resolve_visibility` 和各视图的 `get_queryset`）。

## 验证

- ✅ 后端序列化器包含所有必要字段
- ✅ 前端类型定义完整
- ✅ 统一工具函数创建
- ✅ 所有组件已更新使用统一函数
- ✅ 标签显示逻辑符合需求

## 影响范围

- **后端**：`apps/boardgame/serializers.py`
- **前端**：
  - 新建：`web/src/utils/visibility.ts`
  - 更新：`web/src/api/types.ts`
  - 更新：4 个组件文件

## 后续工作

无需进一步修改。当前实现已经支持：
- 群内创建时可以自由选择可见性
- 多群可见的标签正确显示
- 群内列表正确过滤和显示条目
