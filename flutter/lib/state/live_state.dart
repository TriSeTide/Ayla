/// live 全局状态 —— web `stores/live.ts`（271 行）的 Flutter 等价物。
///
/// ## 逐字段对应（web `stores/live.ts`）
/// | 本类 | web | 口径 |
/// |---|---|---|
/// | [channels] | `channels` | 列表投影（**排序归各页**；本表给房内页/热更新用） |
/// | [currentChannel] / [srsStatus] / [danmaku] / [viewerCount] / [viewers] | `current.*` | 当前直播间四件套 |
/// | [currentLoading] / [currentError] / [currentPlayerError] | 同名 | 由会话运行时写入 |
/// | [wsConnection] | `wsConnection` | 弹幕 WS 连接状态 |
/// | [miniPlayer] | `miniPlayer` | 手机端浮动小窗**UI 投影**（唯一 owner；由运行时显式管理） |
///
/// ## 纪律（web 文件头原话）
/// - `srsStatus` 优先；null（未查询）时 UI 用乐观 `status` 兜底**并标注**；
/// - 弹幕按 id 去重、定长截断（[kAylaDanmakuMaxItems] = 500，权威历史在后端可随时再拉）；
/// - **在看人数是瞬态投影**：null = 读不到（presence 存储不可用）⇒ UI 隐藏人数，
///   **不用 0 冒充"没人看"**（`apps/live/viewers.py` 的 503 语义）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/api/live_api.dart';
import '../core/storage/ayla_storage_paths.dart' show aylaProfileDirectory;
import '../widgets/live/live_channel_snapshot.dart';
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 实时弹幕队列上限（web `stores/live.ts:20` `DANMAKU_MAX_ITEMS`）。
const int kAylaDanmakuMaxItems = 500;

// ==================== 直播静音偏好（web `stores/live.ts` 的 LIVE_*_MUTED_STORAGE_KEY） ====================

/// 观众端（看别人的直播）静音偏好键（web `LIVE_MUTED_STORAGE_KEY`，值 "1" = 静音）。
///
/// 键名与 web 完全同名同语义：**无记录 = 有声**（用户来看直播就是要听声音）。
const String kAylaLiveMutedKey = 'ayla.live.muted';

/// 开播控制台（自己的播）静音偏好键（web `LIVE_OWNER_MUTED_STORAGE_KEY`）。
///
/// 与观众端分开存：主播在自己控制台静音只是「控制台不要出声」，不能把他去别人直播间
/// 的观看偏好也改成静音；反之亦然（design.md §12.7.6.4 的裁决）。
const String kAylaLiveOwnerMutedKey = 'ayla.live.owner.muted';

/// 落盘文件名（web 用 localStorage；Flutter 无 localStorage ⇒ 与 `home_prefs.dart`
/// 同一手法：应用支持目录下一个同名 JSON 文件，键名原样保留）。
const String kAylaLivePrefsFileName = 'ayla_live_prefs.json';

/// 各端静音偏好的缺省值（web `defaultLiveMuted`）：观众端有声、开播端静音。
///
/// ## 为什么开播端默认静音（用户 2026-11-04 原话）
/// 「web 和 Flutter 的开播界面，默认把声音关闭」——主播开播时同一路流会从 SRS 回环
/// 到自己的播放器，默认出声等于把自己的声音延时回授一遍（回声/啸叫风险），
/// 且主播此刻关注的是推流状态与弹幕，不是听自己。
bool aylaDefaultLiveMuted({required bool owner}) => owner;

/// 偏好读写的注入点（测试替换；生产恒 null ⇒ 走 [aylaReadLiveMuted] 的磁盘实现）。
///
/// 为什么是函数变量而不是参数：偏好是**跨会话/跨页面**的进程级事实（web 就是模块级
/// localStorage），而读取点在会话层（`pages/live_support.dart`）、写入点在用户手势里，
/// 两者之间没有天然的注入通路。
bool Function({required bool owner})? aylaLiveMutedReader;
void Function({required bool muted, required bool owner})? aylaLiveMutedWriter;

/// 进程内的偏好缓存（读盘一次后常驻；写操作先改它再异步落盘）。
///
/// 为什么需要缓存：web 的 `localStorage.getItem` 是**同步**的 ⇒ 首帧就能拿到最终值；
/// Flutter 读盘是异步的，若每次读取都 `await`，播放器 attach 时偏好还没到位
/// ⇒ 第一帧按缺省值出声（开播端会漏一下自己的回授）。缓存让「已加载之后」的读取
/// 与 web 一样同步；未加载时按各端缺省值（两个缺省值本身就是正确答案）。
Map<String, String>? _livePrefsCache;

