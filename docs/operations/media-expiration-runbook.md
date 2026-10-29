# 聊天媒体过期与本地缓存 —— 运行手册（Operations）

> 适用：Ayla 后端 `apps/media` + Flutter 客户端漫游缓存
> 事实源：代码（本文件只写「怎么执行、怎么验证、怎么回滚」）
> 相关架构文档：`docs/architecture/media-storage-expiration.md`、`media-retention-boundaries.md`、`flutter-local-media-cache.md`

## 1. 这套机制现在是什么状态

| 项 | 状态 | 证据 |
|---|---|---|
| 过期算法（图片/视频两级、语音/文件单级、A1–A7 保护、emoji 跳过） | ✅ 代码就绪 | `apps/media/management/commands/cleanup_media.py` |
| **调度** | ❌ **没有**（仓库与生产都是手动命令） | 见 §2 |
| **MinIO 版本化** | ⚠️ Enabled ⇒ `delete()` 只写 delete marker，**不释放磁盘** | 见 §3 |

因此：**只要没人跑命令、或桶还是版本化，聊天媒体就永远不过期，磁盘只增不减。**

## 2. 手动执行（先预览，后执行）

```bash
# ① 只读预览：打印会删什么，不删对象、不写 DB
docker exec ayla-backend python manage.py cleanup_media --expire-chat-media --no-delete

# ② 真正执行
docker exec ayla-backend python manage.py cleanup_media --expire-chat-media

# ③ 顺带清上传残留（确认当前没有进行中的上传！）
docker exec ayla-backend python manage.py cleanup_media --include-active
```

输出每条都以 `[media] ` 开头，便于日志检索。

**首次执行前必读**：被清理的语音/文件仍可能出现在历史聊天里，执行后那些消息会显示「已过期」
（符合 E1 类「可过期」设计）。确认可接受再跑。

## 3. 桶版本化（不处理则过期无效）

```bash
# 查看
docker exec ayla-minio sh -c 'mc version info local/elysia-media'

# 方案 A（推荐，一次性释放）：暂停版本化 + 清理历史版本
docker exec ayla-minio sh -c 'mc version suspend local/elysia-media'
# 之后的历史版本仍占空间，需要逐前缀清理：
docker exec ayla-minio sh -c 'mc rm --recursive --versions --force --dangerous local/elysia-media/tmp/'
```

⚠️ 清理历史版本**不可逆**（历史版本永久丢弃）。执行前先用 `mc ls --versions --recursive`
确认哪些前缀有历史版本（线上实测只有 `tmp/` 与 `media/image/*/thumbnail` 有）。

**方案 B（保守）**：保持版本化，把 `S3Storage.delete()` 改成带 `VersionId` 的硬删。
需要改代码 + 跑测试，属于后续优化项。

## 4. 挂到定时任务（建议每日一次）

宿主机 `crontab -e`（与现有 `voice_reap_stale_members` 同一形态）：

```cron
# 每天 04:30 清理聊天媒体（先 --no-delete 观察一周再启用正式删除）
30 4 * * * /usr/bin/docker exec ayla-backend python manage.py cleanup_media --expire-chat-media >> /home/ayerelysia/Elysia/ayla-deploy/logs/cleanup_media.log 2>&1
```

验证：

```bash
tail -50 /home/ayerelysia/Elysia/ayla-deploy/logs/cleanup_media.log   # 应出现 "[media] 聊天媒体过期完成"
docker exec ayla-backend python manage.py shell -c "from apps.media.models import MediaObject as M; print(M.objects.filter(expired_at__isnull=False).count())"
```

## 5. 配置项（全部有代码默认值，可不配）

| 变量 | 默认 | 语义 |
|---|---|---|
| `MEDIA_CHAT_IMAGE_ORIGINAL_TTL_DAYS` | 7 | 图片阶段 1：删原图留缩略图 |
| `MEDIA_CHAT_IMAGE_FULL_TTL_DAYS` | 30 | 图片阶段 2：删全部（含缩略图） |
| `MEDIA_CHAT_VIDEO_TTL_DAYS` | 7 | 视频阶段 1：删视频本体、**保留首帧海报** |
| `MEDIA_CHAT_VIDEO_FULL_TTL_DAYS` | 30（回落图片 FULL） | 视频阶段 2：删海报 |
| `MEDIA_CHAT_VOICE_TTL_DAYS` | 7 | 语音单级：全删 |
| `MEDIA_CHAT_FILE_TTL_DAYS` | 7 | 文件单级：全删 |
| `MEDIA_PROCESSING_STALE_HOURS` | 24 | 卡在 processing 超时转 failed 并纳入过期；`<=0` 禁用 |
| `MEDIA_TMP_TTL_SECONDS` | 600 | 上传会话 TTL |

`<=0` 表示禁用对应阶段。FULL < ORIGINAL 时命令直接报 `CommandError`（显式失败）。

## 6. 客户端侧（Flutter）

- 缓存根：Windows `<exe>/data/media-cache`；**Android `<外部存储>/Android/data/<包名>/files/media-cache`**（拿不到则降级到应用支持目录，日志标记 `已降级`）；iOS 应用支持目录。
- 落盘调度：**持久下载队列**（`core/media/media_download_queue.dart`），任务先落盘再执行，
  失败最多重试 3 次，进程被杀后下次启动 `resumeOnStartup` 续跑。
- 后台保活：Android 起前台服务（通知栏「Ayla 正在缓存媒体」）；
  **iOS 不支持后台常驻下载**（系统限制），策略 = 前台持续 + 后台尽力 + 下次启动续跑。
- 无上限/无 LRU/无 TTL：磁盘只增不减，后续需要「清理缓存」入口（`AylaMediaCache.stats()/evict()` 已有，缺 UI）。

## 7. 回滚

| 变更 | 回滚 |
|---|---|
| 过期 TTL 调整 | 改回 env 或删掉该 env（回落代码默认） |
| 停止过期 | `MEDIA_CHAT_*_TTL_DAYS=0`（全 0 = 命令无动作） |
| 停止 cron | `crontab -e` 删除对应行 |
| 恢复版本化 | `mc version enable local/elysia-media`（历史版本已清的不可恢复） |
| 客户端退回旧缓存目录 | 回滚安装包即可；旧目录文件保留不删，不冲突 |
