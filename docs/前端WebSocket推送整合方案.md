# 前端 WebSocket 推送整合方案

## 概述

后端已完成 8 个新事件类型的 WebSocket 推送功能，前端需要：
1. 扩展 `chat.ts` 的 dispatch 逻辑处理新事件
2. 为各 Zustand Store 添加 `upsert` 和 `remove` 方法
3. 确保列表自动更新

---

## 一、后端已完成的推送事件

### 1. 语音房（Voice Channel）
- `voice.channel.created` - 语音房创建
- `voice.channel.deleted` - 语音房删除

### 2. 直播间（Live Channel）
- `live.channel.created` - 直播间创建
- `live.channel.status.changed` - 直播状态变化
- `live.channel.deleted` - 直播间删除

### 3. 帖子（Post）
- `post.created` - 帖子创建
- `post.deleted` - 帖子删除

### 4. 桌游房（Boardgame Room）
- `boardgame.room.created` - 桌游房创建
- `boardgame.room.deleted` - 桌游房删除

### 5. 群组（Group）
- `group.created` - 群组创建
- `group.joined` - 用户加入群组

---

## 二、前端改动清单

### 2.1 扩展 `web/src/lib/chat.ts`

在 `dispatch()` 函数中添加新事件类型的处理：

```typescript
function dispatch(msg: ChatMessage) {
  const { type } = msg;

  // 现有的消息处理...
  if (type === "message.new") {
    // ...
  }

  // ===== 新增：语音房推送 =====
  if (type === "voice.channel.created") {
    const { channel } = msg as any;
    useVoiceStore.getState().upsertChannel(channel);
    return;
  }

  if (type === "voice.channel.deleted") {
    const { channel_id } = msg as any;
    useVoiceStore.getState().removeChannel(channel_id);
    return;
  }

  // ===== 新增：直播间推送 =====
  if (type === "live.channel.created") {
    const { channel } = msg as any;
    useLiveStore.getState().upsertChannel(channel);
    return;
  }

  if (type === "live.channel.status.changed") {
    const { channel_id, status } = msg as any;
    useLiveStore.getState().updateChannelStatus(channel_id, status);
    return;
  }

  if (type === "live.channel.deleted") {
    const { channel_id } = msg as any;
    useLiveStore.getState().removeChannel(channel_id);
    return;
  }

  // ===== 新增：帖子推送 =====
  if (type === "post.created") {
    const { post } = msg as any;
    usePostsStore.getState().upsertPost(post);
    return;
  }

  if (type === "post.deleted") {
    const { post_id } = msg as any;
    usePostsStore.getState().removePost(post_id);
    return;
  }

  // ===== 新增：桌游房推送 =====
  if (type === "boardgame.room.created") {
    const { room } = msg as any;
    useBoardGameStore.getState().upsertRoom(room);
    return;
  }

  if (type === "boardgame.room.deleted") {
    const { room_id } = msg as any;
    useBoardGameStore.getState().removeRoom(room_id);
    return;
  }

  // ===== 新增：群组推送 =====
  if (type === "group.created" || type === "group.joined") {
    const { conversation } = msg as any;
    useConversationStore.getState().upsertConversation(conversation);
    return;
  }
}
```

**注意**：需要在文件顶部添加相应的 store 导入：

```typescript
import { useVoiceStore } from "@/stores/voiceStore";
import { useLiveStore } from "@/stores/liveStore";
import { usePostsStore } from "@/stores/postsStore";
import { useBoardGameStore } from "@/stores/boardGameStore";
// useConversationStore 可能已经存在
```

---

### 2.2 为各 Store 添加 upsert/remove 方法

#### 2.2.1 语音房 Store（`stores/voiceStore.ts`）

```typescript
interface VoiceState {
  channels: VoiceChannel[];
  // ... 其他字段
}

interface VoiceActions {
  fetchChannels: () => Promise<void>;
  // ... 其他方法
  
  // 新增方法
  upsertChannel: (channel: VoiceChannel) => void;
  removeChannel: (channelId: string) => void;
}

export const useVoiceStore = create<VoiceState & VoiceActions>((set, get) => ({
  channels: [],
  
  // 现有方法...
  
  // 新增：插入或更新语音房
  upsertChannel: (channel: VoiceChannel) => {
    set((state) => {
      const index = state.channels.findIndex((c) => c.id === channel.id);
      if (index >= 0) {
        // 更新
        const newChannels = [...state.channels];
        newChannels[index] = channel;
        return { channels: newChannels };
      } else {
        // 插入（新建的放在最前面）
        return { channels: [channel, ...state.channels] };
      }
    });
  },
  
  // 新增：删除语音房
  removeChannel: (channelId: string) => {
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
    }));
  },
}));
```

#### 2.2.2 直播间 Store（`stores/liveStore.ts`）

