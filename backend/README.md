# Elysia 独立应用后端（阶段四 M4-1 基座 + M4-2 聊天核心 + M4-3 媒体 + M4-4 爱莉桥接 + M4-5 语音 + M4-6 直播）

Django 5 + Channels 4 + Redis 的独立应用后端，作为 Elysia Web 前端的唯一 API/WS 入口。

> 架构与里程碑见 `../docs/plans/阶段四-Elysia多媒体独立应用开发文档.md`。

## 当前里程碑

### M4-6 直播（契约测试通过，端到端未验收）

- [x] `live` 应用：直播频道（LiveChannel）+ 弹幕（Danmaku）
- [x] SRS 集成（`srs.py`）：HTTP API 状态查询（`SrsClient` 短超时 + `FakeSrsClient` 测试注入）；
      `docker-compose.yml` 追加 `srs` 服务（`ossrs/srs:5`，1935/8080/1985/8000udp）
- [x] 频道 REST（`/api/v1/live/`）：创建/列表/详情/删除、`:start`/`:stop`（乐观标记）、
      `/status`（**SRS 实时判定**，失败返回 `degraded` 不伪装"未在播"）
- [x] `stream_key` 安全指纹：`secrets.token_hex(24)` 唯一索引；创建响应回显一次，
      此后仅 owner 详情可见，非 owner 一律 null（推流指纹绝不外泄给观众）
- [x] 弹幕：POST 落库 + `live_{id}` 组广播（复用 M4-5 voice.state 模式，落库与广播分离）、
      历史分页（默认 50、上限 200）
- [x] `DanmakuConsumer` WS（`/ws/live/{channel_id}/?token=<jwt>`）：JWT 认证、直播间不存在关闭
- [x] 配置接线：`SRS_*` / `LIVE_*` 环境变量；`.env.example` 同步；`config/urls.py`/`asgi.py` 接线
- [ ] 真实冒烟（OBS/ffmpeg 推流 → /status live → 拉 HLS/FLV → 弹幕 WS 实时）——
      **未验收**（需 SRS 运行 + 推流工具，见 docs/plans/阶段四-M4-6直播开发步骤.md §8.2）
- [ ] 爱莉直播真实对接（FR-19）——**不验收**（依赖阶段三 `/livestream/*` 契约复核 +
      Elysium 直播意识接入，属未决点，见文档 §6.3）

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

### M4-5 语音（契约层完成，端到端未验收）

- [x] `voice` 应用：语音频道（Discord 风格）+ 频道成员（presence 心跳持久化）
- [x] LiveKit 集成（`livekit.py`）：`AccessToken` + `VideoGrants` 签发（identity/room/grants/TTL），
      无配置时显式失败（不生成裸 token）
- [x] 频道 REST（`/api/v1/voice/`）：列表/详情/建/改名称（仅 owner）/加入（返回 LiveKit token）/离开/心跳/成员
- [x] `voice.state` 广播：频道组 `voice_chan_{id}`（独立于会话组 `chat_conv_{id}`），
      组广播捕获 ChannelFull 不阻塞慢消费者
- [x] `VoiceConsumer` WS（`/ws/voice/?token=<jwt>`）：成员校验后订阅频道组收 `voice.state`
- [x] presence 超时：超过 `VOICE_MEMBER_TIMEOUT_SECONDS` 未心跳的成员标记离开 + 广播（后台任务契约）
- [x] 配置接线：`LIVEKIT_*` / `VOICE_*` 环境变量；`docker-compose.yml` 追加 livekit 服务
- [ ] 爱莉 Voice Live 桥接（`elysia_bridge` 扩展，M4-5 第 1.2 节）：控制面桥接 + 转写/状态投影 + 文本双向注入 ——
      **待实施**（依赖阶段三 voice-calls 挂载 + 真实 credential 验收）
- [ ] 端到端验收：真人语音频道 P95<500ms / 爱莉入会闭环 —— **未验收**（需 LiveKit 运行 + Elysium 运行）

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
│   ├── elysia_bridge/      # 爱莉桥接：profile/inject/SSE 出站/订阅循环（M4-4）
│   ├── voice/              # 语音频道：LiveKit 集成 + voice.state 广播（M4-5）
│   └── live/               # 直播：SRS 集成 + 频道/弹幕 REST + 弹幕 WS（M4-6）
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

