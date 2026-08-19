# Ayla WebSocket 实时推送 - 完整调研与解决方案

> **调研日期**：2025-01-XX  
> **调研目标**：实现所有界面、所有操作流的真正实时更新，移除手动刷新按钮依赖

---

## 一、问题根源

### 1.1 用户反馈的核心问题

- **桌游界面等多个界面不会热更新**
- **需要手动刷新浏览器才能看到新数据**
- **前端依赖定期轮询或缓存过期检查，体验差**

### 1.2 技术根因

**后端只推送部分事件**：
- ✅ 已有推送：聊天消息（`message.new`）、消息撤回/已读、打字状态、语音频道成员状态（`voice.state`）、直播弹幕（`danmaku`）
- ❌ 缺失推送：**列表级变化**（语音房创建/删除、直播间创建/删除/状态变化、帖子创建/删除、桌游房创建/删除、群创建/加入）

**前端只能被动等待**：
- 前端 WebSocket 客户端（`chat.ts`, `voice.ts`, `live.ts`）只处理已有事件类型
- 新建的语音房、直播间、帖子、桌游房只能通过刷新页面或定时轮询才能看到
- 群列表变化（加入新群、被拉入群）也无推送

---

##二、现有 WebSocket 架构

### 2.1 前端 WebSocket 客户端

| 客户端 | 路径 | 连接目标 | 已处理事件 |
|--------|------|----------|-----------|
| **ChatWSClient** | `web/src/ws/chat.ts` | `/ws/chat/?token=<jwt>` | `message.new`, `message.recall`, `message.read`, `typing`, `elysia.reply`, `history.sync`, `group.request.new`, `group.request.resolved`, `group.invite.new`, `group.member.left` |
| **VoiceWSClient** | `web/src/ws/voice.ts` | `/ws/voice/?token=<jwt>` | `voice.state` (joined/left/muted/unmuted/heartbeat) |
| **LiveWSClient** | `web/src/ws/live.ts` | `/ws/live/{channel_id}/?token=<jwt>` | `danmaku` (弹幕) |

### 2.2 后端 WebSocket Consumer

| Consumer | 路径 | 组命名规则 | 广播方法 |
|----------|------|-----------|----------|
| **ChatConsumer** | `apps/chat/consumers.py` | `chat_conv_{conv_id}` (会话组) + `chat_user_{user_id}` (用户组) | `group_send` |
| **VoiceConsumer** | `apps/voice/consumers.py` | `voice_chan_{channel_id}` | `group_send` |
| **DanmakuConsumer** | `apps/live/consumers.py` | `live_{channel_id}` | `group_send` |

### 2.3 已有推送触发点

**聊天消息** (`apps/chat/services.py`)：
- `broadcast_message_new()` → 发送新消息后推送
- `broadcast_message_recall()` → 撤回消息后推送
- `broadcast_message_read()` → 标记已读后推送
- `broadcast_typing()` → 打字状态推送

**语音频道成员状态** (`apps/voice/services.py`)：
- `broadcast_voice_state()` → 加入/离开/静音/取消静音/心跳时推送

**直播弹幕** (`apps/live/services.py`)：
- `broadcast_danmaku()` → 发送弹幕后推送

**群申请/邀请** (`apps/chat/services.py`)：
- `notify_group_request_new()` → 新入群申请推给管理员
- `notify_group_request_resolved()` → 申请处理结果推给申请人
- `notify_group_invite_new()` → 新邀请推给被邀请人
- `notify_member_left()` → 成员离开推给群成员

---

##三、缺失的推送事件（关键发现）

### 3.1 语音房列表推送（❌ 缺失）

**场景**：
- 用户 A 创建语音房 → 用户 B 的语音大厅列表不会自动更新
- 用户 A 删除语音房 → 用户 B 看到的列表仍显示已删除的房间

**需要的推送事件**：
```typescript
// 前端应接收的事件
{
  type: "voice.channel.created",
  data: {
    channel_id: string,
    name: string,
    owner_id: string,
    visibility: "public" | "group",
    group_id: string | null,
    created_at: string
  }
}

{
  type: "voice.channel.deleted",
  data: {
    channel_id: string
  }
}
```

**后端需要添加的广播**：
- `apps/voice/views.py` → `ChannelListView.post()` 创建后广播
- `apps/voice/views.py` → `ChannelDeleteView.delete()` 删除后广播

