/// 桌游全局 store —— web `stores/boardgame.ts`（99 行）的 Flutter 等价物。
///
/// ## 为什么需要它
/// web 的桌游房列表是**全站共享**的（`useBoardgameStore`），三处写、多处读：
/// - `ws/chat.ts:845–865` 的 `boardgame.room.created/updated/deleted` 三条帧直接 upsert/remove；
/// - `stores/directory.ts:313–317` 把桌游目录**取页结果**也 upsert 进同一个 store；
/// - `components/home/groupActivity.ts:120 / 165 / 306` 的群存在性角标与「新内容」排序读它。
///
/// Flutter 侧此前只有**页面级**目录（`AylaPagedList` 与 `AylaDirectoryStore` 的 record，
/// 随页面销毁），没有一份「跨页 + 由 WS 维护」的房间表 ⇒ 群活跃度投影里 `game` 源缺席
/// （`pages/group_support.dart` 文件头登记的偏离）。本件按 web 补齐。
///
/// ## 逐条对应（web 事实源）
/// | web | 行 | 本件 |
/// |---|---|---|
/// | 字段 `rooms` / `roomsLoading` / `error` / `lastFetched` | 11–15 | [AylaBoardgameStore] 同名字段 |
/// | `setRooms`（`created_at` 降序 + 落地 `lastFetched` + 清 error） | 49–55 | [AylaBoardgameStore.setRooms] |
/// | `setRoomsLoading` | 57 | 同 |
/// | `reconcileRooms`（REST 对账：**仅接受当前可见列表**） | 59–70 | 同 |
/// | `setError` | 72 | 同 |
/// | `upsertRoom`（存在则**原位替换**、不存在**插到列表头部**） | 74–84 | 同 |
/// | `removeRoom` | 86–89 | 同 |
/// | `reset` | 91 | 同 |
/// | `isBoardgameStale(maxAgeMs = 60_000)` | 95–98 | [AylaBoardgameStore.isStale] / [kAylaBoardgameFreshWindowMs] |
///
/// ## 与 web 的三处**有意**差异（都已核对，不是缺口）
/// 1. **`normalizeRoom` 不重复实现**（web 37–44）：web 的 `GameRoom` 是宽松 TS 类型
///    （`id: string | number`、`owner_id` 可能非字符串、`group: string | null`），
///    故 store 入口要做一次归一化。Flutter 的 [AylaGameRoom] 是**强类型**，且
///    `fromJson`（`core/models/game_room.dart:151–176`）在解析时已做过逐条等价转换：
///    `id` → int（`id is int ? id : int.tryParse(...) ?? 0`）、
///    `ownerId: raw['owner_id']?.toString() ?? ''`、`group: raw['group']?.toString()`
///    ⇒ 在 store 里再归一化是**空操作**，不写空壳函数冒充对齐。
/// 2. **`created_at` 缺席的排序位置**：web 的 `created_at` 是非空 `string`（后端必给）；
///    Flutter 模型是可空（缺席即 null，**不造时间戳**）⇒ 比较时按空串参与，
///    等价于「缺席排最后」。
/// 3. **稳定排序**：web 用 `Array.sort`（ES2019 起**稳定**）；Dart 的 `List.sort`
///    **不稳定** ⇒ 显式带原索引做次级比较（库内既有先例：
///    `pages/group_support.dart` 的 [aylaSortGroupsByActivity]）。
library;

import 'package:flutter/foundation.dart';

import '../core/models/game_room.dart' show AylaGameRoom;

/// store 数据新鲜窗口（web `isBoardgameStale` 默认 `60_000`，`stores/boardgame.ts:95`）。
const int kAylaBoardgameFreshWindowMs = 60000;

/// 桌游房全局状态（web `useBoardgameStore`，`stores/boardgame.ts:46`）。
class AylaBoardgameStore extends ChangeNotifier {
  List<AylaGameRoom> _rooms = <AylaGameRoom>[];
  bool _roomsLoading = false;
  String? _error;
  int? _lastFetched;

  /// 房间列表（顺序即 web 的顺序：取页/对账后按 `created_at` 降序，WS 新增插头部）。
  List<AylaGameRoom> get rooms => List<AylaGameRoom>.unmodifiable(_rooms);

  bool get roomsLoading => _roomsLoading;

  String? get error => _error;

  /// 最近一次**成功落地列表**的时间（毫秒；null = 从未取到）—— 见 [isStale]。
  int? get lastFetched => _lastFetched;

  /// 是否已取到过数据（决定首屏骨架 vs 列表）。
  bool get loaded => _lastFetched != null;

