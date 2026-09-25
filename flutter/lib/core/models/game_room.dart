/// 桌游域模型 —— 与 web `Ayla/web/src/api/types.ts` 的 `GameRoomMember` /
/// `GameRoom` 以及 `components/cards/cardData.ts` 的 `GameCardData` 逐条同源。
///
/// 纪律（沿用 chat / social 域口径）：JSON 键名与后端一致（snake_case）；
/// 缺失就是缺失（null），不造默认值；**未知枚举值返回 null**（不 fallback）。
library;

import 'user_public.dart';
import 'visibility.dart';

/// 桌游室状态（`types.ts:1345–1346`：waiting / playing / ended）。
enum AylaGameRoomStatus {
  waiting,
  playing,
  ended;

  /// 后端字段值。
  String get wire => name;

  /// 卡片状态 tag 文案（`GameRoomCard.tsx:41` 的三元链：
  /// playing → 对局中；ended → 已结束；其余 → 等待中）。
  ///
  /// ⚠️ tag 的**颜色档只看 playing**（`GameRoomCard.tsx:40`：
  /// `playing ? "is-playing" : "is-waiting"`）—— ended 走的是 waiting 档。
  String get label => switch (this) {
        AylaGameRoomStatus.playing => '对局中',
        AylaGameRoomStatus.ended => '已结束',
        AylaGameRoomStatus.waiting => '等待中',
      };

  /// 解析；未知值 → null（不伪造档位）。
  static AylaGameRoomStatus? parse(Object? raw) => switch (raw) {
        'waiting' => AylaGameRoomStatus.waiting,
        'playing' => AylaGameRoomStatus.playing,
        'ended' => AylaGameRoomStatus.ended,
        _ => null,
      };
}

/// 桌游室成员（`types.ts:1324–1330` `GameRoomMember`）。
class AylaGameRoomMember {
  const AylaGameRoomMember({
    required this.id,
    required this.userId,
    required this.user,
    this.seat,
    this.joinedAt,
  });

  /// 成员行 id。
  final int id;

  /// 成员用户 id（`user_id`）——房主控制里用于排除自己（tsx:155）。
  final String userId;

  /// 成员用户资料（`user`）。
  final AylaUserPublic user;

  /// 座位号（`seat`）。
  final int? seat;

  /// 加入时间（`joined_at`）。
  final String? joinedAt;

  /// 展示名：nickname 优先、其次 username（tsx:156 的 `||` 链）。
  String? get displayName => user.displayName;

  /// 解析；缺 `user` 视为非法 → null。
  static AylaGameRoomMember? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final AylaUserPublic? user = AylaUserPublic.fromJson(raw['user']);
    if (id == null || user == null) return null;
    final Object? seat = raw['seat'];
    return AylaGameRoomMember(
      id: id is int ? id : int.tryParse(id.toString()) ?? 0,
      userId: raw['user_id']?.toString() ?? user.id,
      user: user,
      seat: seat is int ? seat : int.tryParse(seat?.toString() ?? ''),
      joinedAt: raw['joined_at']?.toString(),
    );
  }
}

/// 桌游室（`types.ts:1333–1352` `GameRoom`，后端 `GameRoomSerializer`）。
class AylaGameRoom {
  const AylaGameRoom({
    required this.id,
    required this.name,
    required this.owner,
    required this.ownerId,
    required this.status,
    this.visibility,
    this.group,
    this.groupName,
    this.allowedGroupIds = const <String>[],
    this.allowedGroupNames = const <String>[],
    this.gameType,
    this.memberCount = 0,
    this.isOwner = false,
    this.isMember = false,
    this.createdAt,
  });

  final int id;
  final String name;

  /// 房主资料（`owner`）。
  final AylaUserPublic owner;

  /// 房主用户 id（`owner_id`；`is_owner` 之外的第二个判据，tsx:35）。
  final String ownerId;

  /// 状态（`status`）。
  final AylaGameRoomStatus? status;

  /// 可见性（未知值 → null）。
  final AylaPostVisibility? visibility;

  /// 归属群 id（`group`）。
  final String? group;

  /// 归属群名（`group_name`；旧数据标签回退用）。
  final String? groupName;