### 3.2 直播间列表推送（❌ 缺失）

**场景**：
- 用户 A 创建直播间 → 用户 B 的直播大厅列表不会自动更新
- 用户 A 开始/停止直播 → 用户 B 看到的状态仍是旧的
- 用户 A 删除直播间 → 用户 B 看到的列表仍显示已删除的房间

**需要的推送事件**：
```typescript
{
  type: "live.channel.created",
  data: {
    channel_id: number,
    name: string,
    owner_id: string,
    visibility: "public" | "group",
    group_id: string | null,
    status: "idle",
    created_at: string
  }
}

{
  type: "live.channel.status.changed",
  data: {
    channel_id: number,
    status: "live" | "idle",
    changed_at: string
  }
}

{
  type: "live.channel.deleted",
  data: {
    channel_id: number
  }
}
```

**后端需要添加的广播**：
- `apps/live/views.py` → `ChannelListView.post()` 创建后广播
- `apps/live/views.py` → `ChannelStartView.post()` 开始直播后广播状态变化
- `apps/live/views.py` → `ChannelStopView.post()` 停止直播后广播状态变化
- （删除接口待查，可能需要添加）

### 3.3 帖子列表推送（❌ 缺失）

**场景**：
- 用户 A 发帖 → 用户 B 的帖子信息流不会自动更新
- 用户 A 删除帖子 → 用户 B 的列表仍显示已删除的帖子

**需要的推送事件**：
```typescript
{
  type: "post.created",
  data: {
    post_id: string,
    author_id: string,
    title: string,
    visibility: "public" | "group",
    group_id: string | null,
    created_at: string
  }
}

{
  type: "post.deleted",
  data: {
    post_id: string
  }
}
```

**后端需要添加的广播**：
- `apps/posts/views.py` → `PostListView.post()` 创建后广播
- `apps/posts/views.py` → `PostDetailView.delete()` 删除后广播

### 3.4 桌游房列表推送（❌ 缺失）

**场景**：
- 用户 A 创建桌游房 → 用户 B 的桌游大厅列表不会自动更新
- 用户 A 删除桌游房 → 用户 B 看到的列表仍显示已删除的房间

**需要的推送事件**：
```typescript
{
  type: "boardgame.room.created",
  data: {
    room_id: number,
    name: string,
    owner_id: string,
    game_type: string | null,
    visibility: "public" | "group",
    group_id: string | null,
    created_at: string
  }
}

{
  type: "boardgame.room.deleted",
  data: {
    room_id: number
  }
}
```

**后端需要添加的广播**：
- `apps/boardgame/views.py` → `RoomListView.post()` 创建后广播
- （删除接口待查，可能需要添加）

### 3.5 群列表推送（✅ 部分已有，❌ 缺失新建群）

**已有推送**（通过 `chat_user_{user_id}` 组）：
- ✅ `group.invite.new` - 收到入群邀请
- ✅ `group.request.resolved` - 入群申请被处理

**缺失推送**：
- ❌ **新建群聊** → 创建者的其他设备不知道新群
- ❌ **加入群成功** → 需要刷新才能在列表看到新群

**需要的推送事件**：
```typescript
{
  type: "group.created",
  data: {
    conversation_id: string,
    name: string,
    owner_id: string,
    created_at: string
  }
}

{
  type: "group.joined",
  data: {
    conversation_id: string,
    name: string,
    joined_at: string
  }
}
```

**后端需要添加的广播**：
- `apps/chat/views.py` → `GroupCreateView.post()` 创建后推给创建者
- `apps/chat/views.py` → `GroupJoinRequestActionView.post()` 通过申请后推给新成员
- `apps/chat/views.py` → `GroupInviteActionView.post()` 接受邀请后推给新成员

---

## 四、推荐解决方案

### 4.1 架构设计

**扩展现有 ChatWS 作为全局推送通道**：
- 原因：`ChatWSClient` 已经是全局单例连接，生命周期覆盖整个登录会话
- 不需要为每个列表单独建立 WebSocket 连接
- 复用现有的 `chat_user_{user_id}` 用户级推送组

**推送目标判断规则**：
1. **公开可见**（`visibility=public`）→ 推给所有在线用户（暂不实现全员广播，改用前端轮询兜底）
2. **指定群可见**（`visibility=group`）→ 推给该群的所有成员
3. **创建者操作**（如新建群） → 推给创建者本人的所有设备

