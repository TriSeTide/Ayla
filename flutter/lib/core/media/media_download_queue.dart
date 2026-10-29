/// 持久下载队列 —— 「看见就存」的可靠版（2026-10-29 用户拍板）。
///
/// ## 为什么需要它
///
/// 云端 MinIO 对聊天媒体做分级过期（图片 7 天删原图 / 30 天删缩略图；视频 7 天
/// 删本体 / 30 天删海报；语音·文件 7 天全删）。用户的要求是：
///
/// > 创建一个后台静默的下载任务，直到下载成功了为止，app 内无论在什么位置都保持
/// > 下载。如果有下载任务仍未完成，但 app 清后台退出了下载失败了，该下载任务仍然
/// > 保留，下次 app 启动时再次自动重新开始执行该下载任务。最多重试三次。
///
/// 旧实现是组件层 `unawaited(fetchAndStore(...).catchError(→null))`：
/// 页面一滚走组件就卸载、进程一退就全丢，失败完全无感 —— 于是「7 天后云端删了、
/// 本地也没存下」的媒体会永久变成「已过期」。
///
/// 本队列把落盘意图**先写盘再执行**：任务持久化在
/// `<缓存根>/../download-queue.json`（与缓存同卷，原子写），进程重启后
/// [resumeOnStartup] 重新开跑；单个任务最多重试 [maxAttempts] 次。
///
/// ## 与缓存层的关系（职责边界）
///
/// - [AylaMediaCache] 负责「读/写字节 + 命中判定」，**不知道任务状态**；
/// - 本队列负责「要存什么、存了几次、还差什么」，实际下载仍走
///   `AylaMediaCache.fetchAndStore`（它内部已含签名 + 410 语义 + 原子写 + 并发去重）；
/// - 因此队列是**增强层**：队列文件损坏/写不进去时，退化为「本次不排队」，
///   绝不阻塞媒体显示（与缓存层同一条纪律）。
///
/// ## 状态机
///
/// ```
/// pending ──claim──> running ──成功──> done（立即从文件里移除）
///    ^                  │
///    └────失败且 attempts<3────┘
///                       │
///                       └──失败且 attempts>=3──> failed（保留记录，不再自动重试）
/// ```
///
/// 过期（云端 410 且本地没有）不消耗重试次数：它**不可能**成功，直接判 failed
/// 并记录原因 —— 避免「一个永远失败的过期媒体反复占着队列」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_kind.dart';
import 'media_cache.dart';
import 'media_cache_paths.dart';
import 'media_signer.dart' show MediaExpiredError;

/// 任务状态。
enum AylaDownloadState {
  /// 待执行（含「上次进程退出时没跑完」的任务）。
  pending,

  /// 正在执行。
  running,

  /// 已达最大重试次数或确定不可恢复（云端已过期），不再自动重试。
  failed,
}

/// 一个「把某个媒体形态存到本地」的意图。
@immutable
class AylaDownloadTask {
  const AylaDownloadTask({
    required this.mediaId,
    required this.kind,
    required this.variant,
    this.mimeType,
    this.attempts = 0,
    this.state = AylaDownloadState.pending,
    this.lastError,
  });

  final String mediaId;
  final AylaMediaKind kind;

  /// 媒体 MIME（决定落盘扩展名）。
  ///
  /// **必须传**：缓存文件名扩展名优先由 mime 推导，缺失时按 kind 兜底
  /// （voice → `.webm`），而实际录音是 `audio/mp4`/`.m4a` —— 扩展名错了
  /// 会让本地播放内核（media_kit / just_audio）按错误容器解析。
  final String? mimeType;

  /// 存哪一种（original / thumb）。图片气泡存 thumb、查看器存 original。
  final AylaMediaCacheVariant variant;

  /// 已尝试次数（含失败）。
  final int attempts;

  final AylaDownloadState state;

  /// 最近一次失败原因（诊断用，不含 URL/令牌）。
  final String? lastError;

  /// 队列内唯一键：同媒体同形态只排一次。
  String get key => '${kind.wire}|${variant.name}|$mediaId';

  AylaDownloadTask copyWith({
    int? attempts,
    AylaDownloadState? state,
    String? lastError,
  }) =>
      AylaDownloadTask(
        mediaId: mediaId,
        kind: kind,
        variant: variant,
        mimeType: mimeType,
        attempts: attempts ?? this.attempts,
        state: state ?? this.state,
        lastError: lastError ?? this.lastError,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'media_id': mediaId,
        'kind': kind.wire,
        'variant': variant.name,
        if (mimeType != null) 'mime_type': mimeType,
        'attempts': attempts,
        'state': state.name,
        if (lastError != null) 'last_error': lastError,
      };