# 2) 一键启动后端（runserver + 内嵌 SSE 出站投影，Ctrl+C 一并退出）
python launcher.py                      # 默认 127.0.0.1:8100
# AYLA_HOST=0.0.0.0 AYLA_PORT=8000 python launcher.py   # 自定义地址/端口
```

Windows 可双击仓库根目录 `start_ayla.bat`（等价于 `python launcher.py`）。

`launcher.py` 是 runserver 进程的 owner；**run_bridge（SSE 出站投影）已内嵌**
到 Ayla 后端进程（`apps/elysia_bridge/apps.py::ready()` 启动 daemon 线程，
单实例文件锁 `runtime/elysia_bridge.lock` 防 reload/多 worker 双启），无需
第二个进程。`ELYSIA_BRIDGE_INLINE`（默认 True）控制开关。启动前检查端口
占用（被占用则报告 PID 并拒绝，不启动第二实例）；`runserver` 默认
`--noreload`，代码改动后重启 launcher 生效。

等价拆分启动（调试/排障用）：

```bash
ELYSIA_BRIDGE_INLINE=False python manage.py runserver 127.0.0.1:8100 --noreload  # 仅后端 API / WS
python manage.py run_bridge                                                        # 仅 SSE 出站投影
```

生产部署：`daphne -b 0.0.0.0 -p 8000 config.asgi:application`，内嵌 bridge
随进程启动（`ELYSIA_BRIDGE_INLINE=True`，文件锁保证单实例）；前端由 Nginx
反代，WS 需带升级头（见开发文档 10 节）。

## 基础设施（MySQL/Redis/MinIO/LiveKit/SRS）

```bash
docker compose -f ../docker-compose.yml up -d
```

仅本地聊天/测试可不启动 MySQL（默认 SQLite）；Presence/实时功能需要 Redis；
媒体上传需要 MinIO/S3（`S3_STORAGE_BACKEND=s3`；测试/离线场景可切 `fake`）；
语音频道（M4-5）需要 LiveKit（`elysia-livekit`，端口 7880/7881）；
直播（M4-6）需要 SRS（`elysia-srs`，端口 1935 RTMP / 8080 HTTP-FLV/HLS / 1985 HTTP API）。
SRS 使用默认配置（RTMP + HTTP-FLV + HLS + WebRTC 已内置），无需自定义 conf。

LiveKit key/secret：docker 首启 `--dev` 模式自动生成并打印到容器日志；
生产用 `livekit-server generate-keys` 预生成后写入 `backend/.env` 的
`LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`（**不提交仓库**）。

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
- 语音频道（mock LiveKit，不依赖真实 LiveKit）：
  - 频道模型：`room_name` 唯一、成员 `(channel, user)` 唯一、owner 语义
  - LiveKit token：identity/room/grants/TTL 正确；无配置显式失败
  - 频道 REST：建/查/改（仅 owner）/加入（token）/离开/心跳/成员；越权 403/404、未登录 401
  - `voice.state` 广播：订阅频道组收到 join/left/heartbeat；非成员不订阅
  - presence 超时：超过 `VOICE_MEMBER_TIMEOUT_SECONDS` 未心跳 → 标记离开 + 广播
- 直播（mock SRS，不依赖真实 SRS）：
  - 频道模型：`stream_key` 唯一（DB 硬约束）、status choices、弹幕落库/级联删除
  - SRS 客户端：响应解析、`is_streaming` 判定、非 200/网络错误/坏 payload → `SrsUnavailable`
    （不伪装"未在播"）、FakeSrsClient 注入
  - 频道 REST：创建（201 返回 stream_key/rtmp/hls/flv）、stream_key 最小权限（非 owner null）、
    列表/`?only_live=1`/详情/删除（非 owner 403、直播中 400）、`:start`/`:stop` 状态流转
  - `/status` SRS 判定：在播→live、未在播→idle、查询失败→degraded（不伪装结果）
  - 弹幕：POST 落库 + 广播 `live_{id}` 组（RecordingLayer 断言组名/帧）、历史分页（默认 50 上限 200）、
    空/超长 400、频道不存在 404、未登录 401
  - 弹幕 WS：JWT 认证收广播帧、无 token/非法 token 关闭、直播间不存在关闭

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
| `LIVEKIT_API_KEY` | 空 | LiveKit API key（本机配置，不提交仓库） |
| `LIVEKIT_API_SECRET` | 空 | LiveKit API secret（本机配置，不提交仓库） |
| `LIVEKIT_WS_URL` | `ws://127.0.0.1:7880` | 前端连接 LiveKit 的 WS 地址 |
| `LIVEKIT_TOKEN_TTL_SECONDS` | 600 | 访问 token 有效期（秒），前端过期前重签 |
| `VOICE_MEMBER_TIMEOUT_SECONDS` | 120 | presence 心跳超时（秒），超过标记离开 |
| `SRS_API_URL` | `http://127.0.0.1:1985` | SRS HTTP API 根（状态查询/健康检查） |
| `SRS_RTMP_URL` | `rtmp://127.0.0.1:1935/live` | RTMP 推流地址前缀（stream_key 拼其后，仅 owner 可见） |
| `SRS_PLAY_URL` | `http://127.0.0.1:8080/live` | HTTP-FLV/HLS 播放地址前缀 |
| `SRS_QUERY_TIMEOUT` | 2.0 | SRS 状态查询超时（秒） |
| `LIVE_DANMAKU_HISTORY_LIMIT` | 50 | 新进直播间历史弹幕条数 |

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