### 4.2 后端实现步骤

#### 步骤 1：添加推送服务函数（`apps/chat/services.py` 等）

```python
# apps/chat/services.py 扩展

async def notify_group_created(conversation_id, owner):
    """新建群聊推给创建者（所有设备）"""
    await _user_group_send_async(
        owner.id,
        {
            "type": "group.created",
            "conversation_id": str(conversation_id),
            "name": conversation.name,
            "owner_id": str(owner.id),
            "created_at": conversation.created_at.isoformat(),
        },
    )

def notify_group_created_sync(conversation_id, owner):
    """同步版（同步视图使用）"""
    _user_group_send_sync(
        owner.id,
        {
            "type": "group.created",
            "conversation_id": str(conversation_id),
            "name": conversation.name,
            "owner_id": str(owner.id),
            "created_at": conversation.created_at.isoformat(),
        },
    )

async def notify_group_joined(conversation, user):
    """加入群成功推给新成员"""
    await _user_group_send_async(
        user.id,
        {
            "type": "group.joined",
            "conversation_id": str(conversation.id),
            "name": conversation.name,
            "joined_at": timezone.now().isoformat(),
        },
    )

# 类似地为语音房/直播间/帖子/桌游房添加推送函数
```

#### 步骤 2：在创建/删除/状态变化接口调用推送

```python
# apps/voice/views.py → ChannelListView.post()
from .services import broadcast_channel_created

def post(self, request):
    # ... 创建语音房逻辑
    channel = create_channel(...)
    
    # 推送给相关用户
    if channel.visibility == "public":
        # 公开房间：前端轮询兜底（不做全员广播）
        pass
    elif channel.visibility == "group" and channel.group:
        # 群内可见：推给群成员
        broadcast_channel_created_to_group(channel, channel.group)
    
    # 推给创建者本人
    broadcast_channel_created_to_user(channel, request.user)
    
    return Response(...)
```

#### 步骤 3：新增广播函数到群组

```python
# apps/voice/services.py

def broadcast_channel_created_to_group(channel, group):
    """语音房创建推给群成员（通过会话组）"""
    try:
        layer = get_channel_layer()
        async_to_sync(layer.group_send)(
            f"chat_conv_{group.id}",
            {
                "type": "voice.channel.created",
                "channel_id": str(channel.id),
                "name": channel.name,
                "owner_id": str(channel.owner_id),
                "visibility": channel.visibility,
                "group_id": str(channel.group_id) if channel.group_id else None,
                "created_at": channel.created_at.isoformat(),
            },
        )
    except ChannelFull:
        logger.warning("voice.channel.created broadcast dropped (ChannelFull)")
    except Exception:
        logger.exception("voice.channel.created broadcast failed")
```

### 4.3 前端实现步骤

#### 步骤 1：扩展 ChatWSClient 事件处理（`web/src/ws/chat.ts`）