  /// 解析；任何字段非法返回 null（**不造半份任务**）。
  static AylaDownloadTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String mediaId = raw['media_id']?.toString() ?? '';
    if (mediaId.isEmpty) return null;
    final AylaMediaKind? kind = AylaMediaKind.parse(raw['kind']?.toString());
    if (kind == null) return null;
    final String variantRaw = raw['variant']?.toString() ?? 'original';
    final AylaMediaCacheVariant variant = variantRaw == 'thumb'
        ? AylaMediaCacheVariant.thumb
        : AylaMediaCacheVariant.original;
    final AylaDownloadState state =
        AylaDownloadState.values.where((AylaDownloadState s) => s.name == raw['state']).firstOrNull ??
            AylaDownloadState.pending;
    return AylaDownloadTask(
      mediaId: mediaId,
      kind: kind,
      variant: variant,
      mimeType: raw['mime_type']?.toString(),
      attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
      state: state,
      lastError: raw['last_error']?.toString(),
    );
  }

  @override
  String toString() =>
      'AylaDownloadTask($kind.${variant.name}:$mediaId attempts=$attempts ${state.name})';
}

/// 队列统计（供「缓存管理」UI 展示）。
@immutable
class AylaDownloadQueueStats {
  const AylaDownloadQueueStats({
    required this.pending,
    required this.running,
    required this.failed,
  });

  final int pending;
  final int running;
  final int failed;

  int get total => pending + running + failed;

  static const AylaDownloadQueueStats empty =
      AylaDownloadQueueStats(pending: 0, running: 0, failed: 0);

  @override
  String toString() =>
      'AylaDownloadQueueStats(pending=$pending, running=$running, failed=$failed)';
}

/// 下载执行器抽象（测试注入点）：默认走 [AylaMediaCache.fetchAndStore]。
typedef AylaDownloadRunner = Future<File?> Function(AylaDownloadTask task);

/// 持久下载队列（单例：[AylaMediaDownloadQueue.instance]）。
class AylaMediaDownloadQueue {
  AylaMediaDownloadQueue({
    AylaMediaCache? cache,
    AylaDownloadRunner? runner,
    this.maxAttempts = 3,
    this.maxConcurrent = 2,
  })  : _cache = cache ?? AylaMediaCache.instance,
        _runner = runner;

  /// 生产单例。
  static final AylaMediaDownloadQueue instance = AylaMediaDownloadQueue();

  final AylaMediaCache _cache;
  AylaDownloadRunner? _runner;

  /// 单任务最大尝试次数（用户要求「最多重试三次」）。
  final int maxAttempts;

  /// 并发下载上限（避免一次进视口就几十个请求打满带宽）。
  final int maxConcurrent;

  /// 队列文件路径（首次 [ensureReady] 后非 null）。
  File? _queueFile;

  /// 内存态任务表（键 = [AylaDownloadTask.key]，保持插入顺序）。
  final Map<String, AylaDownloadTask> _tasks = <String, AylaDownloadTask>{};

  Future<void>? _readyFuture;
  bool _pumping = false;
  int _running = 0;

  /// 是否已加载队列文件。
  bool get isReady => _queueFile != null;

  /// 当前快照（只读副本，供 UI）。
  List<AylaDownloadTask> get tasks => List<AylaDownloadTask>.unmodifiable(_tasks.values);

  /// 统计。
  AylaDownloadQueueStats get stats {
    int pending = 0, running = 0, failed = 0;
    for (final AylaDownloadTask t in _tasks.values) {
      switch (t.state) {
        case AylaDownloadState.pending:
          pending++;
        case AylaDownloadState.running:
          running++;
        case AylaDownloadState.failed:
          failed++;
      }
    }
    return AylaDownloadQueueStats(pending: pending, running: running, failed: failed);
  }

  /* ---------------- 测试注入点 ---------------- */

  @visibleForTesting
  void setRunnerForTest(AylaDownloadRunner? runner) => _runner = runner;

  /// 测试注入点：直接指定队列文件（跳过缓存根解析）。
  ///
  /// 不预置 `_readyFuture`：`ensureReady()` 会走 [_init]，其中检测到
  /// `_queueFile` 已注入就只做 [_load]（不碰 path_provider，单测可用）。
  @visibleForTesting
  void setQueueFileForTest(File file) {
    _queueFile = file;
    _readyFuture = null;
  }

  /* ---------------- 初始化 ---------------- */

