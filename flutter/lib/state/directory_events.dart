/// ⚠️ **已退役的事件总线**（2026-10-08）—— 生产不再使用；本文件只为两份历史测试保留。
///
/// ## 为什么退役（用户实报的根因）
/// 本总线是「**帧 → 广播给页面 → 每个页面自己 patch**」的旧架构：
/// 页面漏订阅就**完全没有热更新** —— 用户实报的语音房列表页、直播列表页、桌游列表页、
/// 帖子列表页、群内第 2 列侧栏的直播与语音，正是漏订阅六处；
/// 即便订阅了，`emitInvalidated` 那档也只是「置失效」，页面照做 `refresh()` 时
/// 又会撞上 60 秒新鲜期短路 ⇒ 帧到达后列表纹丝不动。
///
/// 而 web **没有这条总线**：目录缓存是域 store 的查询投影
/// （`stores/directory.ts:143–146` 的 `cachedItems`），帧只落域 store
/// （`ws/chat.ts:667–768 / 845–865`），缓存由 `ensureDirectoryTracking` 的订阅通路
/// 自动 patch（`stores/directory.ts:148–196 / 205–219`）⇒ **页面零订阅**。
///
/// ## 现架构（与消息域同型）
/// - 订阅通路：`state/directory_tracking.dart`（负责新增 / 更新 / 重排 / 成员数）；
/// - 帧直连通路：`core/ws/room_frames.dart` + `AylaDirectoryStore.noteCreated` /
///   `noteDeleted`（负责 `createdIds` 提示与删除摘除）。
/// 参照实现：`core/ws/chat_ws.dart:620` 的 `_message.upsertMessage(convId, msg)` ——
/// 帧处理里**直接调 store 方法**。
///
/// ## 现存用途（仅此一处）
/// `AylaDirectoryEvents` 在 `core/ws/room_frames.dart` 的**兼容档**里仍被使用：
/// 当帧桥**未注入目录 store** 时（历史测试 / 未装配），`*.created` / `*.deleted`
/// 帧仍把语义投到总线，避免静默丢事件。生产恒注入 store ⇒ 兼容档不生效。
///
/// ⚠️ **不得新增订阅者**（否则又回到「漏订阅就没热更新」）。
/// ⚠️ **不静默吞掉**：域外帧在本批之外的一律仍按 [kAylaChatWsOutOfBatchFrames] 显式忽略。
library;

import 'package:flutter/foundation.dart';

/// 目录类别（与 web `DirectoryKind` 同集合）。
enum AylaDirectoryKind { voice, live, game }

/// 一次目录事件。
@immutable
class AylaDirectoryEvent {
  const AylaDirectoryEvent.deleted(this.kind, this.id)
      : memberCount = null,
        deleted = true;

  const AylaDirectoryEvent.patched(this.kind, this.id, this.memberCount)
      : deleted = false;

  const AylaDirectoryEvent.invalidated(this.kind)
      : id = '',
        memberCount = null,
        deleted = false;

  final AylaDirectoryKind kind;

  /// 受影响条目 id（[deleted] / [memberCount] 档有值）。
  final String id;

  /// 新人数（null = 该档不带人数）。
  final int? memberCount;

  /// 是否删除档。
  final bool deleted;
}

/// 目录事件总线（**已退役**；见文件头）。
///
/// 只在帧桥未注入目录 store 时作为兼容出口被使用 —— **页面不得订阅**。
class AylaDirectoryEvents extends ChangeNotifier {
  AylaDirectoryEvent? _last;

  /// 最近一次事件（页面在 build 里比对避免重复处理）。
  AylaDirectoryEvent? get last => _last;

  /// 递增序号（页面记已处理序号，避免重复消费同一事件）。
  int _revision = 0;
  int get revision => _revision;

  void _emit(AylaDirectoryEvent event) {
    _last = event;
    _revision += 1;
    notifyListeners();
  }

  /// 条目被删除。
  void emitDeleted(AylaDirectoryKind kind, String id) =>
      _emit(AylaDirectoryEvent.deleted(kind, id));

  /// 条目的人数变化（瞬态投影；web `patchViewerCount` / `patchChannel`）。
  void emitPatched(AylaDirectoryKind kind, String id, int count) =>
      _emit(AylaDirectoryEvent.patched(kind, id, count));

  /// 目录游标需作废（web `setInvalidated(true)` / `invalidate()`）。
  void emitInvalidated(AylaDirectoryKind kind) =>
      _emit(AylaDirectoryEvent.invalidated(kind));

  /// 登出：清空（web `disposeDirectoryTracking` 的 `reset`）。
  void reset() {
    _last = null;
    _revision += 1;
    notifyListeners();
  }
}
