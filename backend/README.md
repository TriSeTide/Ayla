# Elysia 独立应用后端（阶段四 M4-1 基座）

Django 5 + Channels 4 + Redis 的独立应用后端，作为 Elysia Web 前端的唯一 API/WS 入口。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`。

## 当前里程碑（M4-1 基座）

- [x] Django 5 + Channels 4 ASGI 骨架（daphne 承载）
- [x] `accounts` 应用：用户模型（AbstractUser + uuid id）、JWT（simplejwt）、
      注册/登录/资料/搜索、好友申请/同意/拒绝/删除、Redis 在线状态
- [x] Presence WebSocket（`/ws/presence/?token=<jwt>`）+ 心跳
- [x] 健康检查（`/api/v1/health/`、`/api/v1/health/live/`）
- [x] Docker Compose（MySQL 8 / Redis 7 / MinIO）+ 契约测试

## 目录结构

```text
backend/
├── manage.py
├── pyproject.toml          # uv 依赖管理 + pytest 配置
├── config/                 # settings / asgi / wsgi / urls / settings_test
├── apps/
│   ├── accounts/           # 用户/认证/好友/在线状态
│   ├── chat/               # M4-2 占位
│   └── elysia_bridge/      # M4-4 占位
└── tests/                  # 契约测试
```

## 环境准备

```bash
# Python >= 3.11（建议 3.12+），依赖管理用 uv
uv sync --extra dev        # 或 python -m pip install -e ".[dev]"
cp .env.example .env       # 按需修改（本地默认 SQLite + 本机 Redis）
```

## 启动

```bash
# 1) 迁移
python manage.py migrate

# 2) 启动开发服务器（daphne 已在 INSTALLED_APPS，runserver 即 ASGI）
python manage.py runserver 0.0.0.0:8000
```

生产部署：`daphne -b 0.0.0.0 -p 8000 config.asgi:application`，
前端由 Nginx 反代，WS 需带升级头（见开发文档 10 节）。

## 基础设施（MySQL/Redis/MinIO）

```bash
docker compose -f ../docker-compose.yml up -d
```

仅本地聊天/测试可不启动 MySQL（默认 SQLite）；Presence/实时功能需要 Redis。

## 测试

测试使用内存缓存与 InMemory channel layer，**不依赖 Redis/MySQL**：

```bash
python -m pytest
```

覆盖：
- 注册/登录/资料/搜索、JWT 鉴权（未授权 401、越权 403/404）
- 好友申请->同意->列表->删除全链路，双向关系正确性
- Presence WebSocket：合法 token 连接、非法/缺失 token 拒绝、心跳
- 健康检查只读探测

## 配置说明（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEBUG` | true | 生产必须 false |
| `SECRET_KEY` | 开发占位 | 生产必须显式提供 |
| `DB_ENGINE/DB_NAME/...` | SQLite | 生产切 MySQL 8 |
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | channel layer + 缓存 |
| `JWT_ACCESS_MINUTES` | 30 | access 有效期 |
| `JWT_REFRESH_DAYS` | 7 | refresh 有效期 |

密钥只存在于本机 `.env`（Git 忽略），文档与仓库不含真实密钥。

## API 一览（/api/v1）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/auth/register/` | 注册（返回 user + access/refresh） |
| POST | `/auth/login/` | 登录（simplejwt） |
| POST | `/auth/refresh/` | 刷新 |
| GET | `/me/` | 当前用户信息 |
| PATCH | `/me/profile/` | 修改资料 |
| GET | `/users/search/?q=` | 搜索用户 |
| GET/POST | `/friends/requests/` | 待处理申请 / 发起申请 |
| POST | `/friends/requests/<id>/action/` | 同意/拒绝 |
| GET | `/friends/` | 好友列表 |
| DELETE | `/friends/<user_id>/` | 删除好友 |
| GET | `/health/` | 健康检查 |
| GET | `/health/live/` | 存活探针 |

## 验收

- 注册->登录->改资料->搜索->加好友->删除好友全链路通过（见 tests）
- 未授权访问返回 401；越权处理好友申请返回 404
- WS 连接鉴权失败关闭（4401），合法 token 连接 + 心跳正常
- 在线状态由 Redis 承载（心跳续期 + TTL 掉线），隐身用户对外视为离线
