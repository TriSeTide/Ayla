# 媒体存储过期方案（聊天媒体分级过期）

> 状态：已定稿（2026-09-10，用户拍板；2026-09-10 修订：语音/文件/视频改为单级 7 天直接删除，四种媒体 TTL 全部进配置项）
> 适用范围：Ayla 后端 `apps/media` + 前端媒体加载链路
> 关联文档：`docs/媒体预签名直传与播放架构-2026-08-24.md`、`backend/apps/media/storage.py`

## 1. 背景与目标

Ayla 媒体（图片/视频/语音/文件）全部存 MinIO（bucket `elysia-media`），当前无任何过期机制，正式媒体永久累积。经讨论确定：

- **普通文本消息**（MySQL）：永久保留，零回收（年增量 ~GB 级，无压力）；
- **聊天媒体**（MinIO）：按 kind 分级过期——图片两级（7 天删原图留缩略图、30 天完全过期），语音/文件/视频单级（7 天直接删除）；
- **资产类媒体**（帖子配图/表情包/评论/群头像等）：永久保留；
- **不设空间硬上限**（不做 bucket quota 硬拒）。

设计原则：**云端回收 ≠ 数据销毁**。删除只动 MinIO 对象与 DB 标记，客户端本地缓存不受影响（未来 app 本地为主、云端漫游的架构兼容）。

## 2. 保留策略总览

| 类别 | 引用方 | 策略 |
|---|---|---|
| 永久保留 | 帖子配图 `PostImage.media`（FK） | 内容沉淀，帖子可被收藏 |
| 永久保留 | 表情包 `EmojiItem.media`（FK） | 用户资产 |
| 永久保留 | 帖子评论 `Comment.media_id` / `Comment.images`（JSON） | 帖子内容 |
| 永久保留 | 群头像 `Conversation.avatar`（content URL 字符串） | 群设置 |
| 可过期（图片，两级） | 聊天消息 `Message.media_id` / `Message.segments`（JSON） | 7 天删原图留缩略图、30 天完全过期 |
| 可过期（语音/文件/视频，单级） | 聊天消息 `Message.media_id` / `Message.segments`（JSON） | 7 天直接删除（无缩略图阶段） |
| 可过期（语音/文件/视频，单级） | 直播弹幕 `Danmaku.media_id` | 7 天直接删除 |
| 可过期（语音/文件/视频，单级） | 语音房消息 `VoiceChatMessage.media_id` | 7 天直接删除 |
| 可过期 | 无任何引用的孤儿媒体 | 按 kind 对应策略 |

> 弹幕/语音房消息归入可过期类：与聊天消息语义一致（瞬态对话），量小但策略统一。
> 如需调整（如弹幕永久），改判定集合即可，不影响机制。
> 语音/文件/视频无缩略图阶段（语音波形、视频海报帧随本体一并删除），
> 到期即完全过期；图片有缩略图，故保留两级窗口。

## 3. 判定规则

**一个媒体只要被任何"永久保留"类引用，就永不过期**；否则（仅被聊天类引用，或无引用）进入过期流程。

判定实现（清理命令内）：

```
候选集合 = MediaObject.objects.filter(
    created_at < now - 该 kind 的有效 TTL,
    status=STATUS_READY,
    expired_at__isnull=True,          # 未完全过期
)
保护集合 = 被以下引用的 media_id 集合：
    PostImage.media_id
    EmojiItem.media_id
    Comment.media_id + Comment.images（JSON 数组）
    Conversation.avatar（解析 content URL 中的 media_id）
可过期 = 候选集合 - 保护集合
```

注意：

- `Conversation.avatar` 存的是 `/api/v1/media/{id}/content` 形式 URL，需解析出 media_id 再比对；
- `Message.segments` 为 JSON 数组，段元素 `{"type": "image"|"video", "media_id": "..."}`，需遍历提取；
- 判定必须**全量扫描保护类引用**，漏判会导致资产类媒体被误删——这是本方案最高风险点，测试必须覆盖。

## 4. 过期流程（按 kind 分派）

以 `MediaObject.created_at` 为基准（上传即发消息，created_at ≈ 消息时间）：

### 图片：两级

### 阶段 1：7 天 —— 删原图，留缩略图

- 删除 MinIO 对象 `storage_path`（original）；
- **保留** `thumbnail_path`、`waveform_path` 对象；
- DB 记录 `original_expired_at = now`；
- 前端效果：聊天气泡显示缩略图 + "原图已过期"提示，点开不再有原图。

### 阶段 2：30 天 —— 完全过期

- 删除 MinIO 对象 `thumbnail_path`、`waveform_path`；
- DB 记录 `expired_at = now`（**记录保留，不删行**）；
- 前端效果：显示"已过期"占位。

### 语音/文件/视频：单级（默认 7 天）

- 到期直接删除全部对象（`storage_path` + `thumbnail_path` + `waveform_path`）；
- DB 记录 `expired_at = now`（**记录保留，不删行**；`original_expired_at` 保持 null）；
- 前端效果：显示"已过期"占位（无缩略图降级阶段）。

**DB 记录必须保留**，原因：

1. `PostImage`/`EmojiItem` 是 FK 强引用，删行会违反外键约束（或级联误删资产引用）；
2. 前端需要区分"已过期"（有记录）与"不存在"（无记录）；
3. 审计可追溯：过期是显式状态，不是消失。

## 5. 数据模型变更

`MediaObject` 新增两个字段（迁移）：