```typescript
// web/src/ws/chat.ts → dispatch() 方法扩展

switch (frame.type) {
  // ... 已有事件处理
  
  case "voice.channel.created": {
    const d = frame.data;
    useVoiceStore.getState().upsertChannel({
      id: d.channel_id,
      name: d.name,
      owner_id: d.owner_id,
      visibility: d.visibility,
      group_id: d.group_id,
      member_count: 0,
      i_am_in: false,
      created_at: d.created_at,
    });
    break;
  }
  
  case "voice.channel.deleted": {
    const d = frame.data;
    useVoiceStore.getState().removeChannel(d.channel_id);
    break;
  }
  
  case "live.channel.created": {
    const d = frame.data;
    useLiveStore.getState().upsertChannel({
      id: d.channel_id,
      name: d.name,
      owner_id: d.owner_id,
      visibility: d.visibility,
      group_id: d.group_id,
      status: d.status,
      created_at: d.created_at,
    });
    break;
  }
  
  case "live.channel.status.changed": {
    const d = frame.data;
    useLiveStore.getState().updateChannelStatus(d.channel_id, d.status);
    break;
  }
  
  case "live.channel.deleted": {
    const d = frame.data;
    useLiveStore.getState().removeChannel(d.channel_id);
    break;
  }
  
  case "post.created": {
    const d = frame.data;
    // 帖子列表有分页和 scope 筛选，新帖不一定属于当前视图
    // 只在匹配当前 scope 时才插入列表头部
    const currentScope = usePostsStore.getState().scope;
    if (shouldShowPost(d, currentScope)) {
      usePostsStore.getState().prependPost({
        id: d.post_id,
        author_id: d.author_id,
        title: d.title,
        visibility: d.visibility,
        group_id: d.group_id,
        created_at: d.created_at,
      });
    }
    break;
  }
  
  case "post.deleted": {
    const d = frame.data;
    usePostsStore.getState().removePost(d.post_id);
    break;
  }
  
  case "boardgame.room.created": {
    const d = frame.data;
    useBoardGameStore.getState().upsertRoom({
      id: d.room_id,
      name: d.name,
      owner_id: d.owner_id,
      game_type: d.game_type,
      visibility: d.visibility,
      group_id: d.group_id,
      created_at: d.created_at,
    });
    break;
  }
  
  case "boardgame.room.deleted": {
    const d = frame.data;
    useBoardGameStore.getState().removeRoom(d.room_id);
    break;
  }
  
  case "group.created": {
    const d = frame.data;
    useChatStore.getState().upsertConversation({
      id: d.conversation_id,
      name: d.name,
      type: "group",
      created_at: d.created_at,
    });
    break;
  }
  
  case "group.joined": {
    const d = frame.data;
    useChatStore.getState().upsertConversation({
      id: d.conversation_id,
      name: d.name,
      type: "group",
    });
    // 自动订阅新群的消息
    chatWS.subscribe([d.conversation_id]);
    break;
  }
}
```

#### 步骤 2：为各 store 添加实时更新方法

```typescript
// web/src/stores/voice.ts

export const useVoiceStore = create<VoiceState>((set) => ({
  // ... 已有状态和方法
  
  upsertChannel: (channel: VoiceChannelDescriptor) =>
    set((state) => {
      const seen = new Set(state.channels.map((c) => c.id));
      if (seen.has(channel.id)) {
        // 更新已有频道
        return {
          channels: state.channels.map((c) =>
            c.id === channel.id ? { ...c, ...channel } : c
          ),
        };
      } else {
        // 插入新频道到列表头部
        return { channels: [channel, ...state.channels] };
      }
    }),
  
  removeChannel: (channelId: string) =>
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
    })),
}));
```

```typescript
// web/src/stores/live.ts

export const useLiveStore = create<LiveState>((set) => ({
  // ... 已有状态和方法
  
  upsertChannel: (channel: LiveChannelDescriptor) =>
    set((state) => {
      const seen = new Set(state.channels.map((c) => c.id));
      if (seen.has(channel.id)) {
        return {
          channels: state.channels.map((c) =>
            c.id === channel.id ? { ...c, ...channel } : c
          ),
        };
      } else {
        return { channels: [channel, ...state.channels] };
      }
    }),
  
  updateChannelStatus: (channelId: number, status: string) =>
    set((state) => ({
      channels: state.channels.map((c) =>
        c.id === channelId ? { ...c, status } : c
      ),
    })),
  
  removeChannel: (channelId: number) =>
    set((state) => ({
      channels: state.channels.filter((c) => c.id !== channelId),
    })),
}));
```

```typescript
// web/src/stores/posts.ts

export const usePostsStore = create<PostsState>((set) => ({
  // ... 已有状态和方法
  
  prependPost: (post: Post) =>
    set((state) => {
      const seen = new Set(state.posts.map((p) => p.id));
      if (seen.has(post.id)) return state; // 已存在，不重复添加
      return { posts: [post, ...state.posts] };
    }),
  
  removePost: (postId: string) =>
    set((state) => ({
      posts: state.posts.filter((p) => p.id !== postId),
    })),
}));
```

#### 步骤 3：移除所有手动刷新按钮

```bash
# 回滚之前添加的 8 个手动刷新按钮
git revert <commit-hash>
```

---

## 五、实施计划

### 阶段一：语音房和直播间实时推送（优先级最高，3-4 天）

**后端工作**（2 天，预计 10 小时）：
- [ ] `apps/voice/services.py` 添加 `broadcast_channel_created_to_group()` 和 `broadcast_channel_deleted_to_group()`
- [ ] `apps/voice/views.py` 在创建/删除接口调用推送
- [ ] `apps/live/services.py` 添加直播间推送函数
- [ ] `apps/live/views.py` 在创建/删除/开始/停止接口调用推送
- [ ] 编写单元测试验证推送正确性