  /// 白名单群 id（`allowed_group_ids`）。
  final List<String> allowedGroupIds;

  /// 白名单群名（`allowed_group_names`）。
  final List<String> allowedGroupNames;

  /// 玩法类型（`game_type`；默认 boardgame，玩法后续）。
  final String? gameType;

  /// 人数（`member_count`）。
  final int memberCount;

  /// 当前用户是否房主（`is_owner`）。
  final bool isOwner;

  /// 当前用户是否在房内（`is_member`）。
  final bool isMember;

  /// 创建时间（`created_at`）。
  final String? createdAt;

  /// 房主展示名（tsx:150 的 `nickname || username`）。
  String? get ownerDisplayName => owner.displayName;

  /// 解析；缺 `id`/`name` 视为非法 → null。
  static AylaGameRoom? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    if (id == null || name == null) return null;
    final String nameText = name.toString();
    if (nameText.isEmpty) return null;
    return AylaGameRoom(
      id: id is int ? id : int.tryParse(id.toString()) ?? 0,
      name: nameText,
      owner: AylaUserPublic.fromJson(raw['owner']) ??
          AylaUserPublic(id: raw['owner_id']?.toString() ?? ''),
      ownerId: raw['owner_id']?.toString() ?? '',
      status: AylaGameRoomStatus.parse(raw['status']),
      visibility: AylaPostVisibility.parse(raw['visibility'] as String?),
      group: raw['group']?.toString(),
      groupName: raw['group_name']?.toString(),
      allowedGroupIds: _stringList(raw['allowed_group_ids']),
      allowedGroupNames: _stringList(raw['allowed_group_names']),
      gameType: raw['game_type']?.toString(),
      memberCount: int.tryParse(raw['member_count']?.toString() ?? '') ?? 0,
      isOwner: raw['is_owner'] == true,
      isMember: raw['is_member'] == true,
      createdAt: raw['created_at']?.toString(),
    );
  }
}

/// 卡片投影（`components/cards/cardData.ts:11`
/// `GameCardData = Partial<Omit<GameRoom, "id">> & { id; name }`）。
///
/// 与 [AylaGameRoom] 分开的理由同 live 域（`AylaLiveCardData`）：列表/搜索结果
/// 常常只带摘要字段，`Partial` 语义下**缺就是缺**——卡片按缺席渲染，
/// 不替后端补默认值。页面层负责 JSON → 本投影的映射。
class AylaGameCardData {
  const AylaGameCardData({
    required this.id,
    required this.name,
    this.status,
    this.owner,
    this.memberCount,
    this.visibility,
    this.allowedGroupNames = const <String>[],
    this.groupName,
  });

  /// 房间 id（web `string | number`）。
  final String id;

  /// 房间名。
  final String name;

  /// 状态（null → 不渲染 tag，tsx:40）。
  final AylaGameRoomStatus? status;

  /// 房主（null → 不渲染房主行，tsx:43）。
  final AylaUserPublic? owner;

  /// 人数（null → 不渲染「N 人」，tsx:45 的 `typeof === "number"` 守卫）。
  final int? memberCount;

  /// 可见性（null → 来源标签为空数组，`cardVisibilityLabels` 语义）。
  final AylaPostVisibility? visibility;

  /// 白名单群名（可与公开/好友叠加）。
  final List<String> allowedGroupNames;

  /// 归属群名（旧数据回退）。
  final String? groupName;

  /// 房主展示名（tsx:43 的 `nickname || username`）。
  String? get ownerDisplayName => owner?.displayName;

  /// 来源标签（web `cardVisibilityLabels(room)` → `getVisibilityLabels`）。
  ///
  /// ⚠️ 转发函数先判 `item.visibility`（`cardData.ts:14–16`）：
  /// **visibility 缺失 ⇒ 空数组**，不走 [aylaVisibilityLabels] 自己的兜底
  /// （那个兜底只服务 `visibility === "group"` 且群名为空的旧数据）。
  List<String> get visibilityLabels => visibility == null
      ? const <String>[]
      : aylaVisibilityLabels(
          visibility: visibility,
          allowedGroupNames: allowedGroupNames,
          groupName: groupName,
        );
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if (item != null) item.toString(),
  ];
}
