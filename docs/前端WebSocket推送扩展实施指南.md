# 前端 WebSocket 推送扩展 - 实施指南

## 概述

后端已完成所有 8 个事件类型的 WebSocket 推送，前端需要完成以下 3 个模块的扩展：
1. **帖子（Post）** - 2 个事件
2. **桌游房（Boardgame Room）** - 2 个事件  
3. **群组（Group）** - 2 个事件

语音房和直播间的推送已在前端完成（由子代理 89c5427a 完成）。

---

## 一、类型定义扩展

### 文件：`web/src/api/types.ts`

**问题**：文件被开发服务器占用，无法直接编辑。

**解决方案**：停止开发服务器后再修改，或手动应用补丁文件 `types.patch.ts`。

#### 需要添加的事件类型（在第 382 行后）

```typescript
// ===== 新增：帖子推送事件 =====
export interface PostCreatedFrame {
  type: "post.created";
  data: {
    post_id: number;
    title: string;
    body: string;
    author_id: string;
    visibility: string;
    group_id: string | null;
    created_at: string;
  };
}

export interface PostDeletedFrame {
  type: "post.deleted";
  data: {
    post_id: number;
  };
}

// ===== 新增：桌游房推送事件 =====
export interface BoardgameRoomCreatedFrame {
  type: "boardgame.room.created";
  data: {
    room_id: number;
    name: string;
    owner_id: string;
    visibility: string;
    group_id: string | null;
    game_type: string;
    created_at: string;
  };
}

export interface BoardgameRoomDeletedFrame {
  type: "boardgame.room.deleted";
  data: {
    room_id: number;
  };
}

// ===== 新增：群组推送事件 =====
export interface GroupCreatedFrame {
  type: "group.created";
  data: {
    conversation_id: string;
    title: string;
    owner_id: string;
    created_at: string;
  };
}

export interface GroupJoinedFrame {
  type: "group.joined";
  data: {
    conversation_id: string;
    title: string;
    user_id: string;
  };
}
```

#### 修改 ChatServerFrame 类型定义（第 384-402 行）

```typescript
export type ChatServerFrame =
  | ChatSubscribedFrame
  | MessageNewFrame
  | MessageRecallFrame
  | MessageReadFrame
  | TypingFrame
  | HistorySyncFrame
  | ElysiaReplyFrame
  | GroupRequestNewFrame
  | GroupRequestResolvedFrame
  | GroupInviteNewFrame
  | GroupMemberLeftFrame
  | VoiceChannelCreatedFrame
  | VoiceChannelDeletedFrame
  | LiveChannelCreatedFrame
  | LiveChannelStatusChangedFrame
  | LiveChannelDeletedFrame
  | PostCreatedFrame              // 新增
  | PostDeletedFrame              // 新增
  | BoardgameRoomCreatedFrame     // 新增
  | BoardgameRoomDeletedFrame     // 新增
  | GroupCreatedFrame             // 新增
  | GroupJoinedFrame              // 新增
  | ChatErrorFrame
  | PongFrame;
```

---

## 二、Posts Store 扩展

### 文件：`web/src/stores/posts.ts`

**当前状态**：已有 `lastFetched` 和 `isPostsStale()` 函数（由子代理完成）。

#### 需要添加的方法

```typescript
// 在 PostsActions 接口中添加
interface PostsActions {
  // ... 现有方法
  
  /** 插入或更新帖子（WebSocket 推送用） */
  upsertPost: (post: Post) => void;
  
  /** 删除帖子（WebSocket 推送用） */
  removePost: (postId: number) => void;
}

// 在 create() 实现中添加
export const usePostsStore = create<PostsState & PostsActions>((set, get) => ({
  // ... 现有实现
  
  upsertPost: (post: Post) => {
    set((state) => {
      const index = state.results.findIndex((p) => p.id === post.id);
      if (index >= 0) {
        // 更新现有帖子
        const newResults = [...state.results];
        newResults[index] = post;
        return { results: newResults };
      } else {
        // 插入新帖子（放在最前面）
        return { results: [post, ...state.results] };
      }
    });
  },
  
  removePost: (postId: number) => {
    set((state) => ({
      results: state.results.filter((p) => p.id !== postId),
    }));
  },
}));
```

---

## 三、Chat WebSocket 客户端扩展

