/// 直播间频道快照 —— web `LiveChannelDescriptor` 在 Flutter 侧的投影（共享数据类）。
///
/// 为什么单独一个类型：建播表单（`LiveCreate`）与控制台资料栏（`LiveOwnerPanel`）都需要
/// **描述/可见性/白名单群/推流三址**等字段，而 B2-2 的 `AylaLiveCardData` 只承载列表卡所需
/// （标题/封面/状态/人数/主播名）——**不改动已验收的那个类**（跨组件改动需单独批准），
/// 由页面层在两处之间映射。
///
/// ## 公开面
/// `AylaLiveChannelSnapshot`

library;

import '../../core/models/visibility.dart'
    show AylaPostVisibility, aylaVisibilityLabels;
import 'live_hall.dart' show AylaLiveCardData, AylaLiveStatus;

/// 直播间频道快照（字段名对齐 web `api/types.ts` 的 `LiveChannelDescriptor`）。
class AylaLiveChannelSnapshot {
  const AylaLiveChannelSnapshot({
    required this.id,
    required this.title,
    this.description = '',
    this.cover,
    this.status,
    this.ownerId = '',
    this.ownerNickname,
    this.isOwner = false,
    this.visibility,
    this.allowedGroupIds = const <String>[],
    this.group,
    this.rtmpUrl,
    this.streamKey,
    this.flvUrl,
    this.hlsUrl,
    this.groupName,
    this.allowedGroupNames = const <String>[],
    this.viewerCount,
    this.startedAt,
    this.endedAt,
    this.createdAt,
  });

  /// 频道 id（web `id: string | number`）。
  final String id;

  /// 标题。
  final String title;

  /// 介绍（web `description: string | null`）。
  final String description;

  /// 封面地址（`/api/v1/media/...`）。
  final String? cover;

  /// 归属用户 id（web `owner_id`）。
  final String ownerId;

  /// 主播昵称（web `owner_nickname`）。
  final String? ownerNickname;

  /// 是否本人拥有（web `is_owner`；控制台资料栏/推流地址仅 owner 渲染）。
  final bool isOwner;

  /// 状态（live / idle / ended）。
  final AylaLiveStatus? status;

  /// 可见性（后端单值：public / friends / group）。
  final String? visibility;

  /// 白名单群 id（多选的白名单，与 public/friends 可叠加）。
  final List<String> allowedGroupIds;

  /// 归属群 id（群内创建时非空；一级 tab 创建为 null）。
  final String? group;

  /// 推流地址（owner 可见；**仅内存展示**）。
  final String? rtmpUrl;

  /// 串流密钥（推流指纹：**不打日志、不持久化**，tsx 6）。
  final String? streamKey;

  /// FLV 播放地址。
  final String? flvUrl;

  /// `hls_url`（**全员可见**，HLS 播放地址；PoC-B 三端实测的播放源）。
  final String? hlsUrl;

  /// `group_name`（S1：群归属名）。
  final String? groupName;

  /// `allowed_group_names`（可见性标签用）。
  final List<String> allowedGroupNames;

  /// `viewer_count`（运行事实）；**null = presence 存储不可用（未知）**，不写 0。
  final int? viewerCount;

  /// `started_at` / `ended_at` / `created_at`（侧栏排序 + 活动事件时间）。
  final String? startedAt;
  final String? endedAt;
  final String? createdAt;

  /// 可见性标签（`cardVisibilityLabels(channel)` → `getVisibilityLabels`；同源纯函数）。
  List<String> get visibilityLabels => visibility == null
      ? const <String>[]
      : aylaVisibilityLabels(
          visibility: AylaPostVisibility.parse(visibility),
          allowedGroupNames: allowedGroupNames,
          groupName: groupName,
        );

  /// 后端响应 → 快照（**缺席即缺席**；未知枚举 → null）。
  ///
  /// 2026-09-28（房内页批次）纯增量扩档：房内页/控制台需要从 `GET /live/channels/<id>/`
  /// 与目录页条目构造本类，而 B2-6 交付的版本只有构造器（列表卡走
  /// `AylaLiveCardData.fromJson`、不需要它）⇒ **不新建平行类型**，在本类上补齐解析
  /// 与局部 patch（既有字段与默认值一字未动）。
  static AylaLiveChannelSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? title = raw['title'];
    if (id == null || title == null) return null;
    final String idText = id.toString();
    if (idText.isEmpty) return null;
    final String coverText = raw['cover']?.toString() ?? '';
    return AylaLiveChannelSnapshot(
      id: idText,
      title: title.toString(),
      description: raw['description']?.toString() ?? '',
      cover: coverText.isEmpty ? null : coverText,
      status: AylaLiveStatus.parse(raw['status']?.toString()),
      ownerId: raw['owner_id']?.toString() ?? '',
      ownerNickname: raw['owner_nickname']?.toString(),
      isOwner: raw['is_owner'] == true,
      visibility: raw['visibility']?.toString(),
      allowedGroupIds: _stringList(raw['allowed_group_ids']),
      allowedGroupNames: _stringList(raw['allowed_group_names']),
      group: raw['group']?.toString(),
      groupName: raw['group_name']?.toString(),
      rtmpUrl: raw['rtmp_url']?.toString(),
      streamKey: raw['stream_key']?.toString(),
      flvUrl: raw['flv_url']?.toString(),
      hlsUrl: raw['hls_url']?.toString(),
      viewerCount: (raw['viewer_count'] as num?)?.toInt(),
      startedAt: raw['started_at']?.toString(),
      endedAt: raw['ended_at']?.toString(),
      createdAt: raw['created_at']?.toString(),
    );
  }

  /// 局部替换（`status` / `viewer_count` 两个**瞬态投影**；目录热更新与在看人数帧用）。
  AylaLiveChannelSnapshot patch({
    AylaLiveStatus? status,
    int? viewerCount,
  }) =>
      AylaLiveChannelSnapshot(
        id: id,
        title: title,
        description: description,
        cover: cover,
        status: status ?? this.status,
        ownerId: ownerId,
        ownerNickname: ownerNickname,
        isOwner: isOwner,
        visibility: visibility,
        allowedGroupIds: allowedGroupIds,
        allowedGroupNames: allowedGroupNames,
        group: group,
        groupName: groupName,
        rtmpUrl: rtmpUrl,
        streamKey: streamKey,
        flvUrl: flvUrl,
        hlsUrl: hlsUrl,
        viewerCount: viewerCount ?? this.viewerCount,
        startedAt: startedAt,
        endedAt: endedAt,
        createdAt: createdAt,
      );

  /// JSON 字符串数组（缺席 ⇒ 空数组；不造占位项 —— 与库内 4 处 `_stringList` 同口径）。
  static List<String> _stringList(Object? raw) => <String>[
        for (final Object? item in (raw as List<Object?>? ?? const <Object?>[]))
          if (item != null) item.toString(),
      ];

  /// 列表卡投影（`AylaLiveCardData`；复用大厅/侧栏卡件）。
  AylaLiveCardData get card => AylaLiveCardData(
        id: id,
        title: title,
        cover: cover,
        status: status,
        ownerId: ownerId,
        ownerNickname: ownerNickname,
        viewerCount: viewerCount,
        visibility: AylaPostVisibility.parse(visibility),
        allowedGroupNames: allowedGroupNames,
        groupName: groupName,
      );
}
