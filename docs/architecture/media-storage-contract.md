# 媒体对象存储契约（唯一事实源）

> 状态：生效中（2026-10-29 定稿，因当日事故重写）
> 适用范围：Ayla 后端 `apps/media`、客户端漫游缓存、运维脚本
> 关联：`docs/operations/media-expiration-runbook.md`、`docs/architecture/media-storage-expiration.md`

## 0. 为什么有这份文档

2026-10-29 事故的直接触发是手工执行 `mc rm --versions --dangerous` 把整个
`media/` 前缀的当前对象连同历史版本一起删除，51 条 `MediaObject` 里绝大多数
对象消失。**系统当时没有任何机制能发现这件事** —— `cleanup_media` 只看 DB，
`/content` 到访问时才 404，事后仅能从客户端漫游缓存抢救回 42 条。

因此本文件把「存储结构」从散落在 `storage.py` 的构造函数里**提升为显式契约**，
并由 `manage.py media_audit` 强制执行。

## 1. key 空间（穷举，除此之外一律非法）

```
tmp/{upload_id}                                       ← 上传暂存，用完即删
media/{kind}/{media_id}/original                      ← 正式原件
media/{kind}/{media_id}/thumbnail                     ← 派生封面（图片缩略图 / 视频海报帧）
media/{kind}/{media_id}/waveform                      ← 语音波形 PNG
```

约束：

| 段 | 取值 | 强制度 |
|---|---|---|
| `kind` | `image` \| `voice` \| `video` \| `file` \| `emoji` | 闭集，别的值一律非法 |
| `media_id` | **32 位小写 hex**（`uuid4().hex`） | 严格正则 `[0-9a-f]{32}` |
| variant | `original` \| `thumbnail` \| `waveform` | 闭集 |

**没有例外、没有历史兼容形态。** 新增 variant 或 kind 必须同时改：
1. `apps/media/storage.py` 的 key 构造函数；
2. `apps/media/models.py` 的 `KIND_CHOICES`；
3. `apps/media/management/commands/media_audit.py` 的 `MEDIA_KEY_RE`；
4. 本文件。

## 2. 谁在读、谁在写

| 操作 | 路径 | 是否列举桶 |
|---|---|---|
| 上传 | `tmp/{upload_id}` → complete 时**服务端 copy** → `media/.../original` | ❌ 从不 |
| 派生 | `media/.../thumbnail` / `waveform` | ❌ 从不 |
| 播放/下载 | `presign_get` 或 `open_stream`，**按已知 key 精确取** | ❌ 从不 |
| 过期清理 | 按 DB 记录的 key 精确 `delete` | ❌ 从不 |
| 一致性审计 | `list_keys()` | ✅ **唯一允许列举的路径** |

**硬约束**：业务路径永不列举桶。列举是 O(n)，在千万级桶上会成为运维瓶颈；
且一旦业务依赖列举，任何结构漂移都会变成"越跑越慢"而不是"立刻报错"。

## 3. DB 与对象的权威关系

```
MediaObject.storage_path / thumbnail_path / waveform_path  ←  DB 是权威声明
                          ↕  必须一一对应
MinIO 桶内实际对象                                          ←  对象存储是事实
```

- **DB 有、对象无** ⇒ 缺陷（用户看到「已过期」且永远恢复不了）。唯一例外：
  该媒体 `expired_at` 非空（完全过期后对象本就该删）。
- **对象有、DB 无** ⇒ 孤儿，白占磁盘；由 `--prune-orphans` 清理。
- **对象 key 非标准** ⇒ 结构漂移，清理/TTL 逻辑无法识别。

## 4. 执行护栏

```bash
# 只读对账（每日跑，退出码非 0 即告警）
docker exec ayla-backend python manage.py media_audit

# 逐条列出
docker exec ayla-backend python manage.py media_audit --verbose

# 清理孤儿（先预览，确认后加 --no-dry-run）
docker exec ayla-backend python manage.py media_audit --prune-orphans
```

退出码：`0` 全通过 / `1` 发现问题 / `2` 后端不支持列举。

## 5. 禁止操作清单（2026-10-29 事故教训）

| 禁止 | 原因 |
|---|---|
| `mc rm --recursive --versions --force --dangerous <bucket>/media/` | **在版本化被 suspend 后，`--versions` 会物理删除包括当前对象在内的所有版本**。当日即因此清空了整个 media 前缀。 |
| 对 `media/` 前缀做任何递归删除 | 正式媒体只能由 `cleanup_media` 按 DB 记录逐 key 删除 |
| `mc version suspend` 后立即跑批量删除 | suspend 只影响**未来**的删除行为；已有历史版本仍需 `--versions` 才会释放，而该参数同时会删掉当前对象 |
| 手改 `storage_path` 等字段 | 会造成 DB 与对象永久错位 |

**正确做法**：清理历史版本只针对 `tmp/`（无 DB 引用），或先 `media_audit`
确认目标 key 已是孤儿。正式媒体的回收一律走 `cleanup_media`。

## 6. 变更流程

任何影响 key 形态的改动必须在同一次提交里：
1. 改 `storage.py` 构造函数 + `media_audit.MEDIA_KEY_RE`；
2. 补 `test_media_audit.py` 的正/反例；
3. 更新本文件与 `media-storage-expiration.md`；
4. 在服务器执行一次 `media_audit`，确认旧数据仍全部合规（或提供迁移脚本）。
