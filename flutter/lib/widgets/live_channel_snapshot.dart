/// 直播间频道快照 —— web `LiveChannelDescriptor` 在 Flutter 侧的投影（共享数据类）。
///
/// 为什么单独一个类型：建播表单（`LiveCreate`）与控制台资料栏（`LiveOwnerPanel`）都需要
/// **描述/可见性/白名单群/推流三址**等字段，而 B2-2 的 `AylaLiveCardData` 只承载列表卡所需
/// （标题/封面/状态/人数/主播名）——**不改动已验收的那个类**（跨组件改动需单独批准），
/// 由页面层在两处之间映射。
library;

import 'live_hall.dart' show AylaLiveStatus;

/// 直播间频道快照（字段名对齐 web `api/types.ts` 的 `LiveChannelDescriptor`）。
class AylaLiveChannelSnapshot {
  const AylaLiveChannelSnapshot({
    required this.id,
    required this.title,
    this.description = '',
    this.cover,
    this.status,
    this.visibility,
    this.allowedGroupIds = const <String>[],
    this.group,
    this.rtmpUrl,
    this.streamKey,
    this.flvUrl,
  });

  /// 频道 id（web `id: string | number`）。
  final String id;

  /// 标题。
  final String title;

  /// 介绍（web `description: string | null`）。
  final String description;

  /// 封面地址（`/api/v1/media/...`）。
  final String? cover;

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
}
