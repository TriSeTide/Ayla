# Ayla 后端独立启动修复记录（Elysium 不在线不再刷 WinError 10061）

> 性质：一次性事故 / 验收记录。时间：2026-08-17。
> 结论：Ayla 后端本身可正常启动；"启动不了"是内嵌 SSE 出站投影在 Elysium 不在线时刷完整 traceback 造成的误判。修复后 Ayla 可不依赖 Elysium 独立启动。

## 1. 现象与时间线

- 用户反馈：Ayla 后端启动不了。
- 复现（用户终端输出 + 本机复测）：`python manage.py runserver 127.0.0.1:8100` 后：
  - `System check identified no issues`，daphne `Listening on TCP address 127.0.0.1:8100`（**后端本身启动成功**）；
  - `apps.elysia_bridge.inline` 持续打印：
    - `内嵌 SSE 出站投影已启动：stream=… → http://127.0.0.1:8000`
    - `内嵌 SSE 出站投影异常退出，5.0s 后自动重启` + **完整 traceback**：
      `httpcore.ConnectError: [WinError 10061] 由于目标计算机积极拒绝，无法连接。`
- 证据来源：用户贴出的 runserver 终端输出；本机 `runtime/startup_debug.log(.err)` 复测一致；当时 `netstat` 确认 8000 无监听、无 python 进程。

## 2. 根因

调用链：`start_bridge_thread`（AppConfig.ready，daemon 线程）→ `_bridge_thread_main` → `_run_bridge_once` → `run_bridge_loop` → `credentials.ensure_session` → `ElysiaClient.issue_session`（`POST /api/v1/auth/sessions`）。

- Elysium 主后端（`ELYSIA_BASE_URL=http://127.0.0.1:8000`）不在线时，httpx 抛**裸 `httpx.ConnectError`**；
- `run_bridge_loop` 启动阶段（services.py）只捕获 `ProfileNotConfigured` / `ElysiaUnauthenticated`，裸传输异常冒泡出循环；
- `_bridge_thread_main`（inline.py）的 `except Exception` → `logger.exception` 打印完整 traceback，按 5s→60s 有界退避无限重启 → 周期性刷屏。

与 M4-4 开发文档声明的设计意图（"Elysium 未运行由 run_bridge_loop 的有界退避覆盖，不崩溃，等 Elysium 起来后自动连上"）相悖：因为传输异常没被识别为"可重试的上游不可达"，降到线程级兜底刷屏。

## 3. 已执行操作（可逆性：纯代码改动 + 文档，未提交）

1. `backend/apps/elysia_bridge/elysia_client.py`
   - 新增 `_send()`：把 `httpx.HTTPError`（ConnectError/超时/断网）统一映射为 `ElysiaTransportError`；所有同步 REST 调用点改走 `_send`。
   - `stream_sse` 异步连接加 `except httpx.HTTPError` → `ElysiaTransportError`（连接建立或读取中途断网）。
2. `backend/apps/elysia_bridge/services.py`
   - `run_bridge_loop` 启动阶段补 `except ElysiaTransportError`：Elysium 不可达时仅首次打一条"上游不可达，Ayla 独立运行，SSE 桥接后台退避等待"warning（`degraded` 状态翻转降噪），恢复时打一条 info，不刷 traceback、不阻塞 server 启动。
3. 测试（新增 4 项）
   - `test_elysia_client.py`：`issue_session` / `inject_message` 连接被拒 → `ElysiaTransportError`；`stream_sse` 网络错误 → `ElysiaTransportError`。
   - `test_bridge_loop.py`：`test_loop_waits_when_upstream_down_then_reconnects` —— Elysium 不可达时循环退避不冒泡，恢复后自动连上并投影。
4. 文档：`backend/README.md` 启动章节新增"独立启动（Elysium 不在线）"说明。

## 4. 验证方法与结果

- `apps/elysia_bridge` 全量测试：113 项通过（含新增 4 项）。
- `apps/chat`、`apps/accounts` 测试：全部通过，无回归。
- `python -m compileall` 变更文件通过。
- 真实冒烟：Elysium(8000) 在线、Ayla(8100) 已有实例持有 bridge 锁时，另起 8101 端口实例启动干净——runserver 正常监听，bridge 仅一条"已有实例持有锁，跳过"warning，无 traceback。
- **未做**：Elysium 完全离线时的真实启动验收（当时 8000 已有用户运行的实例；按 AGENTS.md 固定运行策略，agent 不得停止/重启用户手动运行的 Elysium）。该路径由"启动阶段退避"单元测试覆盖，等待用户下次在 Elysium 未启动、Ayla 无实例时自行启动验证。

## 5. 待决 / 归属

- 改动留在 Ayla 工作区**未提交**（同时工作区存在其他会话对 `web/src/components/chat/PrivateChatPane.tsx` 的修改，未触碰）。提交时机与方式由用户决定。
- 验证归属：真实离线启动验收需用户手动执行（按纪律），预期日志应只有一条 degraded warning，REST API/WS 正常。