# 桌游房列表实时更新审计

## 根因

WebSocket 连接只加入 `chat_user_*`、公开帖子组和用户主动订阅的 `chat_conv_*`。桌游创建/删除却广播到 `chat_conv_*`，而桌游页不保证用户已经打开对应聊天页并订阅该会话，因此其他在线用户收不到事件。此前前端也直接信任创建事件的稀疏 payload，无法完成可见性判断。

## 修复

- 新增按群成员自动加入的 `boardgame_group_*`，公开/无归属房间使用 `boardgame_public`；删除同样发送到这些组。
- 桌游 WS 创建事件只做去重 upsert，列表仍通过受权限保护的 REST 列表作为权威对账，删除事件只移除 id。
- REST 创建/删除成功后发本地事件，群页保留对账；两类桌游页统一使用 reconcile。
- WS 连接建立及关闭时维护桌游专用组生命周期。

## 验证

本地 `pnpm exec tsc -b --noEmit` 与 Vitest 启动被 pnpm 的 `ERR_PNPM_IGNORED_BUILDS`（esbuild 构建脚本未获批准）阻断，未伪称测试通过。
