/// live 全局状态 —— web `stores/live.ts`（271 行）的 Flutter 等价物。
///
/// ## 逐字段对应（web `stores/live.ts`）
/// | 本类 | web | 口径 |
/// |---|---|---|
/// | [channels] | `channels` | 列表投影（**排序归各页**；本表给房内页/热更新用） |
/// | [currentChannel] / [srsStatus] / [danmaku] / [viewerCount] / [viewers] | `current.*` | 当前直播间四件套 |
/// | [currentLoading] / [currentError] / [currentPlayerError] | 同名 | 由会话运行时写入 |
/// | [wsConnection] | `wsConnection` | 弹幕 WS 连接状态 |
///
/// ## 纪律（web 文件头原话）
/// - `srsStatus` 优先；null（未查询）时 UI 用乐观 `status` 兜底**并标注**；
/// - 弹幕按 id 去重、定长截断（[kAylaDanmakuMaxItems] = 500，权威历史在后端可随时再拉）；
/// - **在看人数是瞬态投影**：null = 读不到（presence 存储不可用）⇒ UI 隐藏人数，
///   **不用 0 冒充"没人看"**（`apps/live/viewers.py` 的 503 语义）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/live_api.dart';
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 实时弹幕队列上限（web `stores/live.ts:20` `DANMAKU_MAX_ITEMS`）。
const int kAylaDanmakuMaxItems = 500;

/// 弹幕 WS 连接状态（web 字面量联合 `"connecting" | "online" | "offline"`）。
enum AylaLiveWsConnection { connecting, online, offline }

/// 按 id 去重后按 `created_at` 升序，再按 [kAylaDanmakuMaxItems] 截断（保留最新）。
List<AylaLiveDanmaku> normalizeDanmaku(List<AylaLiveDanmaku> list) {
  final Set<String> seen = <String>{};
  final List<AylaLiveDanmaku> deduped = <AylaLiveDanmaku>[];
  for (final AylaLiveDanmaku item in list) {
    if (!seen.add(item.id)) continue;
    deduped.add(item);
  }
  deduped.sort(
    (AylaLiveDanmaku a, AylaLiveDanmaku b) =>
        a.createdAt.compareTo(b.createdAt),
  );
  if (deduped.length > kAylaDanmakuMaxItems) {
    return deduped.sublist(deduped.length - kAylaDanmakuMaxItems);
  }
  return deduped;
}

/// live 全局状态（登录周期内单例；登出时 [reset]）。
class AylaLiveState extends ChangeNotifier {
  final Map<String, AylaLiveChannelSnapshot> _channels =
      <String, AylaLiveChannelSnapshot>{};
  AylaLiveChannelSnapshot? _currentChannel;
  AylaLiveSrsStatus? _srsStatus;
  List<AylaLiveDanmaku> _danmaku = <AylaLiveDanmaku>[];
  int? _viewerCount;
  List<AylaLiveViewer> _viewers = <AylaLiveViewer>[];
  bool _currentLoading = false;
  String? _currentError;
  String? _currentPlayerError;
  AylaLiveWsConnection _wsConnection = AylaLiveWsConnection.offline;

  /// 频道表（房内页/热更新投影；排序归各页 `AylaPagedList`）。
  Map<String, AylaLiveChannelSnapshot> get channels =>
      Map<String, AylaLiveChannelSnapshot>.unmodifiable(_channels);

  AylaLiveChannelSnapshot? channelOf(String? channelId) =>
      channelId == null ? null : _channels[channelId];

  AylaLiveChannelSnapshot? get currentChannel => _currentChannel;
  AylaLiveSrsStatus? get srsStatus => _srsStatus;

  /// 实时弹幕队列（升序、按 id 去重、定长截断）。
  List<AylaLiveDanmaku> get danmaku =>
      List<AylaLiveDanmaku>.unmodifiable(_danmaku);

  /// 在看人数；null = **读不到**（不写 0）。
  int? get viewerCount => _viewerCount;

  /// 在看观众预览（后端上限 12 位）。
  List<AylaLiveViewer> get viewers =>
      List<AylaLiveViewer>.unmodifiable(_viewers);

  bool get currentLoading => _currentLoading;
  String? get currentError => _currentError;
  String? get currentPlayerError => _currentPlayerError;
  AylaLiveWsConnection get wsConnection => _wsConnection;

  // ---------------- 列表投影（web upsertChannel / removeChannel / updateChannelStatus） ----------------

  /// 插入或更新（web `upsertChannel`：已存在则**整体替换**，不存在则追加）。
  void upsertChannel(AylaLiveChannelSnapshot channel) {
    _channels[channel.id] = channel;
    if (_currentChannel?.id == channel.id) _currentChannel = channel;
    notifyListeners();
  }