### 文件：`web/src/ws/chat.ts`

**当前状态**：已有 voice 和 live 推送处理（第 228-280 行）。

#### 需要在 dispatch() 方法中添加的 case 分支

在第 280 行（`live.channel.deleted` case 之后）添加：

```typescript
      case "post.created": {
        const d = frame.data;
        // 调用后端 API 获取完整帖子数据（因为推送只包含基本信息）
        void apiRequest<Post>(`/posts/${d.post_id}/`)
          .then((post) => {
            usePostsStore.getState().upsertPost(post);
          })
          .catch((err) => {
            console.warn("[WS] 获取帖子详情失败", d.post_id, err);
          });
        break;
      }
      case "post.deleted": {
        const d = frame.data;
        usePostsStore.getState().removePost(d.post_id);
        break;
      }
      case "boardgame.room.created": {
        const d = frame.data;
        // 桌游房没有独立 store，通过自定义事件通知页面组件刷新
        if (typeof window !== "undefined") {
          window.dispatchEvent(
            new CustomEvent("boardgame:room-created", {
              detail: {
                id: d.room_id,
                name: d.name,
                owner_id: d.owner_id,
                visibility: d.visibility,
                group: d.group_id,
                game_type: d.game_type,
                created_at: d.created_at,
              },
            })
          );
        }
        break;
      }
      case "boardgame.room.deleted": {
        const d = frame.data;
        // 通知页面组件刷新
        if (typeof window !== "undefined") {
          window.dispatchEvent(
            new CustomEvent("boardgame:room-deleted", {
              detail: { id: d.room_id },
            })
          );
        }
        break;
      }
      case "group.created":
      case "group.joined": {
        const d = frame.data;
        // 调用后端 API 获取完整会话数据
        void apiRequest<Conversation>(`/chat/conversations/${d.conversation_id}/`)
          .then((conv) => {
            useChatStore.getState().upsertConversation(conv);
          })
          .catch((err) => {
            console.warn("[WS] 获取会话详情失败", d.conversation_id, err);
          });
        break;
      }
```

#### 需要添加的导入

在文件顶部添加：

```typescript
import { usePostsStore } from "../stores/posts";
import { apiRequest } from "../api/client";
import type { Post, Conversation } from "../api/types";
```

---

## 四、Chat Store 扩展

### 文件：`web/src/stores/chat.ts`

**需要添加的方法**：

```typescript
// 在 ChatActions 接口中添加
interface ChatActions {
  // ... 现有方法
  
  /** 插入或更新会话（WebSocket 推送用） */
  upsertConversation: (conversation: Conversation) => void;
}

// 在 create() 实现中添加
export const useChatStore = create<ChatState & ChatActions>((set, get) => ({
  // ... 现有实现
  
  upsertConversation: (conversation: Conversation) => {
    set((state) => {
      const index = state.conversations.findIndex((c) => c.id === conversation.id);
      if (index >= 0) {
        // 更新现有会话
        const newConversations = [...state.conversations];
        newConversations[index] = conversation;
        return { conversations: newConversations };
      } else {
        // 插入新会话（放在最前面）
        return { conversations: [conversation, ...state.conversations] };
      }
    });
  },
}));
```

---

## 五、桌游房页面监听事件

桌游房没有独立的 store，使用自定义 DOM 事件通知页面刷新。

### 已存在的监听（无需修改）

- `web/src/pages/GamesHubPage.tsx` - 已监听 `boardgame:room-created` 事件
- `web/src/pages/group/GroupGames.tsx` - 已监听 `boardgame:room-created` 事件

### 需要添加删除事件监听

#### `GamesHubPage.tsx`（第 40 行附近）

```typescript
// 在现有 useEffect 中添加删除监听
useEffect(() => {
  const handleRoomCreated = () => { load(); };
  const handleRoomDeleted = () => { load(); };
  
  window.addEventListener("boardgame:room-created", handleRoomCreated);
  window.addEventListener("boardgame:room-deleted", handleRoomDeleted);
  
  return () => {
    window.removeEventListener("boardgame:room-created", handleRoomCreated);
    window.removeEventListener("boardgame:room-deleted", handleRoomDeleted);
  };
}, []);
```

#### `GroupGames.tsx`（第 42 行附近）