/// 读盘一次（幂等）。会话 `start()` 里 await 一次即可；失败静默（存储不可用 ⇒ 缺省值）。
Future<void> aylaLoadLiveMutePrefs() async {
  if (_livePrefsCache != null) return;
  try {
    final Directory dir = await aylaProfileDirectory();
    final File file =
        File(dir.path + Platform.pathSeparator + kAylaLivePrefsFileName);
    if (!file.existsSync()) {
      _livePrefsCache = <String, String>{};
      return;
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    _livePrefsCache = decoded is Map
        ? <String, String>{
            for (final MapEntry<Object?, Object?> e in decoded.entries)
              e.key.toString(): '${e.value}',
          }
        : <String, String>{};
  } catch (_) {
    // 存储不可用（无权限 / 文件损坏）⇒ 空表 ⇒ 各端缺省值（web 的 catch 同语义）。
    _livePrefsCache = <String, String>{};
  }
}

/// 测试注入：重置缓存（生产不要调）。
@visibleForTesting
void aylaResetLiveMutePrefsForTest() {
  _livePrefsCache = null;
}

/// 读取静音偏好（owner=true 读开播端，缺省静音；否则读观众端，缺省有声）。
///
/// 逐条对照 web `readLiveMuted`：
/// · 开播端：无记录 ⇒ 静音；记录 "0" ⇒ 有声（兼容将来「记住开声」的写法）；
/// · 观众端：只有 "1" 是静音，其余（含无记录 / 未知值）一律有声。
bool aylaReadLiveMuted({bool owner = false}) {
  final bool Function({required bool owner})? injected = aylaLiveMutedReader;
  if (injected != null) return injected(owner: owner);
  final Map<String, String>? prefs = _livePrefsCache;
  if (prefs == null) return aylaDefaultLiveMuted(owner: owner);
  if (owner) {
    final String? raw = prefs[kAylaLiveOwnerMutedKey];
    return raw == null ? aylaDefaultLiveMuted(owner: true) : raw != '0';
  }
  return prefs[kAylaLiveMutedKey] == '1';
}

/// 写入静音偏好（owner 语义同 [aylaReadLiveMuted]）。
///
/// 与 web `writeLiveMuted` 完全同语义：**取消静音时删除键**、不存 "0" ——
/// 避免「从没静音过」与「曾取消静音」变成两种需要迁移的状态；开播端由此得到一个
/// 明确的产品语义：取消静音只对当前这场生效，下次打开控制台仍回到缺省的静音。
/// 落盘 fire-and-forget，失败静默（偏好只在本会话内存生效，不阻断播放）。
void aylaWriteLiveMuted({required bool muted, bool owner = false}) {
  final void Function({required bool muted, required bool owner})? injected =
      aylaLiveMutedWriter;
  if (injected != null) {
    injected(muted: muted, owner: owner);
    return;
  }
  final String key = owner ? kAylaLiveOwnerMutedKey : kAylaLiveMutedKey;
  final Map<String, String> prefs =
      _livePrefsCache ??= <String, String>{};
  if (muted) {
    prefs[key] = '1';
  } else {
    prefs.remove(key);
  }
  final Map<String, String> snapshot = Map<String, String>.of(prefs);
  unawaited(_persistLiveMutePrefs(snapshot));
}

Future<void> _persistLiveMutePrefs(Map<String, String> prefs) async {
  try {
    final Directory dir = await aylaProfileDirectory();
    final File file =
        File(dir.path + Platform.pathSeparator + kAylaLivePrefsFileName);
    await file.writeAsString(jsonEncode(prefs));
  } catch (_) {
    // 存储不可用静默（web writeLiveMuted 的 catch 同语义）。
  }
}

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

/// 手机端浮动小窗状态（web `stores/live.ts:36–41` `MiniPlayerState`）。
///
/// 会话资源（HLS 播放器 / SRS 判定 / 弹幕 WS / video 视图）由会话运行时
/// （`pages/live_support.dart` 的 `AylaLiveRoomSession`）持有，这里只放 **UI 投影**；
/// `null` = 无小窗 —— **唯一 owner，同一时刻至多一个**（web 组件头原话）。
class AylaLiveMiniPlayerState {
  const AylaLiveMiniPlayerState({
    required this.channelId,
    required this.sourceRoute,
    this.channel,
  });

  /// 频道 id（web `channelId: number`）。
  final String channelId;

  /// 点回直播间时导航的目标路由（web `sourceRoute`：一级直播 `/live/:id`，
  /// 群内直播为群场景路由 `/group/:id/live`，开播控制台 `/live/start/:id`）。
  final String sourceRoute;

  /// 频道快照（web `channel: LiveChannelDescriptor | null`）。
  final AylaLiveChannelSnapshot? channel;

  /// 小窗标题（web `LiveMiniPlayer.tsx:195` `mini.channel?.title ?? "直播间"`）。
  String get title => channel?.title ?? '直播间';
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
  AylaLiveMiniPlayerState? _miniPlayer;

  /// 静音 UI 投影（web `stores/live.ts` 的 `muted`）。
  ///
  /// **权威偏好在 [aylaReadLiveMuted] / 平台播放器上**（与 web 一致：`muted` 是
  /// `liveSessionRuntime` 的投影，store 只负责让 UI 能重建）。读写口径：
  /// · 写：会话层（`pages/live_support.dart` 的 `setMuted`）在应用静音后调用 [setMuted]；
  /// · 读：`AylaLiveRoomBody` 把它递给 `AylaLivePlayer` 的音量键。
  bool _muted = false;

  /// 当前会话是否**开播控制台**语义（决定 `muted` 对应哪一套偏好；web `mutedOwner`）。
  bool _mutedOwner = false;

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

  /// 浮动小窗（null = 无小窗）。**唯一 owner**：同一时刻至多一个。
  AylaLiveMiniPlayerState? get miniPlayer => _miniPlayer;

  /// 当前是否静音（喇叭键的两态；见 [_muted]）。
  bool get muted => _muted;

  /// 当前会话是否为开播控制台语义（决定偏好键；见 [_mutedOwner]）。
  bool get mutedOwner => _mutedOwner;

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

  /// 更新静音 UI 投影（web `setMuted`）。
  ///
  /// ⚠️ **不写存储、不碰播放器**：偏好写入的唯一入口是会话层的用户手势
  /// （`pages/live_support.dart` 的 `setMuted`），播放器的静音由
  /// `HlsPlaybackController.setMuted` 应用。本方法只让 UI 能重建。
  void setMuted(bool muted) {
    if (_muted == muted) return;
    _muted = muted;
    notifyListeners();
  }

  /// 更新「当前端」语义（web `setMutedOwner`）：不改变 [muted]，只换投影口径。
  void setMutedOwner(bool owner) {
    if (_mutedOwner == owner) return;
    _mutedOwner = owner;
    notifyListeners();
  }

  /// 设置 / 清除浮动小窗（web `stores/live.ts:208` `setMiniPlayer`）。
  ///
  /// **整体替换** ⇒ 天然表达「同一时刻至多一个 owner」（不做增量合并）；
  /// 传 `null` 且当前已是 `null` 时是 no-op（关闭小窗可幂等重入）。
  void setMiniPlayer(AylaLiveMiniPlayerState? mini) {
    if (identical(_miniPlayer, mini)) return;
    _miniPlayer = mini;
    notifyListeners();
  }

  /// 退房清理：清当前直播间、弹幕与会话 UI 状态（**保留大厅列表**；web `clearCurrent`）。
  ///
  /// ⚠️ **不动 [miniPlayer]**：web `stores/live.ts:250` 原话「miniPlayer 由 runtime 显式
  /// 管理」—— 小窗由会话运行时置位/清理，退房清理不得顺手把它清掉（否则「离开房间页进小窗」
  /// 会被紧随其后的清状态抹平）。
  ///
  /// ⚠️ **同样不动 [muted]**：静音是用户偏好，跨直播间/跨场次保留 —— 换台不该让
  /// 声音突然炸出来（web `clearCurrent` 同款）。端语义（[mutedOwner]）回到缺省的
  /// 观众端：退房后没有会话，再进房由会话 `start()` 按新端重新确定。
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

  /// 登出/账号切换：全清（web `reset` —— 含 `miniPlayer: null`）。
  ///
  /// 静音回到**观众端已持久化的偏好**（web `reset` 的 `muted: readLiveMuted()`），
  /// 而不是硬编码缺省值：登出不该把用户已经选过的「我要静音」擦掉。
  void reset() {
    _channels.clear();
    _miniPlayer = null;
    _muted = aylaReadLiveMuted();
    _mutedOwner = false;
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