  /// 移除（web `removeChannel`：若移除的是当前直播间，当前直播间清空）。
  void removeChannel(String channelId) {
    final bool wasCurrent = _currentChannel?.id == channelId;
    _channels.remove(channelId);
    if (wasCurrent) {
      _currentChannel = null;
      _srsStatus = null;
      _danmaku = <AylaLiveDanmaku>[];
      _viewerCount = null;
      _viewers = <AylaLiveViewer>[];
    }
    notifyListeners();
  }

  /// 乐观标记变更（web `updateChannelStatus`）。
  void updateChannelStatus(String channelId, AylaLiveStatus? status) {
    final AylaLiveChannelSnapshot? prev = _channels[channelId];
    if (prev == null) return;
    _channels[channelId] = prev.patch(status: status);
    if (_currentChannel?.id == channelId) {
      _currentChannel = _channels[channelId];
    }
    notifyListeners();
  }

  /// 按频道 id patch 在看人数（chat WS `live.viewers.changed`；**不参与排序**）。
  ///
  /// 未加载该频道的客户端没有对应条目 ⇒ 自然为空操作（web 原话）。
  void patchViewerCount(String channelId, int count) {
    bool changed = false;
    final AylaLiveChannelSnapshot? prev = _channels[channelId];
    if (prev != null && prev.viewerCount != count) {
      _channels[channelId] = prev.patch(viewerCount: count);
      changed = true;
    }
    if (_currentChannel?.id == channelId && _viewerCount != count) {
      _viewerCount = count;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // ---------------- 当前直播间（web current.*） ----------------

  void setCurrentChannel(AylaLiveChannelSnapshot? channel) {
    _currentChannel = channel;
    notifyListeners();
  }

  void setSrsStatus(AylaLiveSrsStatus? status) {
    if (_srsStatus == status) return;
    _srsStatus = status;
    notifyListeners();
  }

  /// 房内在看人数/预览（弹幕 WS `viewers` 帧或 REST 快照；**仅对当前直播间生效**）。
  void setViewers(String channelId, int count, List<AylaLiveViewer> viewers) {
    bool changed = false;
    if (_currentChannel?.id == channelId) {
      _viewerCount = count;
      _viewers = viewers;
      changed = true;
    }
    final AylaLiveChannelSnapshot? prev = _channels[channelId];
    if (prev != null && prev.viewerCount != count) {
      _channels[channelId] = prev.patch(viewerCount: count);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 在看人数未知（presence 不可用）：**清空人数而不写 0**。
  void clearViewers() {
    _viewerCount = null;
    _viewers = <AylaLiveViewer>[];
    notifyListeners();
  }

  /// 追加单条弹幕（WS 回帧），按 id 去重、定长截断。
  void appendDanmaku(AylaLiveDanmaku item) {
    _danmaku = normalizeDanmaku(<AylaLiveDanmaku>[..._danmaku, item]);
    notifyListeners();
  }

  void setDanmaku(List<AylaLiveDanmaku> items) {
    _danmaku = normalizeDanmaku(items);
    notifyListeners();
  }

  void clearDanmaku() {
    if (_danmaku.isEmpty) return;
    _danmaku = <AylaLiveDanmaku>[];
    notifyListeners();
  }

  void setCurrentLoading(bool loading) {
    if (_currentLoading == loading) return;
    _currentLoading = loading;
    notifyListeners();
  }

  void setCurrentError(String? error) {
    if (_currentError == error) return;
    _currentError = error;
    notifyListeners();
  }

  void setCurrentPlayerError(String? error) {
    if (_currentPlayerError == error) return;
    _currentPlayerError = error;
    notifyListeners();
  }

  void setWsConnection(AylaLiveWsConnection connection) {
    if (_wsConnection == connection) return;
    _wsConnection = connection;
    notifyListeners();
  }

  /// 退房清理：清当前直播间、弹幕与会话 UI 状态（**保留大厅列表**；web `clearCurrent`）。
  void clearCurrent() {
    _currentChannel = null;
    _srsStatus = null;
    _danmaku = <AylaLiveDanmaku>[];
    _viewerCount = null;
    _viewers = <AylaLiveViewer>[];
    _wsConnection = AylaLiveWsConnection.offline;
    _currentLoading = false;
    _currentError = null;
    _currentPlayerError = null;
    notifyListeners();
  }

  /// 登出/账号切换：全清（web `reset`）。
  void reset() {
    _channels.clear();
    clearCurrent();
  }

  bool _disposed = false;

  /// 是否已被 ProviderScope 回收。
  ///
  /// 页面卸载时**会话的清状态动作被排进 microtask**（见 `live_support.dart` 的
  /// `detachView` 注释）—— 那时容器可能已经先一步回收本状态 ⇒ 调用方必须先问这一句，
  /// 否则会命中 `ChangeNotifier` 的 "used after being disposed"（实测踩过）。
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
