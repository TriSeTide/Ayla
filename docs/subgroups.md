# 群聊子群（SubGroup）功能

> 状态：已实现（前后端 + 数据库迁移）
> 范围：`Ayla/backend/apps/chat/`（模型/API/WS）+ `Ayla/web/src/`（宽屏侧栏/窄屏选项卡/群信息编辑）

## 1. 功能概述

群聊内消息按「子群」分组展示，类似频道/分区：

- 每个群至少有一个**默认组**（`is_default=True`，创建群时自动生成，显示名「默认组」），
  即子群功能上线前的群聊本体；默认组**不可删除**，可改名；
- 宽屏（>768px）：左侧栏「聊天」场景项下展开子群列表（默认展开，可收起），
  点击子群行切换聊天内容；子群行显示独立未读红点与当前选中态；
- 窄屏（≤768px）：聊天页输入框上方显示可左右滑动的选项卡切换栏（**子群数 > 1 时**才显示；
  只有默认组时不显示）；
- 子群增删改仅**群主/管理员**可操作：
  - 宽屏：子群列表下方「编辑」按钮 → 编辑态变【+】【x】；编辑态每个子群行出现编辑按钮，
    点击弹窗可改名/删除（删除需二次确认）；
  - 窄屏：编辑入口在**群信息界面**（GroupInfo）的「子群」区块，交互与宽屏一致；
- 删除子群时，其**聊天记录一并永久删除**（不可恢复，删除前二次确认提示）；
- 未读按**子群独立统计**：子群列表/选项卡各自显示未读数；切换子群即标该子群已读；
- **子群禁言开关**（`muted`）：开启后仅群主/管理员可在该子群发言，普通成员发消息 403；
  开关由群主/管理员在子群编辑弹窗中设置；禁言子群在列表/选项卡显示「禁言」标记，
  普通成员视角输入框禁用并提示。

## 2. 数据模型

```text
GroupSubGroup (group_subgroups)
├── id            AutoField
├── conversation  FK → Conversation (related_name="subgroups")
├── name          CharField(64)（同群内唯一：uniq_conv_subgroup_name）
├── is_default    BooleanField（默认组标记，不可删除）
├── muted         BooleanField（子群禁言开关：开启后仅群主/管理员可发言）
└── created_at    DateTimeField

Message.subgroup  FK → GroupSubGroup (related_name="messages", null=True, SET_NULL, db_index)
```

- `Message.subgroup = NULL` 表示子群功能上线前的旧消息，语义上归默认组
  （查询/未读统计时默认组视图包含 `subgroup IS NULL` 的消息）；
- 删除子群由 `services.delete_subgroup` 在事务内先删该子群全部消息（已读回执随消息级联），
  再删子群本身；`Message.subgroup` 的 `SET_NULL` 仅作兜底（正常删除路径不会置空）。

## 3. 迁移

`apps/chat/migrations/0011_group_subgroup.py`：

1. 建 `group_subgroups` 表 + `messages.subgroup_id` 列 + 同群子群名唯一约束；
2. 数据迁移（RunPython）：为每个现有群聊创建「默认组」，并把该群 `subgroup IS NULL`
   的旧消息归入默认组；反向迁移把默认组消息置回 NULL 并删除默认组。

新群创建（`GroupCreateView`）时同步创建默认组。

## 4. REST API（挂 `/api/v1/chat/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/conversations/<id>/subgroups/` | 子群列表（含本人 `unread_count`/`unread_seqs`） | 群成员 |
| POST | `/conversations/<id>/subgroups/` | 创建子群 `{name}` | 群主/管理员 |
| PATCH | `/conversations/<id>/subgroups/<sid>/` | 改名 `{name}` / 禁言开关 `{muted}` | 群主/管理员 |
| DELETE | `/conversations/<id>/subgroups/<sid>/` | 删除（聊天记录一并永久删除；默认组 400） | 群主/管理员 |
| POST | `/conversations/<id>/subgroups/<sid>/read/` | 标该子群已读（本人） | 群成员 |

消息接口扩展：

- `GET /conversations/<id>/messages/?subgroup_id=<sid>`：按子群过滤历史
  （默认组视图含旧消息；不传 = 全部，兼容旧客户端）；
- `POST /conversations/<id>/messages/` 入参 `subgroup_id`（可选；群聊不传归默认组，
  私聊传了 400，子群必须属于该群）；
- 发消息校验：目标子群 `muted=True` 且发送者非群主/管理员 → 403「该子群已禁言」；
- `MessageSerializer` 新增 `subgroup_id` 字段。

## 5. WebSocket 事件

- `message.new` / `message.poke` 帧新增 `subgroup_id`（null = 默认组/旧消息）；
- `subgroup.created` / `subgroup.updated`：`{conversation_id, subgroup_id, name, is_default}`；
- `subgroup.deleted`：`{conversation_id, subgroup_id}`（消息已归默认组）；
- `subgroup.read`：`{conversation_id, subgroup_id, user_id, marked}`（本人端本地清零未读 +
  会话未读递减 `marked` 条）。

## 6. 前端实现

- `stores/subgroup.ts`：子群列表 / 当前选中子群 / 子群独立未读投影（`${convId}:${subgroupId}` 键）；
- `hooks/useChat.ts`：`loadHistory`/`loadMoreHistory`/`loadHistoryUntilSeq` 支持子群过滤；
  `sendMessage`/`sendOptimistic`/`retryOptimistic` 携带 `subgroup_id`；
  `markSubgroupRead` 标已读并同步会话未读；
- `components/chat/MessageList.tsx`：`subgroupId`/`isDefaultSubgroup` 过滤显示 +
  子群未读序号覆盖（会话级 `unread_seqs` 是全局的，子群视图用子群自己的）；
- `pages/group/GroupChat.tsx`：子群选项卡切换栏（>1 子群显示，横向滑动）；
- `layout/ChannelSidebar.tsx`：宽屏子群展开/收起/编辑（+ / x / 每行编辑按钮）；
- `pages/group/GroupInfo.tsx`：窄屏群信息内子群管理区块；
- `components/group/SubGroupDialog.tsx`：添加/编辑子群弹窗（两处共用）；
- `ws/chat.ts`：`message.new` 按子群计未读；`subgroup.*` 事件同步列表与未读。

## 7. 未读语义

- 子群未读 = 该子群内非本人、非撤回、非 poke、无已读回执的消息数（`MessageRead` 消息级回执天然支持）；
- 会话级 `unread_count`（群卡片红点）保持原有逻辑，子群已读后按 `marked` 条递减；
- 切换子群（进入聊天/点选项卡/点侧栏行）即调 `POST .../read/` 标该子群已读。

## 8. 测试

- 后端：`apps/chat/tests/test_subgroups.py`（默认组、CRUD 权限、删除清空聊天记录、消息归属、
  历史过滤、独立未读与标已读幂等）；
- 前端：`web/src/vitest/subgroup.test.tsx`（store 投影、侧栏展开/编辑、选项卡显隐与切换）。
