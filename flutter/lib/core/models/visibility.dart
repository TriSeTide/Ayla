/// 可见性（来源标识）共用模型 —— 对齐 web `Ayla/web/src/utils/visibility.ts`
/// 与 `api/types.ts` 的可见性字面量联合。
///
/// **为什么是共用件**：web 的 `visibility: "public" | "friends" | "group"` 与
/// `getVisibilityLabels()` 是**跨域共用**的——帖子（`Post.visibility`）、
/// 语音频道（`types.ts:872` `VoiceChannelDescriptor.visibility`）、直播频道
/// （`LiveChannelDescriptor.visibility`）用的是同一个联合与同一个生成函数
/// （`components/cards/cardData.ts` 的 `cardVisibilityLabels` 只是转发）。
/// 故这里承载共用语义，`post.dart` / 后续 voice/live 模型都从这里取。
///
/// 名称沿用历史（`AylaPostVisibility` / 原文件 `post.dart`），以免动既有调用点
/// ——与 `media_kind.dart` 的抽出同口径（2026-09-20 先例）。
library;

/// 可见性（`types.ts:1227`：public / friends / group）。
///
/// 注意：**group 是独立维度**（白名单 allowed_groups），与 public/friends 可叠加；
/// 后端单值字段只是准入映射，标签由 [aylaVisibilityLabels] 生成。
enum AylaPostVisibility {
  public,
  friends,
  group;

  static AylaPostVisibility? parse(String? raw) => switch (raw) {
        'public' => AylaPostVisibility.public,
        'friends' => AylaPostVisibility.friends,
        'group' => AylaPostVisibility.group,
        _ => null,
      };

  /// 后端字段值。
  String get wire => name;
}

/// 可见性标签（web `utils/visibility.ts getVisibilityLabels` 逐条同源）。
///
/// - public → ["公开"]；friends → ["好友"]（二者互斥，最多一个）；
/// - `allowedGroupNames` → 白名单群名（**可与公开/好友叠加**：「公开+群」）；
/// - group 可见且无白名单名 → 回退 `groupName`（旧数据兼容）；
/// - 一条都生不出来时按 visibility 兜底（friends→好友 / public→公开 / 否则群可见）。
List<String> aylaVisibilityLabels({
  AylaPostVisibility? visibility,
  List<String> allowedGroupNames = const <String>[],
  String? groupName,
}) {
  final List<String> labels = <String>[];
  if (visibility == AylaPostVisibility.public) {
    labels.add('公开');
  } else if (visibility == AylaPostVisibility.friends) {
    labels.add('好友');
  }
  if (allowedGroupNames.isNotEmpty) {
    labels.addAll(allowedGroupNames);
  } else if (visibility == AylaPostVisibility.group &&
      (groupName ?? '').isNotEmpty) {
    labels.add(groupName!);
  }
  if (labels.isEmpty) {
    if (visibility == AylaPostVisibility.friends) return <String>['好友'];
    if (visibility == AylaPostVisibility.public) return <String>['公开'];
    return <String>['群可见'];
  }
  return labels;
}