**前端工作**（1-2 天，预计 6 小时）：
- [ ] `web/src/ws/chat.ts` 扩展 `dispatch()` 处理 4 个新事件类型
- [ ] `web/src/stores/voice.ts` 添加 `upsertChannel()` 和 `removeChannel()`
- [ ] `web/src/stores/live.ts` 添加 `upsertChannel()`、`updateChannelStatus()` 和 `removeChannel()`
- [ ] 移除语音房和直播间列表页的手动刷新按钮
- [ ] 测试验收：用户 A 创建语音房 → 用户 B 自动看到新房间（< 1s 延迟）

### 阶段二：帖子和桌游房实时推送（优先级中，2-3 天）

**后端工作**（1.5 天，预计 8 小时）：
- [ ] `apps/posts/services.py` 添加帖子推送函数
- [ ] `apps/posts/views.py` 在创建/删除接口调用推送
- [ ] `apps/boardgame/services.py` 添加桌游房推送函数
- [ ] `apps/boardgame/views.py` 在创建/删除接口调用推送

**前端工作**（1 天，预计 5 小时）：
- [ ] `web/src/ws/chat.ts` 处理帖子和桌游房事件
- [ ] `web/src/stores/posts.ts` 添加 `prependPost()` 和 `removePost()`
- [ ] `web/src/stores/boardgame.ts`（如不存在则创建）添加实时更新方法
- [ ] 移除对应页面的手动刷新按钮
- [ ] 测试验收

### 阶段三：群列表实时推送（优先级低，1-2 天）

**后端工作**（1 天，预计 5 小时）：
- [ ] `apps/chat/services.py` 添加 `notify_group_created()` 和 `notify_group_joined()`
- [ ] `apps/chat/views.py` 在创建群/通过申请/接受邀请接口调用推送

**前端工作**（0.5 天，预计 3 小时）：
- [ ] `web/src/ws/chat.ts` 处理群创建/加入事件
- [ ] `web/src/stores/chat.ts` 已有 `upsertConversation()`，直接复用
- [ ] 测试验收

### 阶段四：全面测试与优化（1 天）

- [ ] 多用户并发测试（用户 A/B/C 同时操作，互相实时看到）
- [ ] 网络断开重连测试（断网后重连，是否自动恢复实时推送）
- [ ] 性能测试（推送延迟 < 1s，无卡顿）
- [ ] 边界情况测试（快速创建/删除、权限变化、跨群可见性）

---

## 六、验收标准

### 6.1 功能验收

- [ ] **语音房**：用户 A 创建语音房 → 用户 B 无需刷新 1s 内自动看到新房间
- [ ] **语音房**：用户 A 删除语音房 → 用户 B 的列表 1s 内自动移除该房间
- [ ] **直播间**：用户 A 创建直播间 → 用户 B 自动看到
- [ ] **直播间**：用户 A 开始直播 → 用户 B 看到状态从 "idle" 变为 "live"（实时徽章更新）
- [ ] **直播间**：用户 A 停止直播 → 用户 B 看到状态变回 "idle"
- [ ] **直播间**：用户 A 删除直播间 → 用户 B 的列表自动移除
- [ ] **帖子**：用户 A 发帖 → 用户 B 的信息流自动插入新帖（如果在当前 scope 内）
- [ ] **帖子**：用户 A 删除帖子 → 用户 B 的列表自动移除
- [ ] **桌游房**：用户 A 创建桌游房 → 用户 B 自动看到
- [ ] **桌游房**：用户 A 删除桌游房 → 用户 B 的列表自动移除
- [ ] **群列表**：用户 A 创建群 → 用户 A 的其他设备自动看到新群
- [ ] **群列表**：用户 B 通过入群申请 → 用户 B 的群列表自动出现新群

### 6.2 性能验收

- [ ] 推送延迟 < 1s（从操作完成到其他用户看到）
- [ ] 无卡顿、无闪烁
- [ ] 断网重连后自动恢复实时推送
- [ ] 并发操作不丢失推送

### 6.3 代码质量验收

- [ ] 所有推送函数有单元测试
- [ ] 前端事件处理有类型定义
- [ ] 后端推送异常有日志记录（不阻塞主流程）
- [ ] 手动刷新按钮已全部移除

