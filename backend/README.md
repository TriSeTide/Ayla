# Elysia 独立应用后端（阶段四 M4-1 基座 + M4-2 聊天核心 + M4-3 媒体 + M4-4 爱莉桥接）

Django 5 + Channels 4 + Redis 的独立应用后端，作为 Elysia Web 前端的唯一 API/WS 入口。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`。

## 当前里程碑

### M4-3 媒体与表情包（已完成）

- [x] `media` 应用：媒体对象（`media_id` 稳定 uuid、`content_hash` sha256、MIME allowlist、
      文件头嗅探、分类型大小上限）+ 受控上传会话（三步上传）
- [x] 受控三步上传：`POST /uploads` 创建会话 → `PUT /uploads/{id}` 传二进制（临时前缀）
      → `POST /uploads/{id}:complete` 校验生成 `media_id`（幂等：同一 upload 重复 complete 返回同一 media_id）
- [x] 完整性与安全：sha256 + size + MIME + 文件头嗅探同时校验；内容去重（同 hash 复用 media_id）；
      只允许已登记 media_id 下载，禁止 path traversal
- [x] 派生与 ready 分离：缩略图（image/emoji，Pillow 等比缩放）与波形（voice WAV，48 段峰值 PNG）
      派生失败不把媒体置 failed，媒体仍 ready，派生单独标记
- [x] 下载：`GET /media/{id}/content`（Range 206/416、ETag、`Cache-Control: private, no-store`）、
      `GET /media/{id}/thumbnail|waveform`（无 → 404）
- [x] 媒体访问控制（工程硬约束）：owner 永远可访问；消息引用（会话成员可访问）；
      表情包（系统包全员/个人包仅 owner）；未授权 403/404 不泄露存在性
- [x] `emoji` 应用：表情包（系统包 owner=None / 个人包）、收藏/取消（`unique(pack, media)` DB 硬约束 +
      services 幂等 201/200）、检索（tag/名称基础匹配）、系统包管理员切换
- [x] 消息链接线（M4-2 复用）：`CreateMessageSerializer` 校验 `type=image/voice/file/emoji` 时
      media 必须存在/ready/类型匹配/有权访问（越权 403）；`MessageSerializer.media` 升级为 descriptor 对象
- [x] 契约测试：上传-完成-下载闭环、幂等、越权 403/404、MIME/大小/嗅探校验、缩略图/波形派生、
      表情包 CRUD、系统包权限、发 emoji 消息
- [x] `manage.py cleanup_media` 清理过期上传会话与孤儿临时对象（手动执行）

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

### M4-4 爱莉桥接（已完成）

- [x] `elysia_bridge` 应用：`ElysiaProfile`（爱莉应用内身份 ↔ Elysium stream_id 唯一映射）
- [x] 阶段三 HTTP 客户端（`elysia_client.py`）：service credential 创建/换 session/refresh、
      inject 入站、命令端点（send/reply 带 Idempotency-Key）、SSE 出站订阅（cursor/history_gap 恢复）
- [x] 入站：应用内用户给爱莉发消息 → `POST /chat/messages:inject` 注入 Elysium 主链
      （带 `sender_id`/`platform="elysia-app"`/`chat_type` 回显来源）
- [x] 出站：`run_bridge` 订阅 `GET /events/stream` → 匹配 stream 的 `chat.message.*`
      投影为应用内消息（幂等键 `elysia-<event_id>`）→ 广播 `elysia.reply`（走 M4-2 Chat WS）
- [x] 出站路由：payload `sender_id`/`correlation_id` 定位会话，匹配不到降级默认会话 + warning
- [x] 断线恢复：SSE `Last-Event-ID`/cursor 补历史，`history_gap` 按 recovery.cursor 重连，心跳不推进 cursor
- [x] 应用内 WS 断线补发复用 M4-2 `last_message_seq`（`resume` 帧）
- [x] 契约测试：inject 入站、SSE 出站投影、profile REST 权限、订阅循环断线/重连/401 恢复、
      主体性边界（应用绝不生成爱莉第一人称内容）

## 目录结构

```text
backend/
├── manage.py
├── pyproject.toml          # uv 依赖管理 + pytest 配置
├── config/                 # settings / asgi / wsgi / urls / settings_test
├── apps/
│   ├── accounts/           # 用户/认证/好友/在线状态（M4-1）
│   ├── chat/               # 私聊/群聊/消息/已读/撤回（M4-2）
│   ├── media/              # 媒体对象/受控三步上传/下载/派生/访问控制（M4-3）
│   ├── emoji/              # 表情包/收藏/检索/系统包（M4-3）
│   └── elysia_bridge/      # 爱莉桥接：profile/inject/SSE 出站/订阅循环（M4-4）
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

