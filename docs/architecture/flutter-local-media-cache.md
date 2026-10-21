# Flutter 客户端本地媒体缓存（漫游缓存）方案

> 版本：2026-10-21 定稿（用户拍板）
> 状态：**实施中**（task-4 缓存层 / task-5 组件接入）
> 上位文档：`docs/architecture/media-retention-boundaries.md`（云端边界唯一事实源）
> 关联报告：`docs/report/MinIO存储与过期机制调查报告-2026-10-21.md`

## 1. 设计动机

云端 MinIO 对聊天媒体做 7/30 天分级过期（图片）、7 天单级过期（语音/文件/视频）。但用户侧的真实诉求是：

> **「能看到图片永远比不能看到好，过期只是服务器存储优化的方案。」**

即：云端过期是**成本控制手段**，不是**内容销毁策略**。客户端应在本地保留已看过的内容，实现"看过就一直能看"。

这与 `media-retention-boundaries.md` 的核心原则「**云端回收 ≠ 数据销毁**」完全一致——该原则原本只对"客户端本地缓存不受影响"做了抽象表述，本方案是其具体落地。

## 2. 已定决策（用户 2026-10-21）

| # | 决策 | 说明 |
|---|---|---|
| D1 | **缓存原图** | 只缓存 original，不缓存 thumb（thumb 仅用于网络降级显示） |
| D2 | **无容量上限** | 不做 LRU、不做总量限制、不自动清理。用户后续可能加"图片清理"功能，当前不做 |
| D3 | **本地有就一直显示** | 云端 410/404 时，本地命中则正常渲染，**不显示「已过期」占位** |
| D4 | **加载即存** | 任何媒体被加载/查看成功后就静默落盘，不提示、不显示"正在缓存" |
| D5 | **跨账号共享** | 不按 user_id 隔离。两个号加同一群，A 号看过的图 B 号也能看到 |
| D6 | **覆盖全部会过期的媒体** | image / voice / video / file 全做（emoji 本就不上场，接口预留） |
| D7 | **目录必须分桶** | 不允许所有文件堆在一个文件夹 |

## 3. 存储位置

| 平台 | 根目录 | 依据 |
|---|---|---|
| **Windows** | `<exe所在目录>/data/media-cache/` | 用户实测绿色包解压在 `E:\ayla-windows-x64-1.0.1+2`，同级有 `data/` |
| **Android / iOS** | `getApplicationSupportDirectory()/media-cache/` | 应用私有目录，无需额外权限 |

### 3.1 Windows 的 data/ 目录复用风险（重要）

Windows 包的 `data/` **同时是 Flutter 运行时资源目录**：

```
data/
├── app.so              ← Flutter AOT 编译产物（运行时必需）
├── icudtl.dat          ← ICU 数据（运行时必需）
└── flutter_assets/     ← 资源包（运行时必需）
```

因此缓存**必须**放进 `data/media-cache/` 这个独立子目录，**绝不能**污染上述文件。

**更新安全性**：Windows 更新脚本用 `robocopy %SRC% %DST% /E /COPY:DAT /R:3 /W:2`
（`Ayla/flutter/lib/core/update/update_applier.dart:269`）。`/E` 只覆盖不删除，
所以 `data/media-cache/` 在应用更新后**不会丢失**。

### 3.2 可写性降级

Windows 若安装到 `Program Files` 等受保护目录，普通用户对 exe 同级目录无写权限。
启动时探测（试写一个临时文件）：

```
可写 → <exe目录>/data/media-cache/
不可写 → getApplicationSupportDirectory()/media-cache/  （并记日志）
```

Android/iOS 直接用后者，无需探测。

## 4. 目录布局（分桶）

**原则**：单一目录文件数不超过约 2^8=256 个（避免目录遍历性能退化与资源管理器卡顿）。

```
media-cache/
└── <kind>/                     image | voice | video | file | emoji
    └── <media_id 前 2 位>/     00 .. ff（256 个桶）
        └── <media_id>.<ext>    原始对象（原图/原音频/原视频/原文件）
```

示例：

```
media-cache/
├── image/5d/5db02e1571464f91bce21bdda1245125.jpg
├── image/51/51c0e2cd5c2b409ebb89647d53fa0231.png
├── voice/c9/c904082abf1a4003a5a0db48b5071a0d.webm
├── video/8a/8a1b2c3d....mp4
└── file/fb/fb485f2570ab4473b8da13688940327b.pdf
```

**理由**：
- 按 `kind` 分第一层：便于后续按类型做清理/统计（例如"只清视频"）；
- 按 `media_id` 前 2 位分第二层：media_id 是 uuid4 hex，前 2 位均匀分布，天然 256 桶；
- 文件名直接用 media_id：稳定、幂等、便于反查；扩展名从 mime_type 推导（缺失时用 `.bin`）。

## 5. 读取链路

```
组件请求媒体
  ↓
本地缓存 lookup(mediaId)
  ├─ 命中 → 直接用本地 File（Image.file / Audio file:// / Video file:// / 直接打开）
  └─ 未命中
      ↓
      MediaSigner.sign(mediaId)  → 预签名 URL
      ↓
      远程加载成功
      ↓
      静默 store(bytes/file) 落盘（失败只记日志，不打断显示）
```

**关键语义**：

| 场景 | 行为 |
|---|---|
| 本地命中 | 直接用本地，**完全不发网络请求**（连签名都不签） |
| 本地未命中 + 云端可用 | 远程加载 → 显示 → 静默落盘 |
| 本地未命中 + 云端 410（完全过期） | 显示「已过期」占位 |
| **本地命中 + 云端 410** | **正常显示本地内容，不显示已过期**（D3） |
| 本地未命中 + 云端 404/网络失败 | 显示「加载失败 + 重试」 |

## 6. 写入原子性

```
写入 → <target>.tmp → fsync → rename(<target>.tmp, <target>)
```

避免进程崩溃/断电时留下半截文件被后续读到。`.tmp` 文件在启动扫描时清理。

## 7. 并发控制

同一 `media_id` 的并发加载（例如列表里同一张图出现多次）只下载一次：
用 in-flight `Map<String, Future<File?>>`，与 `MediaSigner` 的现有做法一致
（`media_signer.dart:110-118`）。

## 8. 与其他缓存的层次

| 层 | 作用域 | 生命周期 | 内容 |
|---|---|---|---|
| `MediaSigner._cache` | 进程内存 | 600s（到期前 60s 重签） | 签名 URL |
| Flutter `ImageCache` | 进程内存 | Flutter 默认 | 解码后的图片 |
| **本地媒体缓存** | **磁盘** | **永久** | **原始字节** |

三者不冲突：本地缓存是**最外层**，命中后连签名都不需要。

## 9. 不做的事

- ❌ 不按账号隔离缓存（D5）
- ❌ 不设容量上限与 LRU（D2）
- ❌ 不自动清理过期/陈旧文件（D2；用户后续可能加清理功能）
- ❌ 不缓存 thumb（D1）
- ❌ 不缓存资产类之外的临时上传对象（`tmp/` 前缀是服务端的，客户端不涉及）

## 10. 后续可能的扩展（本期不做）

- 设置页「清理本地缓存」（显示占用大小、按 kind 清理）——缓存层需暴露统计 API 以支持
- 缓存导出/导入（换机迁移）
