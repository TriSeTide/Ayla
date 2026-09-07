# 群聊子群（SubGroup）功能

> 状态：已实现（前后端 + 数据库迁移）
> 范围：`Ayla/backend/apps/chat/`（模型/API/WS）+ `Ayla/web/src/`（宽屏侧栏/窄屏选项卡/群信息编辑）

## 1. 功能概述

群聊内消息按「子群」分组展示，类似频道/分区：

- 每个群至少有一个**默认组**（`is_default=True`，创建群时自动生成，显示名「默认组」），
  即子群功能上线前的群聊本体；默认组**不可删除**，可改名；
- 宽屏（>768px）：左侧栏「聊天」场景项下展开子群列表（默认展开，可收起），
  默认组固定第一，其余按最近消息倒序；新消息立即前移（含自己发送、正在查看子群，
  以及携带对应子群归属的戳一戳事件），
  无消息或排序值相同保持原序。先排序再显示前三项，展开更多延续同序；
  点击子群行切换聊天内容；子群行显示独立未读红点与当前选中态，重排不改变选中对象；
- 窄屏（≤768px）：聊天页输入框上方显示可左右滑动的选项卡切换栏（**子群数 > 1 时**才显示；
  只有默认组时不显示）；
- 子群增删改仅**群主/管理员**可操作：
  - 宽屏：子群列表下方「编辑」按钮 → 编辑态变【+】【x】；编辑态每个子群行出现编辑按钮，
    点击弹窗可改名/删除（删除需二次确认）；
  - 窄屏：编辑入口在**群信息界面**（GroupInfo）的「子群」区块，交互与宽屏一致；
- 删除子群时，其**聊天记录一并永久删除**（不可恢复，删除前二次确认提示）；
- 未读按**子群独立统计**：子群列表/选项卡各自显示未读数；进入/切换只加载历史，
  只有实际进入可视区的消息逐条确认已读，尚未看到的消息保留红点；
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
| GET | `/conversations/<id>/subgroups/` | 子群列表（含本人 `unread_count`/`unread_seqs` 与 `last_message_seq`） | 群成员 |
| POST | `/conversations/<id>/subgroups/` | 创建子群 `{name}` | 群主/管理员 |
| PATCH | `/conversations/<id>/subgroups/<sid>/` | 改名 `{name}` / 禁言开关 `{muted}` | 群主/管理员 |
| DELETE | `/conversations/<id>/subgroups/<sid>/` | 删除（聊天记录一并永久删除；默认组 400） | 群主/管理员 |
| POST | `/conversations/<id>/subgroups/<sid>/read/` | 显式整组已读兼容接口；聊天页不自动调用 | 群成员 |

消息接口扩展：

- `GET /conversations/<id>/messages/?subgroup_id=<sid>`：按子群过滤历史
  （默认组视图含旧消息；不传 = 全部，兼容旧客户端）；
- `POST /conversations/<id>/messages/` 入参 `subgroup_id`（可选；群聊不传归默认组，
  私聊传了 400，子群必须属于该群）；
- 发消息校验：目标子群 `muted=True` 且发送者非群主/管理员 → 403「该子群已禁言」；
- `MessageSerializer` 新增 `subgroup_id` 字段。

子群列表、创建和更新响应均包含只读整数 `last_message_seq`：同一会话内该子群已有消息的最大
`Message.seq`，空组为 0；默认组同时计入 `subgroup_id=NULL` 的旧消息。它与未读状态、发送者
及消息是否撤回无关，包含戳一戳；撤回/已读操作本身不产生新序号。列表按原有子群顺序返回，
视图通过一次按 `subgroup_id` 分组的 `Max(seq)` 查询提供排序依据，未新增数据库字段或迁移。

单条已读使用 `POST /conversations/<id>/messages/<mid>/read/`，请求 `{exact:true}`。
响应 `marked_seqs` 是本次固定范围内服务器已确认的全部序号；群聊 exact 另外返回
`subgroup_id`（旧 null 消息解析为真实默认组 ID，支持列表尚未加载时正确记账）。
整组兼容接口返回 `{marked, marked_seqs}`；幂等重试即使 `marked=0` 仍返回已确认序号，
客户端只按序号集合消除，不按 `marked` 重复扣数，不猜测缺少范围的旧响应已读了哪些消息。

## 5. WebSocket 事件

- `message.new` / `message.poke` 帧新增 `subgroup_id`（null = 默认组/旧消息）；
- `subgroup.created` / `subgroup.updated`：`{conversation_id, subgroup_id, name, is_default}`；
- `subgroup.deleted`：`{conversation_id, subgroup_id}`（该子群消息已随删除清空）；
- `subgroup.read`：`{conversation_id, subgroup_id, user_id, marked, marked_seqs}`；群聊单条
  exact 和显式整组动作都会发送。本人端只移除明确确认的序号，同步子群/会话未读与缓存消息
  `read_by_me`；重复回执不重复扣数，旧帧缺少 `marked_seqs` 时不得整组清零。