仅本地聊天/测试可不启动 MySQL（默认 SQLite）；Presence/实时功能需要 Redis；
媒体上传需要 MinIO/S3（`S3_STORAGE_BACKEND=s3`；测试/离线场景可切 `fake`）。

## 测试

测试使用内存缓存、InMemory channel layer 与内存 FakeStorage，**不依赖 Redis/MySQL/MinIO**：

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
- 媒体（M4-3）：三步上传闭环、complete 幂等（同 upload 同一 media_id）、
  MIME/大小/文件头嗅探校验、缩略图/波形派生、Range 206/416、访问控制
  （owner/消息引用/表情包、未授权 403/404）、media_id/upload_id 唯一约束
- 表情包（M4-3）：系统包/个人包、收藏/取消/重复收藏幂等 201/200、
  非 emoji 拒绝 400、越权收藏 403、系统包全员可见、发 emoji 消息
- Chat WebSocket：合法 token 连接、subscribe 基线、两人互发广播、断线补发、
  非成员订阅忽略/收不到广播、慢消费者不阻塞
- 爱莉桥接（mock Elysium，不依赖真实服务）：
  - `ElysiaProfile` 生命周期/唯一约束/enabled 关闭
  - 凭据流程：创建 secret 只显示一次、换 session、refresh 轮换、撤销 401 恢复
  - inject 入站：合法请求体 + 应用内消息落库、非爱莉会话不注入、缺凭据 ProfileNotConfigured
  - SSE 出站投影：匹配 stream 落库（幂等 `elysia-<event_id>`）+ 广播 `elysia.reply`、
    路由（sender_id/correlation）、降级 + warning、无会话返回 None
  - 订阅循环：断线按 cursor 重连、history_gap 按 recovery.cursor、心跳不推进 cursor、
    401 refresh 恢复、stop 优雅退出
  - profile REST：登录可读、管理员写、越权 403、未初始化 404、`:test` 冒烟 503/200
  - 主体性边界：落库内容 == 投影原文，应用从不伪造爱莉发言

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
| `ELYSIA_BASE_URL` | 空 | 阶段三 Elysium API 根地址（不含 `/api/v1`） |
| `ELYSIA_CREDENTIAL_FILE` | `runtime/elysia_credential.json` | service credential 落盘路径（Git 忽略） |
| `ELYSIA_SSE_RECONNECT_SECONDS` | 3.0 | SSE 断线重连有界退避初始间隔（秒） |
| `ELYSIA_SSE_EVENT_TYPES` | `chat.message` | SSE 订阅事件类型前缀过滤 |
| `S3_STORAGE_BACKEND` | `s3` | 对象存储后端：`s3`=MinIO/S3；`fake`=内存 FakeStorage（仅测试） |
| `S3_ENDPOINT_URL` | `http://127.0.0.1:9000` | MinIO/S3 endpoint |
| `S3_ACCESS_KEY/S3_SECRET_KEY` | `minioadmin` | MinIO/S3 凭据 |
| `S3_BUCKET` | `elysia-media` | 媒体桶（首传时 create_bucket 幂等） |
| `S3_REGION` | `us-east-1` | 区域 |
| `S3_PUBLIC` | false | 对对象加 public-read ACL（默认 false：私密媒体禁止进共享缓存） |
| `MEDIA_MAX_IMAGE_BYTES` | 10485760 | 图片大小上限（10MB） |
| `MEDIA_MAX_VOICE_BYTES` | 31457280 | 语音上限（30MB） |
| `MEDIA_MAX_FILE_BYTES` | 52428800 | 文件上限（50MB） |
| `MEDIA_MAX_EMOJI_BYTES` | 5242880 | 表情上限（5MB） |
| `MEDIA_TMP_TTL_SECONDS` | 600 | 上传临时会话 TTL（秒） |
| `MEDIA_THUMB_MAX` | 320 | 缩略图最大边长（px） |

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