  /// 加载队列文件（幂等）。
  ///
  /// 队列文件放在**缓存根的同级**（`<media-cache>/../download-queue.json`）：
  /// 与缓存同卷 ⇒ 同一份可写性判定，不额外依赖别的目录；同时不污染
  /// `media-cache/` 的 kind 分桶遍历（[AylaMediaCache.stats] 会递归扫该目录）。
  Future<void> ensureReady() {
    final Future<void>? current = _readyFuture;
    if (current != null) return current;
    final Future<void> future = _init();
    _readyFuture = future;
    return future;
  }

  Future<void> _init() async {
    // 测试/调用方已显式注入队列文件 ⇒ 只加载，不再解析缓存根
    //（缓存根解析依赖 path_provider，单测环境下没有 platform channel）。
    if (_queueFile != null) {
      await _load();
      return;
    }
    try {
      final AylaMediaCacheLayout layout = await _cache.ensureReady();
      final String root = layout.root.replaceAll('\\', '/');
      final int slash = root.lastIndexOf('/');
      final String parent = slash <= 0 ? root : root.substring(0, slash);
      _queueFile = File('$parent/download-queue.json');
      await _load();
    } catch (error) {
      debugPrint('[AylaDownloadQueue] 初始化失败（队列降级为内存态）：$error');
    }
  }

