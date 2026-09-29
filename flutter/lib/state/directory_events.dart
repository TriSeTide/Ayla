/// 目录热更新事件总线 —— web `ws/chat.ts` 的 `voice.channel.*` / `live.channel.*` /
/// `boardgame.room.*` 三类帧对**目录列表**的效应，Flutter 侧的等价物。
///
/// ## 为什么需要一条总线
/// web 有一个跨页的 `stores/directory.ts`（按 `kind+filter` 缓存游标页），
/// 频道帧到达时直接 patch/移除缓存条目，页面从缓存渲染 ⇒ 天然热更新。
/// Flutter 侧的目录列表是**每页一个** `AylaPagedList`（第二批定的口径：不预建跨页缓存），
/// 因此"某个频道被删/改名/改人数"这件事必须由**事件**广播给当前挂着的页面。
///
/// ## 语义（与 web 逐条对齐）
/// | 帧 | 本总线的动作 | 页面动作 |
/// |---|---|---|
/// | `voice.channel.deleted` / `live.channel.deleted` / `boardgame.room.deleted` | [emitDeleted] | 命中则从列表移除（web `items.filter`） |
/// | `voice.channel.member_count_changed` | [emitPatched]（人数） | 命中则 patch 人数并重排 |
/// | `live.viewers.changed` | [emitPatched]（人数） | 同上（**瞬态投影，不参与排序**） |
/// | `*.created` / `*.updated` / `live.channel.status.changed` | [emitInvalidated] | 置 `invalidated`（页脚给「刷新」入口，不再自动续读旧游标） |
///
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

/// 目录事件总线（全局单例；页面按需订阅）。
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