### 媒体（M4-3，`/api/v1/media/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| POST | `/media/uploads` | 创建受控上传会话 `{kind, expected_size, mime_type}` | 登录 |
| PUT | `/media/uploads/<upload_id>` | 传二进制（body 原始字节，落到临时前缀） | 会话 owner |
| POST | `/media/uploads/<upload_id>:complete` | 校验并生成 `media_id`（幂等） | 会话 owner |
| GET | `/media/<media_id>` | 媒体 descriptor + 处理状态 | 有访问权 |
| GET | `/media/<media_id>/content` | 原对象下载（Range 206/416、ETag、private no-store） | 有访问权 |
| GET | `/media/<media_id>/thumbnail` | 缩略图（image/emoji） | 有访问权 |
| GET | `/media/<media_id>/waveform` | 波形图（voice WAV） | 有访问权 |
| POST | `/media/<media_id>:save` | 爱莉媒体投影通道预留（本期 501） | 有访问权 |

**媒体 descriptor**：`media_id, kind, mime_type, size, status, width, height, duration, thumbnail, waveform, created_at`（不暴露 `storage_path`）。

**访问控制**：owner 永远可访问；消息引用（media 被某条消息引用，且调用方是该会话成员）；
表情包（系统包全员/本人个人包）；其余未授权 403/404，不泄露存在性。

**消息 `media` 字段（M4-2 契约升级）**：`MessageSerializer.media` 从字符串 `media_id` 升级为
descriptor 对象（`media_id` 引用不存在时仍为 null）；发媒体消息（type=image/voice/file/emoji）
必须携带已存在、ready、类型匹配且调用方有权访问的 `media_id`，越权返回 403 `media_access_denied`。

### 表情包（M4-3，`/api/v1/emoji/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/emoji/packs/` | 我的个人包 + 系统包 | 登录 |
| POST | `/emoji/packs/` | 建个人包 `{name}`（同名幂等复用） | 登录 |
| GET | `/emoji/packs/<pack_id>/items/` | 包内表情列表 | 包 owner 或系统包 |
| POST | `/emoji/packs/<pack_id>/items/` | 收藏 `{media_id, tag?}`（重复收藏幂等 200） | 包 owner |
| DELETE | `/emoji/packs/<pack_id>/items/<item_id>/` | 取消收藏 | 包 owner |
| POST | `/emoji/search/` | 按 tag/名称检索 `{keyword}` | 登录 |
| POST | `/emoji/packs/<pack_id>/set_system/` | 切换系统包 `{is_system}` | 系统管理员 |

### Chat WebSocket（`/ws/chat/?token=<jwt>`）

- 连接后发 `subscribe` 帧订阅会话组，收到 `chat.subscribed` 基线（含会话当前最大 seq）；
- 重连后发 `resume` 帧（`{conversation_id, last_message_seq}`），服务端补发 `seq > last_message_seq`
  的消息，最后发 `history.sync`（含最新 `last_seq`）；
- 事件帧：`message.new / message.recall / message.read / typing`，`sender_id` 由前端过滤；
- 慢消费者（`ChannelFull`）被服务层捕获记 warning，不阻塞其他成员；
- 心跳 `ping` -> `pong`。

### 爱莉桥接（M4-4，`/api/v1/elysia/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/elysia/profile/` | 读取当前爱莉 profile（应用级单例） | 登录 |
| POST | `/elysia/profile/` | 初始化（绑定 user + stream_id） | 系统管理员 |
| PATCH/PUT | `/elysia/profile/` | 更新 enabled/display_name/chat_type/platform | 系统管理员 |
| POST | `/elysia/profile/:test` | 连接冒烟（验证凭据/session，不真正 inject） | 系统管理员 |

**爱莉聊天闭环（入站/出站）**：

1. **入站**：用户与爱莉私聊（爱莉是一个真实 `User`，可被搜索/私聊/@/加群）→
   应用内消息落库（M4-2 `create_message`）→ `on_user_message_to_elysia` 判断该会话含爱莉
   profile → `POST /api/v1/chat/messages:inject` 注入 Elysium 主链（带 `sender_id` 回显，
   `platform="elysia-app"`）。inject 失败不阻塞/回滚用户消息（视图层 try/except + 日志）。
2. **出站**：`python manage.py run_bridge` 订阅 `GET /api/v1/events/stream`，按
   `event_type=chat.message.*` + `stream_id` 匹配 → 从 payload 回显 `sender_id`/`correlation_id`
   定位应用内会话 → `create_message`（sender=爱莉 user，`idempotency_key=elysia-<event_id>` 幂等）
   → 广播 `elysia.reply`（走 M4-2 Chat WS，消费者处理器 `elysia_reply`）。