  Future<void> _load() async {
    final File? file = _queueFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final String text = await file.readAsString();
      if (text.trim().isEmpty) return;
      final Object? raw = jsonDecode(text);
      if (raw is! Map) return;
      final Object? list = raw['tasks'];
      if (list is! List) return;
      for (final Object? item in list) {
        final AylaDownloadTask? task = AylaDownloadTask.fromJson(item);
        if (task == null) continue;
        // 进程退出时还在 running 的任务：视为 pending，重新排队
        // （用户要求「app 清后台退出后，下次启动再次自动重新执行」）。
        _tasks[task.key] = task.state == AylaDownloadState.running
            ? task.copyWith(state: AylaDownloadState.pending)
            : task;
      }
      debugPrint('[AylaDownloadQueue] 恢复 ${{_tasks.length}} 个下载任务');
    } catch (error) {
      debugPrint('[AylaDownloadQueue] 读取队列失败（按空队列处理）：$error');
    }
  }

  /// 原子写队列文件（`.tmp` → flush → rename）。
  /// 写盘序号：让每次写用的 `.tmp` 名字唯一。
  ///
  /// 为什么不用固定的 `download-queue.json.tmp`：多实例（测试里两个队列指向同一
  /// 文件、或用户开了两个进程）并发写时，同名 tmp 会互相踩出 AccessDenied。
  /// 唯一名 + rename 后，最后一次成功 rename 的赢，语义仍是「整体替换」。
  static int _persistSeq = 0;

  Future<void> _persist() async {
    final File? file = _queueFile;
    if (file == null) return;
    _persistSeq++;
    final File tmp = File('${file.path}.$_persistSeq.tmp');
    try {
      await file.parent.create(recursive: true);
      final String text = jsonEncode(<String, dynamic>{
        'version': 1,
        'tasks': _tasks.values.map((AylaDownloadTask t) => t.toJson()).toList(),
      });
      final RandomAccessFile handle =
          await tmp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeString(text);
        await handle.flush();
      } finally {
        await handle.close();
      }
      // Windows 上 `rename` 覆盖已存在文件会偶发 AccessDenied（errno 5）——
      // 先删目标再改名，把「原子替换」退化成「删除+改名」，最坏情况是崩溃在
      // 两者之间留下空队列文件（下次启动按空队列处理，可接受：缓存是增强项）。
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // 删不掉就直接 rename，交给下面的 catch 记录
        }
      }
      await tmp.rename(file.path);
    } catch (error) {
      debugPrint('[AylaDownloadQueue] 写队列失败（忽略）：$error');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清不掉也无妨：下次写入会覆盖
      }
    }
  }

  /* ---------------- 入队 / 执行 ---------------- */

  /// 入队一个「存到本地」的意图。
  ///
  /// 幂等：同 `kind|variant|mediaId` 已在队列（且不是 failed）则直接返回。
  /// 已 failed 的任务允许被**重新入队**（用户再次看到它 = 再给一次机会，
  /// 但 attempts 会重置，因为这是一次新的用户可见机会）。
  Future<void> enqueue({
    required String mediaId,
    required AylaMediaKind kind,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
    String? mimeType,
  }) async {
    await ensureReady();
    final AylaDownloadTask probe = AylaDownloadTask(
      mediaId: mediaId,
      kind: kind,
      variant: variant,
      mimeType: mimeType,
    );
    final AylaDownloadTask? existing = _tasks[probe.key];
    if (existing != null && existing.state != AylaDownloadState.failed) return;
    _tasks[probe.key] = probe;
    await _persist();
    unawaited(_syncKeepAlive());
    unawaited(pump());
  }

  /// 启动时续跑（`main.dart` 预热处调用）。
  ///
  /// 与 [enqueue] 的差别：不新增任务，只把上次没跑完的 pending 重新跑一遍。
  Future<void> resumeOnStartup() async {
    await ensureReady();
    if (_tasks.isEmpty) return;
    debugPrint('[AylaDownloadQueue] 启动续跑：${_tasks.length} 个待办');
    unawaited(_syncKeepAlive());
    await pump();
  }

  /// 推进队列（可重入安全）。
  ///
  /// 返回后**不保证全部完成**（并发上限内会异步继续跑），调用方可
  /// `await waitIdle()` 等待。
  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_running < maxConcurrent) {
        final AylaDownloadTask? next = _nextPending();
        if (next == null) break;
        _running++;
        // 不 await：让并发槽位同时跑起来（下载是 IO 密集）
        unawaited(_run(next).whenComplete(() => _running--));
      }
    } finally {
      _pumping = false;
    }
  }

  /// 队列状态变化后同步「后台保活」（Android 前台服务）。
  ///
  /// 单向依赖：队列**不认识**平台保活实现，只调用这个注入点；保活层反过来读
  /// [stats] 决定起停。两者解耦 ⇒ 队列仍可在纯 Dart 单测里跑。
  Future<void> _syncKeepAlive() async {
    final Future<void> Function()? hook = keepAliveSync;
    if (hook != null) await hook();
  }

  /// 保活同步钩子（生产由 main.dart 接到 AylaDownloadKeepAlive.syncWithQueue；
  /// 单测可注入替身断言「队列有活/空了会触发保活」）。
  Future<void> Function()? keepAliveSync;

  AylaDownloadTask? _nextPending() {
    for (final AylaDownloadTask t in _tasks.values) {
      if (t.state == AylaDownloadState.pending) return t;
    }
    return null;
  }

  Future<void> _run(AylaDownloadTask task) async {
    final AylaDownloadTask running = task.copyWith(state: AylaDownloadState.running);
    _tasks[task.key] = running;
    await _persist();
    try {
      final File? file = await _runTask(running);
      if (file != null) {
        // 成功：任务完成即从队列移除（不留垃圾记录）
        _tasks.remove(task.key);
        await _persist();
        unawaited(_syncKeepAlive()); // 队列空了要停掉前台服务
        return;
      }
      // 返回 null = 缓存层放弃（下载失败 / 0 字节 / 原图已过期不冒充）
      await _markFailure(task, 'download_failed');
    } on MediaExpiredError {
      // 云端已完全过期且本地没有 ⇒ 永远不可能成功，不再消耗重试
      _tasks[task.key] = task.copyWith(
        state: AylaDownloadState.failed,
        lastError: 'media_expired',
      );
      await _persist();
    } catch (error) {
      await _markFailure(task, error.toString());
    }
  }

  Future<void> _markFailure(AylaDownloadTask task, String reason) async {
    final int attempts = task.attempts + 1;
    final bool exhausted = attempts >= maxAttempts;
    _tasks[task.key] = task.copyWith(
      attempts: attempts,
      state: exhausted ? AylaDownloadState.failed : AylaDownloadState.pending,
      lastError: reason,
    );
    await _persist();
    if (!exhausted) {
      // 有界退避后继续跑（不阻塞调用方）
      unawaited(Future<void>.delayed(Duration(seconds: 2 * attempts), pump));
    }
  }

  Future<File?> _runTask(AylaDownloadTask task) {
    final AylaDownloadRunner? runner = _runner;
    if (runner != null) return runner(task);
    return _cache.fetchAndStore(
      mediaId: task.mediaId,
      kind: task.kind,
      mimeType: task.mimeType,
      variant: task.variant,
    );
  }

  /// 等待队列跑空（测试/退出前用；最长 [timeout]）。
  Future<void> waitIdle({Duration timeout = const Duration(seconds: 60)}) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await pump();
      final bool busy = _tasks.values.any(
        (AylaDownloadTask t) => t.state != AylaDownloadState.failed,
      );
      if (!busy) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 清掉 failed 记录（「缓存管理」里的「清除失败任务」）。
  Future<void> clearFailed() async {
    await ensureReady();
    _tasks.removeWhere(
      (String _, AylaDownloadTask t) => t.state == AylaDownloadState.failed,
    );
    await _persist();
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _tasks.clear();
    _queueFile = null;
    _readyFuture = null;
    _pumping = false;
    _running = 0;
  }
}
