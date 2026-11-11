# 爱莉作为普通用户：默认好友 / 默认会话 / ElyH 在线

> 2026-11-11 落地。用户（TriSeTide）定的三条规则，**不引入任何「爱莉专属入口」**——
> 爱莉就是一个真实 user（`username=elysia`，`ElysiaProfile.user` 绑定），
> 前端按普通好友 / 普通私聊渲染。

## 规则与实现位置

| 规则 | 行为 | 实现 |
|---|---|---|
| 一 | 所有账号默认有爱莉的好友 | 注册时 `ensure_elysia_relationship()`；存量由迁移 `elysia_bridge.0005` 补齐 |
| 二 | 消息列表默认有爱莉的私聊会话 | 同上，会话复用 `chat.services.get_or_create_conversation`（不另写建会话逻辑） |
| 三 | ElyH 连上 Ayla 时爱莉在线，断开即离线 | 独立 Redis 标记 `presence:elyh:<user_id>`（TTL 90s），由 `AylaBridgeConsumer` 维护 |

- `apps/elysia_bridge/services.py::ensure_elysia_relationship(user) -> bool`
  幂等：`Friendship.update_or_create` 双向各一条（`accepted`）+
  `get_or_create_conversation`。爱莉 profile 缺失/禁用 → 静默跳过 + 一行 warning。
- `apps/accounts/views.py::RegisterView.create`：`try/except + logger.exception`，
  **关系补齐失败不得让注册失败**。
- 迁移 `0005_backfill_elysia_relationship`：遍历 `is_active` 用户（排除爱莉自己）内联
  等价逻辑（不 import 服务层——迁移必须绑定历史模型）。正向幂等，**反向 `noop`**
  （理由写在迁移 docstring：没有 provenance 列可区分，且删会话会级联删除聊天历史）。

## 规则三的关键约束：两个标记源必须分离

`presence:<user_id>` 归 Ayla 前端 `PresenceConsumer` 所有（活连接引用计数 + 60s TTL，
断开/心跳都写它）。ElyH 若共用同一个 key，两侧会互相 clear / 互相续期，把真实在线的
另一侧标成离线——所以 ElyH 用独立的 key 族：

- `presence:elyh:<user_id>` → JSON `{"ts": ..., "owner": "<channel_name>"}`，TTL **90s**
  （DSH 每 30s ping，3 个周期；进程被 kill 也最多 90s 自然过期）。
- `mark_elyh_online` 在 consumer `connect` 成功后与 **每次 ping** 调用（续期）；
  `clear_elyh_online` 在 `disconnect` 调用。
- **owner 比较**：同 profile 新连接顶替旧连接时，旧连接晚到的 disconnect 带的是旧
  channel_name，不匹配即跳过，不会清掉新连接的标记。
- 对外可见性：`UserPublicSerializer` 取「Ayla presence 或 ElyH」的**或**。
- **隐身（invisible）只管 Ayla presence**：用户的隐身不作用于 ElyH 标记（爱莉没有隐身
  概念；标记只表达「插件连着」这一运行事实）。dnd/away 的文案不变。

## 验证

```bash
cd Ayla/backend
./.venv/Scripts/python.exe -m pytest apps/accounts apps/chat apps/elysia_bridge -q \
  --ds=config.settings_test_mysql -o addopts=""
```

定向用例：

- `elysia_bridge/tests/test_elysia_relationship.py`（注册即好友/会话、幂等、降级、异常兜底）
- `accounts/tests/test_elyh_presence.py`（标记存储层、或关系、互不影响、隐身边界）
- `elysia_bridge/tests/test_elyh_bridge_presence.py`（connect 写 / ping 续 / disconnect 清 / 顶替）
- `elysia_bridge/tests/test_migration_0005_backfill.py`（前进 / 幂等 / 反向 noop）
