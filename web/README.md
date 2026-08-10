# Elysia Web 前端（阶段五 M5-1 基座）

React 18 + Vite + TypeScript + Zustand 的 Elysia 多媒体独立应用前端。
本里程碑为工程基座：认证闭环、路由守卫、全局状态、API 客户端、Presence WebSocket、健康检查。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`；
> 实施步骤见 `../docs/plans/阶段五-M5-1前端基座开发步骤.md`。

## 当前里程碑（M5-1，已完成）

- [x] Vite + React 18 + TS 工程脚手架（`web/` 目录）
- [x] 路由（React Router 6）：登录/注册公开；受保护主布局（会话/设置占位）
- [x] 全局状态（Zustand）：auth（token/当前用户）、presence（在线用户）、连接状态
- [x] 认证闭环：注册 → 登录 → JWT 存取与自动刷新 → 登出；401 拦截静默续期 + 重放
- [x] API 客户端（fetch 封装）：自动 Authorization、错误归一（DRF detail/字段错误）、401 刷新互斥锁
- [x] Presence WebSocket：`/ws/presence/?token=<jwt>` 单例连接 + 心跳 + 指数退避重连
- [x] 健康检查接线：`GET /api/v1/health/live/` 启动自检（侧边栏显示后端状态）
- [x] 端到端验收：注册/登录/登出/刷新恢复/回跳/守卫，真实浏览器通过

**不包含（里程碑边界）**：聊天（M5-2）、语音（M5-3）、直播（M5-4）、桌游（M5-5）、爱莉集成（M5-6）。

## 目录结构

```text
web/
├── package.json
├── vite.config.ts          # React + TS + dev proxy（/api、/ws 代理到后端）
├── tsconfig.json
├── index.html
├── .env.example            # VITE_API_BASE_URL / VITE_WS_BASE_URL
├── .gitignore
└── src/
    ├── main.tsx            # 入口：会话恢复 + Router 挂载
    ├── App.tsx             # 路由表
    ├── api/
    │   ├── client.ts       # fetch 封装：baseURL / Authorization / 错误归一 / 401 刷新重放
    │   ├── auth.ts         # register / login / refresh / me / profile
    │   ├── users.ts        # users/search、friends 骨架（M5-1 仅契约）
    │   ├── health.ts       # health/live 与 health
    │   └── types.ts        # 与 backend 序列化器对齐的 TS 类型
    ├── stores/
    │   ├── auth.ts         # token / 当前用户 / 登录登出 / 会话恢复
    │   └── presence.ts     # 在线用户集合 + 连接状态
    ├── ws/
    │   └── presence.ts     # /ws/presence/ 单例 + 心跳 + 重连
    ├── hooks/
    │   └── useAuth.ts      # 登录/登出/回跳组合封装
    ├── pages/
    │   ├── LoginPage.tsx
    │   ├── RegisterPage.tsx
    │   ├── HomeLayout.tsx  # 受保护主布局（侧边栏 + Outlet）
    │   ├── ConversationsPage.tsx  # 占位（M5-2）
    │   └── SettingsPage.tsx       # 占位
    ├── components/
    │   └── ProtectedRoute.tsx
    ├── styles/global.css
    └── vitest/             # 单测 + 契约测试
```

## 启动方式

```bash
# 0) 前置：后端已启动（见 backend/README.md）
#    注意：Ayla 后端在 8100 端口启动（8000 被 Elysium 主进程占用）
#    Ayla/backend/.venv/Scripts/python.exe manage.py runserver 127.0.0.1:8100

# 1) 安装依赖
npm install

# 2) 启动 dev server（默认代理到 127.0.0.1:8100）
npm run dev

# 3) 构建
npm run build

# 4) 测试（Vitest：auth store / client 401 重放与互斥 / 路由守卫 / presence）
npm run test
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VITE_API_BASE_URL` | 空（走 Vite proxy） | 生产环境 API 根地址，如 `https://app.example.com` |
| `VITE_WS_BASE_URL` | 空（走 Vite proxy，`ws:` 自动） | 生产环境 WS 根地址，如 `wss://app.example.com` |
| `VITE_DEV_PROXY_TARGET` | `http://127.0.0.1:8100` | 仅开发；Vite dev proxy 目标后端地址（Ayla 后端在 8100） |

开发默认同源走 Vite proxy（`/api` → 后端、`/ws` → 后端，`ws: true`），无需 CORS。
后端 `ALLOWED_HOSTS=["*"]` 已放行本地。

## 与后端契约对齐要点

- 用户 `id` 为字符串（UUID），`UserPublic` 字段：`id/username/nickname/avatar/signature/status/online/date_joined`
- JWT：`ROTATE_REFRESH_TOKENS=True` → **每次 refresh 都返回新 refresh，前端必须用返回值覆盖旧值**（已实现）
- Presence WS：`/ws/presence/?token=<jwt>`；服务端推 `presence.update` 增量；`ping`→`pong` 心跳

## 已知取舍（M5-1 决策）

1. **refresh token 持久化**：存 `sessionStorage`（关闭标签页即失效，XSS 面小于 localStorage，刷新页面可恢复会话）。access 只存内存。
2. **样式方案**：本期只做全局 CSS + 最小 CSS 变量，无组件库/设计 token；视觉系统留待 M5-2 或后续统一。
3. **CORS**：本地 dev 走 Vite proxy 同源；若未来前端直连后端域名，需评估在 backend 加 `django-cors-headers`（公共契约变更，先说明再动）。
4. **登录/注册 401**：认证端点标记 `noRetry401`，401 原样归一给页面展示后端错误，不触发刷新重放（避免登录失败误报"登录已过期"）。
5. **Presence 增量**：后端推 `presence.update` 增量帧，前端按 `user_id` 合并/移除（与 backend `consumers.py` 对齐）。
6. **会话恢复**：页面启动时若 `sessionStorage` 有 refresh，先续期拿 access 再拉 `me`，恢复完成前不渲染路由，避免已登录用户闪跳登录页。