### 语音频道（M4-5，`/api/v1/voice/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/channels/` | 频道列表（含人数、我的状态） | 登录 |
| POST | `/channels/` | 建频道 `{name}`（自动生成 `room_name`） | 登录 |
| GET | `/channels/<id>/` | 频道详情（成员数 + 我的状态） | 登录 |
| PATCH | `/channels/<id>/` | 改名称 `{name}`（`room_name` 不可改） | 频道 owner |
| POST | `/channels/<id>/join/` | 加入（落成员表 + 广播 `voice.state` + 返回 LiveKit token） | 登录 |
| POST | `/channels/<id>/leave/` | 离开（删成员 + 广播 `voice.state`） | 成员 |
| POST | `/channels/<id>/heartbeat/` | presence 心跳（刷新 `last_seen_at`） | 成员 |
| GET | `/channels/<id>/members/` | 当前成员列表 | 登录 |

**加入流程**：`POST /join/` → 校验登录 → 写成员表 → 签发 LiveKit token（绑定该用户 + 该房间）
→ 返回 `{channel_id, room_name, token, ws_url, ttl}`。LiveKit 未配置时返回 503（不伪造 token）。

**`voice.state` 事件**（走 `VoiceConsumer`，`/ws/voice/?token=<jwt>`，订阅 `voice_chan_{id}` 组）：

```json
{
  "type": "voice.state",
  "data": { "channel_id": "3", "user_id": "a5bdf36b...", "state": "joined|left|muted|unmuted|heartbeat", "ts": "..." }
}
```

`joined/left/heartbeat` 由成员表变更广播；`muted/unmuted` 由客户端静音时上报（元数据层，不落库强制）。
`voice.state` 只表达**技术状态**，不是爱莉/用户的情绪判断。

### 直播（M4-6，`/api/v1/live/`）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | `/channels/` | 频道列表（含乐观 status；`?only_live=1` 只返回 status=live） | 登录 |
| POST | `/channels/` | 创建频道 `{title}` → 201 返回 `stream_key`/推流/播放地址 | 登录 |
| GET | `/channels/<id>/` | 频道详情：owner 可见 `stream_key`+推流地址；他人仅播放地址+状态 | 登录 |
| POST | `/channels/<id>:start/` | 开播（乐观标记：status→live、started_at=now；不校验 SRS 真实流） | 频道 owner |
| POST | `/channels/<id>:stop/` | 下播（乐观标记：status→ended、ended_at=now） | 频道 owner |
| GET | `/channels/<id>/status/` | **SRS 实时判定**：在播→`live` / 未在播→`idle` / SRS 不可用→`degraded` | 登录 |
| DELETE | `/channels/<id>/` | 删除频道（直播中禁止，先 `:stop`） | 频道 owner |
| POST | `/channels/<id>/danmaku/` | 发弹幕 `{content}`（≤200）→ 落库 + 广播 `live_{id}` 组 | 登录 |
| GET | `/channels/<id>/danmaku/?limit=` | 最近弹幕历史（默认 50，上限 200） | 登录 |

**SRS 地址格式**（stream_key 是推流握手指纹，**仅 owner 可见，绝不外泄给观众**）：