---

## 七、技术债与优化方向

### 7.1 公开可见内容的全员广播

**当前方案**：公开语音房/直播间/帖子暂不做全员 WebSocket 推送，依赖前端缓存过期检查（60s）兜底。

**原因**：
- 全员广播需要维护 `global_online_users` 组，所有在线用户都加入该组
- 高并发下 `channel_layer.group_send()` 性能开销大
- Redis 内存占用增加

**优化方向**（第二期）：
- 实现智能推送：只推给"当前正在查看对应列表页面"的用户
- 前端页面挂载时发送 `subscribe_feed` 帧，卸载时 `unsubscribe_feed`
- 后端维护 `feed_public_voice`、`feed_public_live` 等动态订阅组

### 7.2 增量推送与分页冲突

**问题**：帖子列表有游标分页，实时推送的新帖可能导致分页偏移。

**当前方案**：新帖插入列表头部（`prependPost()`），不影响已加载的旧帖。

**潜在问题**：
- 用户滚动到底部加载下一页时，可能出现重复或遗漏
- 需要按 `created_at` 去重

**优化方向**（第二期）：
- 实现"有新帖提示"轻量级通知，用户点击后才刷新列表
- 或使用时间戳锚点分页（`?before=<timestamp>`）代替游标

### 7.3 跨设备同步

**当前方案**：用户 A 在设备 1 创建语音房，设备 2 通过 `chat_user_{user_id}` 组收到推送。

**限制**：
- 需要确保所有设备都保持 ChatWS 连接
- 设备 2 离线期间的推送会丢失（WebSocket 无持久化）

**优化方向**（第二期）：
- 添加"未读通知"持久化机制（类似未读消息）
- 登录时拉取离线期间的列表变化

---

## 八、风险与注意事项

### 8.1 推送风暴

**风险**：用户快速创建/删除多个语音房，导致大量推送事件堆积。

**缓解措施**：
- `channel_layer.group_send()` 已有 `ChannelFull` 异常捕获，慢消费者不阻塞其他用户
- 前端 store 使用 `upsertChannel()` 去重，避免重复渲染

### 8.2 权限泄露

**风险**：推送给不该看到的用户（如私密群的语音房推给非成员）。

**缓解措施**：
- 后端在推送前严格检查 `visibility` 和 `group_id`
- 只推给群成员组（`chat_conv_{group_id}`），不推给全局
- 前端收到推送后再次检查权限（防御性编程）

### 8.3 历史数据不一致

**风险**：用户离线期间错过推送，重新上线后列表数据陈旧。

**缓解措施**：
- 保留现有的"缓存时间戳过期检查"机制作为兜底
- 页面挂载时检查 `lastFetched`，超过 60s 则重新加载
- WebSocket 重连后不做全量同步（避免性能问题），依赖缓存过期机制

---

## 九、总结

### 核心改变

1. **移除手动刷新按钮** → 所有列表变化由 WebSocket 推送自动更新
2. **扩展 ChatWS 推送 11 个新事件类型** → 覆盖语音房、直播间、帖子、桌游房、群列表
3. **前端 store 实时更新** → `upsertChannel()`、`removeChannel()` 等方法响应推送

### 预期效果

- ✅ 所有界面实时刷新（< 1s 延迟）
- ✅ 多用户协作体验流畅
- ✅ 无需手动刷新或定时轮询
- ✅ 断网重连后自动恢复实时性

### 工作量评估

| 阶段 | 后端 | 前端 | 总计 |
|------|------|------|------|
| 语音房 + 直播间 | 10h | 6h | 16h (2 天) |
| 帖子 + 桌游房 | 8h | 5h | 13h (1.5 天) |
| 群列表 | 5h | 3h | 8h (1 天) |
| 测试与优化 | 4h | 4h | 8h (1 天) |
| **总计** | **27h** | **18h** | **45h (5.5 天)** |

---

**下一步行动**：
1. 用户确认方案
2. 创建后端推送函数框架
3. 逐模块实施（语音房 → 直播间 → 帖子 → 桌游房 → 群列表）
4. 全面测试验收
5. 移除所有手动刷新按钮

**备注**：本方案基于现有 WebSocket 架构，无需引入新的技术栈或中间件，最小化风险和改动范围。