```python
original_expired_at = models.DateTimeField("原图过期时间", null=True, blank=True)
expired_at = models.DateTimeField("完全过期时间", null=True, blank=True)
```

- `original_expired_at`：图片阶段 1 完成时间；null = 原图仍在（单级媒体恒为 null）；
- `expired_at`：完全过期时间（图片阶段 2 / 单级媒体到期）；null = 未完全过期；
- 两者均加 `db_index=True`（清理命令按此过滤）。

## 6. 配置项（settings.py，env 可覆盖）

```python
# 图片：两级
MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS = env.int("MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS", default=7)
MEDIA_CHAT_IMAGE_FULL_TTL_DAYS = env.int("MEDIA_CHAT_IMAGE_FULL_TTL_DAYS", default=30)
# 语音/文件/视频：单级
MEDIA_CHAT_VOICE_TTL_DAYS = env.int("MEDIA_CHAT_VOICE_TTL_DAYS", default=7)
MEDIA_CHAT_FILE_TTL_DAYS = env.int("MEDIA_CHAT_FILE_TTL_DAYS", default=7)
MEDIA_CHAT_VIDEO_TTL_DAYS = env.int("MEDIA_CHAT_VIDEO_TTL_DAYS", default=7)
```

- `<= 0` 表示禁用对应 kind/阶段（未来 app 上线或磁盘紧张时调整窗口，逻辑不变）；
- 约束：`MEDIA_CHAT_IMAGE_FULL_TTL_DAYS >= MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS`（不满足时清理命令报配置错误）。

## 7. 清理命令

扩展 `backend/apps/media/management/commands/cleanup_media.py`：

- 新增 `--expire-chat-media` 参数，执行上述分级过期（幂等、可重跑）；
- 默认行为（无参数）保持现状：清理过期上传会话与孤儿 tmp 对象；
- 输出：每个删除动作一行日志（key、media_id、阶段），汇总统计；
- 遵循项目纪律：**不引入后台调度**，由运维手动/计划任务执行；
- 执行前 `--no-delete` 可预览（与现有参数一致）。

## 8. 前端配合

### 8.1 图片原图降级（7 天后）

- `getSignedMediaUrl(mediaId)` 请求 original 签名后，实际 GET 404（对象已删）；
- 前端降级：original 加载失败 → 自动请求 `variant=thumb` 签名 → 显示缩略图 + "原图已过期"角标；
- 后端 `:sign` 端点：original 已删（`original_expired_at` 非空）时直接返回 410 + 前端降级，避免无效签名往返。

### 8.2 完全过期占位（图片 30 天 / 语音文件视频 7 天）

- thumbnail 也 404（或单级媒体 original 410）→ 聊天气泡显示"已过期"占位（灰底 + 文字），不裂图；
- 查看器（图片/视频大图）同样处理；
- 语音/文件/视频无缩略图降级阶段：到期直接"已过期"。

### 8.3 资产类不受影响

- 帖子/表情包/评论/群头像的媒体永不触发降级，现有加载链路不变。

## 9. 测试计划

后端（`--ds=config.settings_test_mysql`，FakeStorage 注入）：

1. **7 天边界**：图片 created_at 恰好 7 天前 → 阶段 1 过期；6 天 23 小时 → 不过期；
2. **30 天边界**：图片恰好 30 天前 → 完全过期；29 天 23 小时 → 仅阶段 1；
3. **单级边界**：语音/文件/视频恰好 7 天前 → 直接删除；6 天 23 小时 → 不过期；
4. **保护类不删**：被 PostImage / EmojiItem / Comment（media_id 与 images 两种形态）/ Conversation.avatar 引用的媒体，即使超期也不删（含单级媒体）；
5. **聊天类过期**：仅被 Message.media_id / segments 引用的媒体按 kind 对应流程删；
6. **孤儿过期**：无引用媒体按 kind 对应流程删；
7. **幂等重跑**：同一命令跑两次，第二次无动作、不报错；
8. **DB 记录保留**：过期后记录仍在，`expired_at` 已标记；
9. **配置禁用**：TTL 配置为 0 时对应 kind/阶段不删；全部为 0 时命令不删任何正式媒体；
10. **:sign 410**：图片阶段 1 → original 410（可降级）；完全过期（图片阶段 2 / 单级媒体）→ original/thumb 410。

前端（vitest）：

11. original 404 → 降级 thumb 签名请求；
12. thumb 也 404 → 占位渲染。

## 10. 边界与风险

| 风险 | 缓解 |
|---|---|
| 保护类引用漏判 → 资产误删 | 判定全量扫描五类引用；测试覆盖每种引用形态；`--no-delete` 预览 |
| 媒体被多上下文引用（先发消息后被帖子引用） | 判定规则天然安全：被任一保护类引用即永久 |
| 过期后用户回看聊天 | 文字仍在 + 缩略图/占位，与微信"已过期"体验一致 |
| 未来 app 本地缓存 | 删除只动云端对象与 DB 标记，本地副本不受影响（云端回收 ≠ 数据销毁） |
| 磁盘写满 | 用户已拍板不设硬上限；保留磁盘水位监控/告警作为运维手段 |

## 11. 不做的事（明确排除）

- 不设 bucket quota 硬上限；
- 不回收文本消息、帖子、表情包、收藏；
- 不删 `MediaObject` DB 记录（只标记）；
- 不引入后台调度（沿用手动/计划任务执行纪律）。