| 用途 | 协议 | 地址 |
|---|---|---|
| 推流（OBS/ffmpeg） | RTMP | `rtmp://<host>:1935/live/{stream_key}` |
| 播放 | HTTP-FLV | `http://<host>:8080/live/{stream_key}.flv` |
| 播放 | HLS | `http://<host>:8080/live/{stream_key}.m3u8` |
| 状态查询 | HTTP API | `GET http://<host>:1985/api/v1/streams` |

```bash
# 推流示例（OBS 用自定义流：rtmp://127.0.0.1:1935/live + 流密钥 = stream_key）
ffmpeg -re -i <源> -c copy -f flv rtmp://127.0.0.1:1935/live/{stream_key}
```

**状态语义（AGENTS.md §8 状态真实性）**：应用侧 `status` 是乐观标记（`:start`/`:stop`
更新）；`/status` 以 SRS HTTP API 实时判定为准。SRS 查询失败（超时/网络/非 200）返回
`{"status": "degraded", "detail": "srs_unavailable"}`，**禁止把查询失败伪装成"未在播"**。

**弹幕 WS（`/ws/live/{channel_id}/?token=<jwt>`）**：连接即校验直播间存在（不存在关闭），
加入 `live_{id}` 组收弹幕实时帧：

```json
{ "type": "danmaku", "id": "1", "channel_id": "3",
  "sender": { "user_id": "...", "nickname": "...", "avatar": "" },
  "content": "大家好", "created_at": "..." }
```

弹幕内容原样转发，应用不代判内容意义（审核/过滤属 Elysium 侧能力，AGENTS.md §2）。

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

### 已知取舍（M4-5）

- **真人 ↔ 爱莉实时双向音频互通是最大未决点**（开发文档 §11 风险表第三行）：LiveKit 是
  WebRTC（真人多人频道），Voice Live 是浏览器 ↔ Elysium 的 WebSocket + PCM16（一对一，
  `max_concurrent_sessions=1`），两套媒体传输不能简单翻译；本期只打通**控制面 + 转写/文本**闭环，
  实时双向音频需 Elysium 侧新增媒体网关契约（公共契约缺陷，先说明再动）。
- **Voice Live 单并发**：同一时刻只能一个爱莉 Voice Live 通话；多人频道同时要与爱莉语音需排队/限制
  （本期允许爱莉频道一个活跃通话）。
- **爱莉 Voice Live 桥接未实施**（第 1.2 节）：控制面 REST / observer 转写投影 / 文本注入属
  `elysia_bridge` 扩展，依赖阶段三 `plugins/voice_live` 挂载 + 真实 credential 验收，本期 README 如实标注。
- **`VoiceChannelMember` / `last_seen_at` 为补充表/字段**（开发文档 §4 只有 `voice_channels`，
  需求 FR-13/16 需要成员持久化）；`last_seen_at` 用于 presence 超时判定。
- **频道开放加入**：默认类似 Discord 语音频道，邀请制/私有频道留待后续。
- **LiveKit 密钥安全**：API key/secret 走本机配置（Git 忽略），token 只签给登录用户 + 绑定房间。

### 已知取舍（M4-6）

- **状态真实性以 SRS 为准**：应用侧 `status` 是乐观标记；`/status` 以 SRS HTTP API 实时判定，
  查询失败返回 `degraded` 不伪装结果；未来可加定时对账（本期不做）。
- **`stream_key` 安全**：`secrets.token_hex(24)` 唯一索引；创建响应一次回显、仅 owner 详情可见；
  泄漏风险（截图/日志）需注意，未来可支持重发/轮换 key（本期不做）。
- **`LiveChannel` 为补充表**（开发文档 §4 直播域未给表结构，按 FR-17/18 补充）：
  `stream_key`/`status`/`started_at`/`ended_at` 是直播频道最小必要组成；核心语义与 FR-17 对齐。
- **HLS 延迟 5-15s 可接受**（需求 §4.1）；WebRTC <500ms 可选，本期不验收。
- **不转码不录制**：OBS 推流侧编码，SRS 不做转码/录制落盘；录制/回放归后续里程碑。
- **在线人数精确计数**：可选（channels group 连接数），本期不做 UI 层计数。
- **弹幕不做内容过滤**：审核/过滤属 Elysium 侧能力，应用只落库广播。
- **爱莉直播真实对接未做**（FR-19）：依赖阶段三 `/livestream/*` 契约复核 + Elysium 直播意识接入
  （voice_live/livestream 场景意识闭环是 Elysium 侧工作），本期通道预留不验收。

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