```typescript
// 在现有 useEffect 中添加删除监听
useEffect(() => {
  const handleRoomCreated = () => { load(); };
  const handleRoomDeleted = () => { load(); };
  
  window.addEventListener("boardgame:room-created", handleRoomCreated);
  window.addEventListener("boardgame:room-deleted", handleRoomDeleted);
  
  return () => {
    window.removeEventListener("boardgame:room-created", handleRoomCreated);
    window.removeEventListener("boardgame:room-deleted", handleRoomDeleted);
  };
}, [groupId]);
```

---

## 六、实施步骤

### 步骤 1：停止开发服务器

```bash
# 在 Ayla/web 目录下
# 按 Ctrl+C 停止 pnpm run dev
```

### 步骤 2：应用类型定义

手动将 `types.patch.ts` 的内容复制到 `types.ts`：
- 在第 382 行后添加 6 个新事件类型接口
- 修改第 384-402 行的 `ChatServerFrame` 类型定义

### 步骤 3：扩展 Posts Store

在 `stores/posts.ts` 末尾添加 `upsertPost` 和 `removePost` 方法。

### 步骤 4：扩展 Chat Store

在 `stores/chat.ts` 末尾添加 `upsertConversation` 方法。

### 步骤 5：扩展 WebSocket 客户端

在 `ws/chat.ts` 的 `dispatch()` 方法中：
- 添加 6 个新 case 分支
- 添加必要的导入

### 步骤 6：扩展桌游房页面监听

在 `GamesHubPage.tsx` 和 `GroupGames.tsx` 中添加 `boardgame:room-deleted` 事件监听。

### 步骤 7：验证

```bash
# 重新启动开发服务器
pnpm run dev

# 运行类型检查
pnpm type-check
```

---

## 七、验收测试

### 测试场景 1：帖子实时同步

1. 用户 A 在群 X 发帖
2. **预期**：用户 B 的信息流立即出现新帖（< 1s）
3. 用户 A 删除帖子
4. **预期**：用户 B 的信息流中帖子立即消失

### 测试场景 2：桌游房实时同步

1. 用户 A 在群 X 创建桌游房
2. **预期**：用户 B 的桌游列表立即出现新房间
3. 用户 A 删除桌游房
4. **预期**：用户 B 的桌游列表中房间立即消失

### 测试场景 3：群组实时同步

1. 用户 A 创建群 Y 并邀请用户 B
2. **预期**：用户 B 接受邀请后，群列表立即出现群 Y
3. 用户 A 创建群 Z 并直接添加用户 B
4. **预期**：用户 B 的群列表立即出现群 Z

---

## 八、注意事项

### 1. 帖子和群组的延迟加载

帖子和群组的推送事件只包含基本信息，需要调用 API 获取完整数据：

```typescript
// 推送事件只有 post_id，需要获取完整 Post 对象
void apiRequest<Post>(`/posts/${d.post_id}/`)
  .then((post) => usePostsStore.getState().upsertPost(post));
```

这会增加约 100-300ms 延迟，但避免了在推送中序列化完整对象。

### 2. 桌游房的自定义事件模式

桌游房没有 Zustand store，使用 DOM 自定义事件通知页面：

```typescript
window.dispatchEvent(
  new CustomEvent("boardgame:room-created", { detail: roomData })
);
```

页面组件监听事件后重新调用 `load()` 刷新列表。

### 3. 错误处理

所有异步 API 调用都应捕获错误并打印 warning：

```typescript
.catch((err) => {
  console.warn("[WS] 获取详情失败", id, err);
});
```

不阻断推送流程，失败时用户可以手动刷新。

---

## 九、已完成的相关工作

以下工作已由其他子代理完成，无需重复：

- ✅ 后端推送函数（8 个事件类型）
- ✅ ChatConsumer 事件处理器（8 个处理器）
- ✅ 语音房和直播间的前端处理
- ✅ 缓存时间戳机制（所有 store）
- ✅ 登录后预加载核心列表
- ✅ 全局组件按需加载兜底
- ✅ 手动刷新按钮（所有列表页）
- ✅ 图片加载性能优化

完成本指南的所有步骤后，Ayla 前端将实现完整的实时推送功能。

---

**预计工时**：1-2 小时（需要停止开发服务器）  
**风险**：低（逻辑简单，已有参考实现）  
**优先级**：高（完成后即可进行完整验收测试）