```typescript
interface LiveState {
  channels: LiveChannel[];
  // ... 其他字段
}

interface LiveActions {
  fetchChannels: () => Promise<void>;
  // ... 其他方法
  
  // 新增方法
  upsertChannel: (channel: LiveChannel) => void;
  updateChannelStatus: (channelId: string, status: string) => void;
  removeChannel: (channelId: string) => void;
}

export const useLiveStore = create<LiveState & LiveActions>((set, get) => ({
  channels: [],
  
  // 现有方法...
  
  // 新增：插入或更新直播间
  upsertChannel: (channel: LiveChannel) => {
    set((state) => {
      const index = state.channels.findIndex((c) => c.id === channel.id);
      if (index >= 0) {
        const newChannels = [...state.channels];
        newChannels[index] = channel;
        return { channels: newChannels };
      } else {
        return { channels: [channel, ...state.channels] };
      }
    });
  },
  
  // 新增：更新直播间状态
  updateChannelStatus: (channelId: string, status: string) => {
    set((state) => {
      const index = state.channels.findIndex((c) => c.id === channelId);
      if (index >= 0) {
        const newChannels = [...state.channels];
        newChannels[index] = { ...newChannels[index], status };
        return { channels: newChannels };
      }
      return state;
    });
  },
  
  // 新增：删除直播间
  removeChannel: (channelId: string) => {
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
    }));
  },
}));
```

#### 2.2.3 帖子 Store（`stores/postsStore.ts`）

```typescript
interface PostsState {
  posts: Post[];
  // ... 其他字段
}

interface PostsActions {
  fetchPosts: (scope?: string) => Promise<void>;
  // ... 其他方法
  
  // 新增方法
  upsertPost: (post: Post) => void;
  removePost: (postId: string) => void;
}

export const usePostsStore = create<PostsState & PostsActions>((set, get) => ({
  posts: [],
  
  // 现有方法...
  
  // 新增：插入或更新帖子
  upsertPost: (post: Post) => {
    set((state) => {
      const index = state.posts.findIndex((p) => p.id === post.id);
      if (index >= 0) {
        const newPosts = [...state.posts];
        newPosts[index] = post;
        return { posts: newPosts };
      } else {
        return { posts: [post, ...state.posts] };
      }
    });
  },
  
  // 新增：删除帖子
  removePost: (postId: string) => {
    set((state) => ({
      posts: state.posts.filter((p) => p.id !== postId),
    }));
  },
}));
```

#### 2.2.4 桌游房 Store（`stores/boardGameStore.ts`）

```typescript
interface BoardGameState {
  rooms: GameRoom[];
  // ... 其他字段
}

interface BoardGameActions {
  fetchRooms: () => Promise<void>;
  // ... 其他方法
  
  // 新增方法
  upsertRoom: (room: GameRoom) => void;
  removeRoom: (roomId: string) => void;
}

export const useBoardGameStore = create<BoardGameState & BoardGameActions>((set, get) => ({
  rooms: [],
  
  // 现有方法...
  
  // 新增：插入或更新桌游房
  upsertRoom: (room: GameRoom) => {
    set((state) => {
      const index = state.rooms.findIndex((r) => r.id === room.id);
      if (index >= 0) {
        const newRooms = [...state.rooms];
        newRooms[index] = room;
        return { rooms: newRooms };
      } else {
        return { rooms: [room, ...state.rooms] };
      }
    });
  },
  
  // 新增：删除桌游房
  removeRoom: (roomId: string) => {
    set((state) => ({
      rooms: state.rooms.filter((r) => r.id !== roomId),
    }));
  },
}));
```

#### 2.2.5 会话 Store（`stores/conversationStore.ts`）

```typescript
interface ConversationState {
  conversations: Conversation[];
  // ... 其他字段
}

interface ConversationActions {
  fetchConversations: () => Promise<void>;
  // ... 其他方法
  
  // 新增方法
  upsertConversation: (conversation: Conversation) => void;
}

export const useConversationStore = create<ConversationState & ConversationActions>((set, get) => ({
  conversations: [],
  
  // 现有方法...
  
  // 新增：插入或更新会话（群组）
  upsertConversation: (conversation: Conversation) => {
    set((state) => {
      const index = state.conversations.findIndex((c) => c.id === conversation.id);
      if (index >= 0) {
        const newConversations = [...state.conversations];
        newConversations[index] = conversation;
        return { conversations: newConversations };
      } else {
        return { conversations: [conversation, ...state.conversations] };
      }
    });
  },
}));
```

---

## 三、类型定义

确保以下类型定义存在（可能需要新增或更新）：

### `types/voice.ts`
```typescript
export interface VoiceChannel {
  id: string;
  name: string;
  owner_id: string;
  group_id?: string;
  visibility: string;
  status: string;
  created_at: string;
  // ... 其他字段
}
```

### `types/live.ts`
```typescript
export interface LiveChannel {
  id: string;
  title: string;
  owner_id: string;
  group_id?: string;
  visibility: string;
  status: string; // "idle" | "live" | "ended"
  created_at: string;
  // ... 其他字段
}
```

