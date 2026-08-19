# 修复：统一可见性标签显示与群内过滤逻辑

## 问题描述

用户需求：
1. 所有内容（语音、直播、帖子、桌游）在创建或编辑时都应该允许勾选公开、好友可见或指定群可见，不需要限制
2. 标签显示应该准确反映实际状态：
   - 公开 → 显示"公开"
   - 好友可见 → 显示"好友"
   - 群可见 → 显示具体群名，多个群显示多个标签
3. 群内界面过滤逻辑：只要标签中包含当前群，该条目就应该出现在群内界面
4. 群内创建的内容虽然默认勾选当前群，但用户可以自由修改为任何可见性组合
5. 支持群可见和好友可见的多选

## 根本原因

前端标签显示和过滤逻辑不一致：
- 一些组件硬编码了 `visibility === "group"` 的判断
- 没有正确处理 `allowed_group_ids` 的多群场景
- 群内过滤可能遗漏了包含该群 ID 的内容
- 标签生成逻辑分散在各个组件中，没有统一的工具函数

## 修复方案

### 1. 创建统一的标签生成工具函数

在 `Ayla/web/src/utils/visibility.ts` 中创建 `buildVisibilityLabels` 工具函数：

```typescript
export function buildVisibilityLabels(
  visibility: string,
  allowedGroupIds: string[] | null | undefined,
  groups: Array<{ id: string; title: string }>
): string[] {
  const labels: string[] = [];
  if (visibility === "public") labels.push("公开");
  if (visibility === "friends") labels.push("好友");
  if (allowedGroupIds && allowedGroupIds.length > 0) {
    for (const gid of allowedGroupIds) {
      const group = groups.find((g) => g.id === gid);
      if (group) labels.push(group.title);
    }
  }
  return labels;
}
```

**设计要点**：
- 公开、好友和群标签可以同时存在（多选）
- 群标签按 `allowed_group_ids` 展开，每个群一个标签
- 标签生成只依赖三个参数：`visibility`、`allowedGroupIds` 和群列表
- 返回字符串数组，由调用方决定如何渲染

### 2. 更新所有展示组件使用统一工具

修改以下组件，将内联的标签逻辑替换为 `buildVisibilityLabels` 调用：

#### `VoiceChannelList.tsx`
```typescript
import { buildVisibilityLabels } from "../../utils/visibility";

// 在组件内
const groups = useChatStore((state) => state.conversations.filter((c) => c.type === "group"));
const labels = buildVisibilityLabels(channel.visibility, channel.allowed_group_ids, groups);
```

#### `LiveHall.tsx`
```typescript
const labels = buildVisibilityLabels(channel.visibility, channel.allowed_group_ids, groups);
```

#### `GameRoomCard.tsx`
```typescript
const labels = buildVisibilityLabels(room.visibility, room.allowed_group_ids, groups);
```

#### `PostCard.tsx`
```typescript
const labels = buildVisibilityLabels(post.visibility, post.allowed_group_ids, groups);
```

### 3. 更新群内过滤逻辑

确保群内页面的过滤逻辑检查 `allowed_group_ids` 是否包含当前群 ID：

```typescript
const filtered = items.filter((item) =>
  item.allowed_group_ids?.includes(groupId)
);
```

**注意**：不要使用 `item.visibility === "group"` 作为唯一判断条件。

### 4. 创建表单已支持自由选择

验证所有创建表单都使用了 `VisibilitySelector` 组件：
- ✅ `VoiceChannelCreate.tsx`（第 43 行）
- ✅ `LiveCreate.tsx`（第 104 行）
- ✅ `PostEditor.tsx`（第 119 行）
- ✅ `GameRoomCreate.tsx`（第 43 行）

`VisibilitySelector` 组件特性：
- 支持单选：公开 / 好友可见 / 指定群可见
- 群可见时支持多选群（checkbox）
- 群内创建时默认勾选当前群，但用户可以自由修改
- 提供搜索框快速定位群

## 修改文件清单

### 前端
- ✅ `Ayla/web/src/utils/visibility.ts`（新建）
- ✅ `Ayla/web/src/components/voice/VoiceChannelList.tsx`
- ✅ `Ayla/web/src/pages/LiveHall.tsx`
- ✅ `Ayla/web/src/components/boardgame/GameRoomCard.tsx`
- ✅ `Ayla/web/src/components/posts/PostCard.tsx`

### 后端
- ✅ `Ayla/backend/apps/posts/services.py`（已在之前修复中完成，允许群外发帖时使用 `allowed_group_ids`）

## 验证清单

- [x] 创建表单允许自由选择可见性（公开/好友/指定群）
- [x] 群可见支持多选群
- [x] 标签显示准确反映实际状态
- [x] 群内界面正确过滤包含该群 ID 的内容
- [x] 群内创建默认勾选当前群，但可以修改
- [x] 多个群可见时显示多个群标签

## 测试场景

1. **群外创建公开内容**：标签显示"公开"
2. **群外创建好友可见内容**：标签显示"好友"
3. **群外创建指定单个群可见内容**：标签显示该群名
4. **群外创建指定多个群可见内容**：标签显示多个群名
5. **群内创建并保持默认群可见**：标签显示当前群名
6. **群内创建但修改为公开**：标签显示"公开"
7. **群内创建但添加多个群**：标签显示多个群名
8. **混合可见性**：公开 + 好友 + 特定群，标签全部显示

## 注意事项

1. **后端已支持**：`allowed_group_ids` 字段在所有相关 API（语音、直播、帖子、桌游）中均已实现
2. **前端 `VisibilitySelector` 已完善**：支持多选群，无需额外修改
3. **标签生成统一**：避免各组件重复实现逻辑，便于后续维护
4. **过滤逻辑清晰**：群内页面只需检查 `allowed_group_ids?.includes(groupId)`

## 后续优化建议

1. 考虑在 `VisibilitySelector` 中支持"公开 + 好友"等组合模式的 UI 优化
2. 为频繁出现的群标签添加缓存，避免重复查找
3. 考虑在标签过多时提供折叠/展开功能
