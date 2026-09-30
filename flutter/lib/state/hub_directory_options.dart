/// 三个大厅（语音 / 直播 / 桌游）的**分类档 → 目录 options**（单一事实源）。
///
/// ## 为什么要有这个文件（用户 2026-09-30：「一次性预加载所有，保证流畅体验」）
/// `AylaDirectoryOptions` 的**每个字段都进 `directoryKey`**（web `stores/directory.ts` 的
/// `directoryKey`）⇒ **预加载与页面必须构造出完全相同的组合**，否则 store 里是两条 record、
/// 预取命中不了（本项目已踩过：13 号记的「预加载形同虚设」）。
/// 此前 options 内联在三个页面里各写一份 ⇒ 预加载不可能逐档对齐。
/// 现在**页面与 `app_preload.dart` 都调用本文件的函数**，逐档对齐是结构性保证。
///
/// ## 与 web 的关系（有意偏离，仅此一处）
/// web `appInit.ts:36–39` 只预取「全部」档（`loadDirectory(kind)`，无 options），
/// 切分类 tab 时各自取页。用户明确要求「**一次性预加载所有**」⇒ 这里把**全部档**都预取
/// （语音 5 档 / 直播 6 档 / 桌游 6 档 = 17 个请求，全部并发），代价是启动请求数上升，
/// 换来「切分类不闪骨架、零等待」。
library;

import '../core/models/post.dart' show AylaPostVisibility;
import 'directory_events.dart' show AylaDirectoryKind;
import 'directory_store.dart' show AylaDirectoryOptions;

/// 语音大厅的分类档（= `VoiceHubPage.filters` 的 key 序列）。
const List<String> kAylaVoiceHubFilters = <String>[
  'all',
  'public',
  'friends',
  'occupied',
  'mine',
];

/// 直播大厅的分类档（= `LiveHubPage.filters`）。
const List<String> kAylaLiveHubFilters = <String>[
  'all',
  'live',
  'public',
  'friends',
  'offline',
  'mine',
];

/// 桌游大厅的分类档（= `GamesHubPage.filters`）。
const List<String> kAylaGamesHubFilters = <String>[
  'all',
  'public',
  'friends',
  'mine',
  'waiting',
  'playing',
];

/// 某 kind 的全部档。
List<String> aylaHubFiltersOf(AylaDirectoryKind kind) {
  switch (kind) {
    case AylaDirectoryKind.voice:
      return kAylaVoiceHubFilters;
    case AylaDirectoryKind.live:
      return kAylaLiveHubFilters;
    case AylaDirectoryKind.game:
      return kAylaGamesHubFilters;
  }
}

/// 构造与页面**逐字段一致**的目录 options。
///
/// 逐条对照页面里的内联构造（`voice_hub_page.dart` / `live_hub_page.dart` /
/// `games_hub_page.dart` 的 `_start()`）：
/// · `owner` —— 只有「我的」档带当前用户 id；
/// · `friends` / `occupied` —— 各自的档才置位（`occupied` 仅语音有）；
/// · `visibility` —— 「公开」档显式传 `public`（其余 null）；
/// · `status` —— 直播的 `live/offline`、桌游的 `waiting/playing`。
AylaDirectoryOptions aylaHubDirectoryOptions({
  required AylaDirectoryKind kind,
  required String filter,
  required String? userId,
}) {
  String? status;
  if (kind == AylaDirectoryKind.live) {
    status = filter == 'live'
        ? 'live'
        : filter == 'offline'
            ? 'offline'
            : null;
  } else if (kind == AylaDirectoryKind.game) {
    status = filter == 'waiting'
        ? 'waiting'
        : filter == 'playing'
            ? 'playing'
            : null;
  }
  return AylaDirectoryOptions(
    filter: filter,
    owner: filter == 'mine' ? userId : null,
    friends: filter == 'friends',
    occupied: kind == AylaDirectoryKind.voice && filter == 'occupied',
    visibility: filter == 'public' ? AylaPostVisibility.public : null,
    status: status,
  );
}