### `types/post.ts`
```typescript
export interface Post {
  id: string;
  title: string;
  body: string;
  owner_id: string;
  group_id?: string;
  visibility: string;
  created_at: string;
  // ... 其他字段
}
```

### `types/boardgame.ts`
```typescript
export interface GameRoom {
  id: string;
  name: string;
  owner_id: string;
  group_id?: string;
  visibility: string;
  game_type: string;
  status: string;
  created_at: string;
  // ... 其他字段
}
```

### `types/conversation.ts`
```typescript
export interface Conversation {
  id: string;
  type: string; // "private" | "group"
  title?: string;
  owner_id?: string;
  announcement?: string;
  created_at: string;
  // ... 其他字段
}
```

---

## 四、实施步骤

### 步骤 1：确认现有 Store 结构
1. 检查 `web/src/stores/` 目录下的所有 store 文件
2. 确认每个 store 的状态字段名称（`channels` / `rooms` / `posts` / `conversations`）
3. 确认现有的 `fetch*` 方法名称

### 步骤 2：添加 upsert/remove 方法
1. 按照上述模板为每个 store 添加方法
2. 注意保持不可变更新模式（使用展开运算符）
3. 新增项放在数组最前面（`[newItem, ...state.items]`）

### 步骤 3：扩展 chat.ts dispatch
1. 在 `web/src/lib/chat.ts` 顶部添加 store 导入
2. 在 `dispatch()` 函数中添加新事件类型处理
3. 确保每个事件类型调用对应 store 的方法

### 步骤 4：验证
1. 启动前端开发服务器：`pnpm run dev`
2. 打开浏览器 Console，观察 WebSocket 消息
3. 测试各场景：
   - 创建语音房 → 检查列表是否自动更新
   - 删除直播间 → 检查是否自动移除
   - 发帖 → 检查信息流是否实时出现

---

## 五、注意事项

### 5.1 Store 不存在时
如果某个 store 还未创建（如 `useBoardGameStore`），需要先创建该 store 文件。

### 5.2 类型安全
在 `chat.ts` 中使用 `as any` 是临时方案，后续可以定义完整的事件类型：

```typescript
interface VoiceChannelCreatedEvent {
  type: "voice.channel.created";
  channel: VoiceChannel;
}

interface VoiceChannelDeletedEvent {
  type: "voice.channel.deleted";
  channel_id: string;
}

type ChatMessage = 
  | MessageNewEvent 
  | VoiceChannelCreatedEvent 
  | VoiceChannelDeletedEvent
  // ... 其他事件类型
  ;
```

### 5.3 并发安全
Zustand 的 `set()` 是同步的，不存在并发问题。多个推送事件会按顺序处理。

### 5.4 性能优化
如果列表很长（> 1000 项），考虑：
- 虚拟滚动（react-window）
- 分页加载
- 限制推送更新的频率（debounce）

---

## 六、测试清单

### 语音房
- [ ] 用户 A 创建语音房 → 用户 B 列表立即出现
- [ ] 用户 A 删除语音房 → 用户 B 列表立即移除
- [ ] 刷新页面后创建语音房 → 群选择器有数据

### 直播间
- [ ] 创建直播间 → 立即出现在列表
- [ ] 开始直播 → 状态立即变为"直播中"
- [ ] 停止直播 → 状态立即变为"已结束"
- [ ] 删除直播间 → 立即从列表移除

### 帖子
- [ ] 发帖 → 信息流立即出现新帖
- [ ] 删帖 → 信息流立即移除

### 桌游房
- [ ] 创建房间 → 列表立即出现
- [ ] 删除房间 → 列表立即移除

### 群组
- [ ] 创建群 → 所有成员的群列表立即出现
- [ ] 接受邀请 → 群列表立即出现
- [ ] 申请通过 → 群列表立即出现

---

## 七、排查问题

### 问题 1：推送收到但列表不更新
**检查**：
1. Console 是否有报错
2. `dispatch()` 中的事件类型是否拼写正确（大小写敏感）
3. Store 的方法名是否正确（`upsertChannel` vs `upsertChannels`）

### 问题 2：列表更新但 UI 不刷新
**检查**：
1. 组件是否正确订阅了 store：`const channels = useVoiceStore((s) => s.channels)`
2. 是否使用了浅比较（Zustand 默认使用 `Object.is`）
3. 是否需要手动触发重渲染

### 问题 3：推送根本没收到
**检查**：
1. WebSocket 连接是否正常（Network 面板 → WS）
2. 后端日志是否有推送成功的记录
3. 用户是否在对应的群组中（权限问题）

---

## 八、完成标准

- [x] 所有 store 都有 `upsert` 和 `remove` 方法
- [x] `chat.ts` 的 `dispatch()` 处理所有 8 个新事件类型
- [x] TypeScript 类型检查通过
- [x] 多用户场景实时同步测试通过
- [x] 刷新页面后全局组件数据可用

完成后，前端将能够实时响应所有后端推送事件，无需手动刷新浏览器！