3. **断线恢复**：SSE 断线按最后 cursor（`Last-Event-ID`）补历史；`history_gap` 错误帧按
   `recovery.cursor` 重连；应用内 WS 断线复用 `resume`/`last_message_seq` 补发。

**出站路由降级**：payload 无法回显 `sender_id`/`correlation` 时，降级到爱莉 profile 的
最近私聊会话 + warning（不静默丢弃，见失败路径留日志）；无任何私聊会话则返回 None。

### 已知取舍（M4-4）

- **首期以 SSE 投影为"爱莉已回复"依据**：SSE 出现 `chat.message.*` 即投影落库广播；
  `delivery_confirmed` 回执链路本期不做（记录取舍，后续可补）。
- **命令端点 send/reply 已打通链路但非主路径**：`elysia_client` 实现且契约测试覆盖
  （凭据/scope/幂等键/结果解析）；因 `elysia-app` 平台在阶段三 `ProviderFacadeRegistry`
  无真实 facade，真实发送会 `capability_disabled`，故主路径是 SSE 投影。
- **出站来源回显是最大未决点**：inject 注入的消息无 `reply_target`，爱莉回复能否可靠回显
  `sender_id` 需真实 E2E 验证；不能则需与阶段三协调补契约（公共契约缺陷先说明再动）。
- **`display_name`/`chat_type`/`created_at` 为补充字段**（开发文档 §4 未列，接口驱动补充，已注明）。
- **SSE 订阅单 owner**：多应用实例需 Redis 锁占位，本期单实例即可。
- **凭据安全**：secret 一次性落盘本机 `runtime/`（Git 忽略），token 只存内存，重启用 secret 重换。

### 已知取舍（M4-2）

- `seq` 并发冲突：事务内 `Max(seq)+1` + `unique(conversation, seq)` 兜底，冲突重试一次，仍冲突抛异常（README 记录）；
- reaction 本期只做事件帧占位，不建表；
- @提及：内容里保留 `@昵称` 文本，不做独立 at 表/提醒；
- 群聊已读：记录 `MessageRead`，不广播群聊已读聚合（避免噪声）；
- `announcement` 字段为补加字段，与开发文档数据模型略有出入（已在 `models.py` 注明）；
- `media_id` 校验在 M4-3 接通：类型=image/voice/file/emoji 时必须存在/ready/类型匹配/有权访问（M4-2 仅预留不校验）。

### 已知取舍（M4-3）

- **补充字段**：`MediaObject.kind/width/height/duration/thumbnail_path/waveform_path` 与
  `MediaUploadSession.expires_at/media_id` 为接口驱动补充（descriptor/幂等锚点所需），核心字段与开发文档一致；
- **派生尽力而为**：缩略图/波形在 `:complete` 同一请求内生成，失败只记 warning、媒体仍 ready；
  波形仅支持 WAV（PCM16）；其他语音格式可上传但无波形。
- **文件类型不做魔数强校验**：`kind=file` 任意 allowlist 内 MIME 均可（至少要有内容）；
  image/emoji 必须有位图魔数（PNG/JPEG/GIF/WebP）；voice 除 WAV/MP3/Ogg 外交由 MIME 判断。
- **去重复用 media_id**：同 `content_hash` 复用既有 media_id（不改变 owner 语义），首次上传方持原对象；
- **`media_id:save` 为预留通道**：爱莉媒体投影（应用只渲染/投影，不生成爱莉第一人称内容，AGENTS.md §4.1）本期 501；
- **清理为手动命令**：`manage.py cleanup_media` 清理过期会话与孤儿临时对象，未接入定时任务；
- **缩略图质量**：JPEG 白底 quality=80、长边压缩到 `MEDIA_THUMB_MAX`，适合浅色聊天场景。

## 验收

- 注册->登录->改资料->搜索->加好友->删除好友全链路通过（见 tests）
- 未授权访问返回 401；越权处理好友申请返回 404
- WS 连接鉴权失败关闭（4401），合法 token 连接 + 心跳正常
- 在线状态由 Redis 承载（心跳续期 + TTL 掉线），隐身用户对外视为离线
- 聊天：两人私聊、群聊、消息幂等、越权 403/404、WS 连接/重连/补发契约测试全绿