  /// 整表替换 —— web `setRooms`（49–55）。
  void setRooms(List<AylaGameRoom> rooms) {
    _rooms = List<AylaGameRoom>.unmodifiable(_sortedByCreatedAtDesc(rooms));
    _roomsLoading = false;
    _error = null;
    _lastFetched = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// REST 对账 —— web `reconcileRooms`（59–70）：**仅接受当前可见列表**
  /// （避免 WS 越权插入）。与 [setRooms] 的 body 相同，只有**语义**不同（调用方据此区分），
  /// 故保留两个入口，与 web 的两个 action 一一对应。
  void reconcileRooms(List<AylaGameRoom> rooms) {
    _rooms = List<AylaGameRoom>.unmodifiable(_sortedByCreatedAtDesc(rooms));
    _roomsLoading = false;
    _error = null;
    _lastFetched = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  void setRoomsLoading(bool loading) {
    if (_roomsLoading == loading) return;
    _roomsLoading = loading;
    notifyListeners();
  }

  void setError(String? error) {
    _error = error;
    notifyListeners();
  }

  /// WS 推送 / 目录落地：插入或更新房间 —— web `upsertRoom`（74–84）。
  ///
  /// **已存在则原位替换**（保持它在列表中的位置）；**不存在则插入到列表头部**
  /// （「新房间在列表头部」，web 74–84 的注释原话）。
  void upsertRoom(AylaGameRoom room) {
    final int index =
        _rooms.indexWhere((AylaGameRoom r) => r.id == room.id);
    if (index >= 0) {
      final List<AylaGameRoom> next = List<AylaGameRoom>.of(_rooms);
      next[index] = room;
      _rooms = List<AylaGameRoom>.unmodifiable(next);
    } else {
      _rooms = List<AylaGameRoom>.unmodifiable(<AylaGameRoom>[room, ..._rooms]);
    }
    notifyListeners();
  }

  /// WS 推送：从列表移除 —— web `removeRoom`（86–89）。
  void removeRoom(int roomId) {
    final int length = _rooms.length;
    final List<AylaGameRoom> next = <AylaGameRoom>[
      for (final AylaGameRoom r in _rooms)
        if (r.id != roomId) r,
    ];
    if (next.length == length) return;
    _rooms = List<AylaGameRoom>.unmodifiable(next);
    notifyListeners();
  }

  /// 数据是否过期 —— web `isBoardgameStale`（95–98）。
  ///
  /// `lastFetched` 缺席 ⇒ **true**（web 原话：`if (!lastFetched) return true`）——
  /// 从未取到就是过期，不把「未知」当「新鲜」。
  bool isStale({int maxAgeMs = kAylaBoardgameFreshWindowMs}) {
    final int? lastFetched = _lastFetched;
    if (lastFetched == null) return true;
    return DateTime.now().millisecondsSinceEpoch - lastFetched > maxAgeMs;
  }

  /// 登出 / 会话过期清空 —— web `reset`（91：`set({ ...INITIAL })`）。
  void reset() {
    _rooms = <AylaGameRoom>[];
    _roomsLoading = false;
    _error = null;
    _lastFetched = null;
    notifyListeners();
  }
}

/// `created_at` 降序（web 51 的 `b.created_at.localeCompare(a.created_at)`），
/// 同时间保持**原索引顺序**（Dart `List.sort` 不稳定，web `Array.sort` 稳定）。
List<AylaGameRoom> _sortedByCreatedAtDesc(List<AylaGameRoom> rooms) {
  final List<({AylaGameRoom room, int index})> rows =
      <({AylaGameRoom room, int index})>[
    for (int i = 0; i < rooms.length; i++) (room: rooms[i], index: i),
  ];
  rows.sort((({AylaGameRoom room, int index}) a, ({AylaGameRoom room, int index}) b) {
    final int byTime = _createdAtKey(b.room).compareTo(_createdAtKey(a.room));
    if (byTime != 0) return byTime;
    return a.index - b.index;
  });
  return <AylaGameRoom>[for (final ({AylaGameRoom room, int index}) r in rows) r.room];
}

/// 排序键：缺席（null）按空串参与 ⇒ 排在所有有值项之后（见库文档差异 2）。
String _createdAtKey(AylaGameRoom room) => room.createdAt ?? '';

/// 模块级单例 —— web `useBoardgameStore`（`stores/boardgame.ts:46`）的模块级 store 语义：
/// WS 帧桥、目录取页落地与群活跃度投影共用同一实例。
///
/// ⚠️ 不包 `ChangeNotifierProvider`：与 `aylaPostsStore` / `aylaDirectoryStore` 同因
/// （见 `state/directory_store.dart:642–651` 的实测记录）——页面直接持有本单例，
/// 用 `addListener` 订阅（zustand 的订阅语义的等价物）。
final AylaBoardgameStore aylaBoardgameStore = AylaBoardgameStore();