## 6. 前端实现

- `stores/subgroup.ts`：子群列表 / 当前选中子群 / 子群独立未读投影（`${convId}:${subgroupId}` 键）；
  `lastMessageSeqByKey` 保留每个子群已知最大消息序号；列表加载、改名与早到消息取最大值合并，
  迟到 REST 或重连补发不会回退顺序；删除子群或执行 store `reset` 时清理相应投影。
  当前账号确认集合过滤迟到列表/编辑快照与重放；快照之后新到的未读继续保留。
  `stores/auth.ts` 在登出与用户身份变更时重置子群状态；异步已读响应只能更新发起账号的状态。
- `stores/message.ts`：WS 新消息/戳一戳、本人发送 REST 确认、幂等确认和历史补页统一推进子群
  已知序号；本地 pending/失败消息（无服务端序号）不抢位，旧历史不覆盖较新的消息活动。
  已确认序号同步投影到迟到历史的 `read_by_me`，避免红点和消息属性不一致。
  现有 UI 的 `sendPoke` 未传 `subgroup_id`，默认归入默认组；本次只消费事件已有的子群归属，
  不改变该发送接口行为。
- `hooks/useChat.ts`：`loadHistory`/`loadMoreHistory`/`loadHistoryUntilSeq` 支持子群过滤；
  `sendMessage`/`sendOptimistic`/`retryOptimistic` 携带 `subgroup_id`；
  `markMessageReadExact` 仅确认实际可见消息，并按回执同步子群/会话；
  `markSubgroupRead` 仅保留显式整组动作兼容，日常群聊不调用；
- `components/chat/MessageList.tsx`：`subgroupId`/`isDefaultSubgroup` 过滤显示 +
  子群未读序号覆盖（会话级 `unread_seqs` 是全局的，子群视图用子群自己的）；
- `pages/group/GroupChat.tsx`：子群选项卡切换栏（>1 子群显示，横向滑动）；
  普通未读标签仅跳转，随后仍由可视区逐条确认；@/回复标签仅取当前子群未读交集；
- `layout/ChannelSidebar.tsx`：宽屏子群展开/收起/编辑（+ / x / 每行编辑按钮）；
  使用 `sortSubgroupsByActivity` 生成默认组优先、最近消息降序的独立投影，基础列表和窄屏顺序不变；
- `pages/group/GroupInfo.tsx`：窄屏群信息内子群管理区块；
- `components/group/SubGroupDialog.tsx`：添加/编辑子群弹窗（两处共用）；
- `ws/chat.ts`：群聊 `message.new` 先计未读，等待实际可视区确认，不以“当前在底部”代替看见；
  仅明确的私信保持原有底部自动确认路径；`subgroup.*` 事件同步列表与精确未读。

## 7. 未读语义

- 子群未读 = 该子群内非本人、非撤回、非 poke、无已读回执的消息数（`MessageRead` 消息级回执天然支持）；
- 会话级 `unread_count`（群卡片红点）与子群按确认序号集合同步；另一子群未读不受影响；
- 进入聊天/点选项卡/点侧栏行/点击未读标签都不等于整组看过；复用 `MessageList` 可视区
  观察器，消息至少 60% 进入可视区后请求 exact，成功才移除对应未读，失败保留；
- 已确认集合和请求账号绑定；退出/切换账号后不会继承前一账号的确认记录。

## 8. 测试

- 后端：`apps/chat/tests/test_subgroups.py`（默认组、CRUD 权限、删除清空聊天记录、消息归属、
  历史过滤、独立未读与标已读幂等）；
- 前端：`web/src/vitest/subgroup.test.tsx`（store 投影、侧栏展开/编辑、选项卡显隐与切换）。
- 排序契约：`apps/chat/tests/test_subgroup_activity.py` 检查 API 序号、空组、默认组旧消息与会话隔离；
  `web/src/vitest/subgroup.test.tsx` 和 `ws-chat.test.ts` 检查默认组固定、隐藏子群进入前三项、
  当前查看/本人发送/戳一戳重排、重放与迟到 REST 不回退、稳定并列及选择保留。

本次结果与验证边界见 [宽屏子群消息排序验收](report/宽屏子群消息排序验收-2026-09-07.md)。
已读修复另见 [群聊可视消息已读修复验收](report/群聊可视消息已读修复验收-2026-09-07.md)，
对应 `web/src/vitest/subgroup-read.test.ts` 与后端 `test_subgroup_read_receipts.py`。
