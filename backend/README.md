# Elysia 独立应用后端（阶段四 M4-1 基座 + M4-2 聊天核心）

Django 5 + Channels 4 + Redis 的独立应用后端，作为 Elysia Web 前端的唯一 API/WS 入口。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`。

## 当前里程碑

### M4-1 基座（已完成）

- [x] Django 5 + Channels 4 ASGI 骨架（daphne 承载）
- [x] `accounts` 应用：用户模型（AbstractUser + uuid id）、JWT（simplejwt）、
      注册/登录/资料/搜索、好友申请/同意/拒绝/删除、Redis 在线状态
- [x] Presence WebSocket（`/ws/presence/?token=<jwt>`）+ 心跳
- [x] 健康检查（`/api/v1/health/`、`/api/v1/health/live/`）
- [x] Docker Compose（MySQL 8 / Redis 7 / MinIO）+ 契约测试

### M4-2 聊天核心（已完成）

- [x] `chat` 应用：私聊/群聊会话、会话成员（角色/禁言）、消息（文本/图片/语音/文件/表情/引用/@）、
      已读回执、撤回（限时）
- [x] 私聊 REST + 群聊 REST + 群管理（建群/退群/成员/公告/群主管理员）
- [x] 应用内 Chat WebSocket（`/ws/chat/?token=<jwt>`）：`message.new/recall/read`、`typing`、
      断线补发（`last_message_seq`）、慢消费者不阻塞
- [x] 消息幂等（`idempotency_key`）、离线消息上线补发
- [x] 契约测试：两人私聊、群聊、幂等、越权 403/404、WS 连接/重连/补发

## 目录结构

```text
backend/
├── manage.py
├── pyproject.toml          # uv 依赖管理 + pytest 配置
├── config/                 # settings / asgi / wsgi / urls / settings_test
├── apps/
│   ├── accounts/           # 用户/认证/好友/在线状态（M4-1）
│   ├── chat/               # 私聊/群聊/消息/已读/撤回（M4-2）
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
- 聊天：私聊幂等创建、消息幂等（同 key 200 原消息 / 不同内容 409）、seq 单调、
  撤回限时、已读回执、群管理、禁言、越权 403/404
- Chat WebSocket：合法 token 连接、subscribe 基线、两人互发广播、断线补发、
  非成员订阅忽略/收不到广播、慢消费者不阻塞

## 配置说明（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DEBUG` | true | 生产必须 false |
| `SECRET_KEY` | 开发占位 | 生产必须显式提供 |
| `DB_ENGINE/DB_NAME/...` | SQLite | 生产切 MySQL 8 |
| `REDIS_URL` | `redis://127.0.0.1:6379/0` | channel layer + 缓存 |
| `JWT_ACCESS_MINUTES` | 30 | access 有效期 |
| `JWT_REFRESH_DAYS` | 7 | refresh 有效期 |
| `MESSAGE_RECALL_SECONDS` | 120 | 消息撤回限时窗口（秒） |

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

### 聊天（M4-2，`/api/v1/chat/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/conversations/` | 当前用户会话列表（含未读数、对方信息/群标题） | 登录 |
| POST | `/conversations/private/` | body `{user_id}` 开启/获取私聊会话 | 登录 |
| POST | `/conversations/group/` | 建群 `{title, member_ids[]}` | 登录 |
| GET | `/conversations/<id>/` | 会话详情（成员 + 我的角色） | 会话成员 |
| PATCH | `/conversations/<id>/` | 改群标题/公告 `{title?, announcement?}` | 群管理员 |
| GET | `/conversations/<id>/messages/?before_seq=&limit=` | 历史分页（seq 游标） | 会话成员 |
| POST | `/conversations/<id>/messages/` | 发消息（幂等） | 会话成员（禁言 403） |
| POST | `/conversations/<id>/messages/<mid>/read/` | 标已读 | 会话成员 |
| POST | `/conversations/<id>/messages/<mid>/recall/` | 撤回（限时，仅发送者） | 发送者 |
| POST | `/conversations/<id>/typing/` | 声明正在输入 | 会话成员 |
| POST | `/conversations/<id>/members/` | 加人 `{user_ids[]}` | 群管理员 |
| DELETE | `/conversations/<id>/members/<user_id>/` | 踢人 | 群管理员（群主不能踢自己） |
| POST | `/conversations/<id>/members/<user_id>/mute/` | 禁言/解除 `{muted: bool}` | 群管理员 |

**消息序列化**：`id(str), conversation_id(str), sender_id(str), type, content, media_id, reply_to(id 或 null), status, seq, created_at`。
**会话序列化**：`id(str), type, title, owner_id, members[], my_role, member_count, unread_count, created_at`。

### 消息幂等语义（9.1 验收）

- 同 `idempotency_key` + 同会话重复 POST：返回 200 + 原消息（不重复落库）；
- 同 key 但内容不同：返回 409 Conflict；不同会话复用同 key：同样 409。
- `idempotency_key` 为全局唯一索引（`unique=True`），是 M4-4 爱莉桥接幂等契约的地基。

### Chat WebSocket（`/ws/chat/?token=<jwt>`）

- 连接后发 `subscribe` 帧订阅会话组，收到 `chat.subscribed` 基线（含会话当前最大 seq）；
- 重连后发 `resume` 帧（`{conversation_id, last_message_seq}`），服务端补发 `seq > last_message_seq`
  的消息，最后发 `history.sync`（含最新 `last_seq`）；
- 事件帧：`message.new / message.recall / message.read / typing`，`sender_id` 由前端过滤；
- 慢消费者（`ChannelFull`）被服务层捕获记 warning，不阻塞其他成员；
- 心跳 `ping` -> `pong`。

### 已知取舍（M4-2）

- `seq` 并发冲突：事务内 `Max(seq)+1` + `unique(conversation, seq)` 兜底，冲突重试一次，仍冲突抛异常（README 记录）；
- reaction 本期只做事件帧占位，不建表；
- @提及：内容里保留 `@昵称` 文本，不做独立 at 表/提醒；
- 群聊已读：记录 `MessageRead`，不广播群聊已读聚合（避免噪声）；
- `announcement` 字段为补加字段，与开发文档数据模型略有出入（已在 `models.py` 注明）；
- `media_id` 为 M4-3 预留，本期不校验对象存储。

## 验收

- 注册->登录->改资料->搜索->加好友->删除好友全链路通过（见 tests）
- 未授权访问返回 401；越权处理好友申请返回 404
- WS 连接鉴权失败关闭（4401），合法 token 连接 + 心跳正常
- 在线状态由 Redis 承载（心跳续期 + TTL 掉线），隐身用户对外视为离线
- 聊天：两人私聊、群聊、消息幂等、越权 403/404、WS 连接/重连/补发契约测试全绿
