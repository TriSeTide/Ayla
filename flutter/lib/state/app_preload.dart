/// 核心数据预加载实现 —— web `appInit.ts:31–46` 的 `loadCoreData` 等价物。
///
/// 由 `core/app_init.dart` 的 [aylaCoreDataLoader] 注入调用：web 的 `appInit.ts` 直接
/// import 各 store，Flutter 侧 `lib/core/` 不依赖 `lib/state/`（依赖方向 core ← state），
/// 故 `main.dart` 启动时调 [aylaRegisterCoreDataLoader] 完成接线。
///
/// ## 逐条对应的 web 请求（`appInit.ts:34–42`）
/// | web | 行 | 本件 |
/// |---|---|---|
/// | `loadSocial("conversations", { type: "group" })` | 35 | [AylaSocialStore.load]（group） |
/// | `loadDirectory("voice")` | 36 | [AylaDirectoryStore.load]（voice，全部档） |
/// | `loadDirectory("live")` | 37 | 同上（live） |
/// | `listPosts({ scope: "feed", limit: 20 })` | 38 | [AylaPostsApi.listPosts] ⇒ `setPage` |
/// | `loadDirectory("game")` | 39 | 同上（game） |
/// | `loadSocial("conversations", { type: "private" })` | 40 | 同上（private） |
/// | `usePostsStore.getState().setPage(posts.results, next_cursor, has_more)` | 42 | [AylaPostsStore.setPage] |
/// | 失败不阻断（catch 后 resolve） | 43–45 | 同 |
///
/// ## 未实现（登记）
/// 1. **`loadSocial` 两项（群会话 / 私聊会话）**：Flutter 侧尚无 web `stores/social.ts`
///    的等价物 —— 会话列表当前由 `chat_state.dart` 的 WS 维护 + 各页私有无分页缓存
///    （`chat_state.dart:15` 已登记「列表加载态归各页」）。待 social store 建成后在此补齐，
///    不改变其余四组的语义。
/// 2. 预加载的目录 **不带分类选项**（web 同：`loadDirectory("voice")` 无 options）
///    ⇒ 预取「全部」档（key 与该档页面一致）；分类 tab 首次进入时各自取页（与 web 一致）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/directory_page.dart';
import '../core/api/posts_api.dart';
import '../core/app_init.dart';
import '../core/models/post.dart' show AylaPost;
import 'directory_events.dart' show AylaDirectoryKind;
import '../core/models/conversation.dart' show AylaConversationSummary;
import 'chat_state.dart' show AylaChatState;
import 'directory_store.dart';
import 'hub_directory_options.dart';
import 'posts_store.dart';
import 'social_store.dart';

/// 接线：把本文件的预加载实现装进 `core/app_init.dart` 的预加载门（`main.dart` 调一次）。
void aylaRegisterCoreDataLoader() {
  aylaCoreDataLoader = aylaLoadCoreData;
}

/// 由 `main.dart` 注入的「当前用户的 chatState」取值器（见 [_seedChatStateFromSocial]）。
AylaChatState Function()? aylaChatStateResolver;

/// 接线：注入 chatState 取值器（`main.dart` 调一次）。
void aylaRegisterChatStateResolver(AylaChatState Function() resolver) {
  aylaChatStateResolver = resolver;
}

/// **把预取到的会话摘要灌进 `chatState`** —— 2026-10-01 用户实机：
/// 「**每次切换到主页选项卡时左侧群头像列表都要加载，这在 web 是不需要的**」。
///
/// 根因：群主页左侧服务器列的数据源是 `AylaGroupDirectory(chatState: …)`
/// （`group_page.dart:188`），而 web 的对应组件读的是 **social store**
/// —— `appInit.ts:35` 的 `loadSocial("conversations", { type: "group" })` 预取的就是它。
/// Flutter 只预取 social 却**不灌 chatState** ⇒ 左侧群头像列表等于没被预加载 ⇒
/// 每次进主页都要等一次群列表请求。
/// 口径与 `messages_page.dart:149` 的 `_onPagerChanged` 完全一致（会话摘要进 chat store）。
void _seedChatStateFromSocial() {
  final AylaChatState? chat = aylaChatStateResolver?.call();
  if (chat == null) return;
  for (final AylaSocialOptions options in <AylaSocialOptions>[
    const AylaSocialOptions(type: 'group'),
    const AylaSocialOptions(type: 'private'),
  ]) {
    final AylaSocialRecord? record = aylaSocialStore.recordOf(
      AylaSocialKind.conversations,
      options,
    );
    for (final Object item in record?.items ?? const <Object>[]) {
      if (item is AylaConversationSummary) chat.upsertConversation(item);
    }
  }
}

/// web `loadCoreData`（`appInit.ts:31–46`）—— 并发预取，失败不阻断。
Future<void> aylaLoadCoreData(String? userId) async {
  // userId 进目录 record 的 key 段（web `directoryKey` 读 `currentUser?.id`）。
  aylaDirectoryStore.userId = userId;
  aylaSocialStore.userId = userId;
  try {
    await Future.wait(<Future<void>>[
      // web 35：loadSocial("conversations", { type: "group" })
      aylaSocialStore.load(
        AylaSocialKind.conversations,
        const AylaSocialOptions(type: 'group'),
      ),
      // ⚠️ **必须带 `filter: 'all'`**：web 的 `loadDirectory(kind)`（无 options）与大厅页
      // `useDirectoryPage(kind, { filter: 'all', … })` 的 `directoryKey` **不一致** ⇒
      // web 现状下这份预取对大厅**读不到**（用户 2026-09-30 实机：「预加载形同虚设」）。
      // 这里按用户明确要求改为与页面同 key（**有意偏离 web**，仅 options 一处，
      // 请求本身仍是 `appInit.ts` 的同一组）。
      aylaDirectoryStore.load(
        AylaDirectoryKind.voice,
        const AylaDirectoryOptions(filter: 'all'),
      ),
      // ⚠️ **必须带 `filter: 'all'`**：web 的 `loadDirectory(kind)`（无 options）与大厅页
      // `useDirectoryPage(kind, { filter: 'all', … })` 的 `directoryKey` **不一致** ⇒
      // web 现状下这份预取对大厅**读不到**（用户 2026-09-30 实机：「预加载形同虚设」）。
      // 这里按用户明确要求改为与页面同 key（**有意偏离 web**，仅 options 一处，
      // 请求本身仍是 `appInit.ts` 的同一组）。
      aylaDirectoryStore.load(
        AylaDirectoryKind.live,
        const AylaDirectoryOptions(filter: 'all'),
      ),
      // ⚠️ **补齐其余筛选档**（用户 2026-09-30「**一次性预加载所有**，保证流畅体验」）：
      // 「全部」「公开」两档在上面；这里把**其余档**（语音 occupied、直播 live/offline、
      // 桌游 waiting/playing，以及三者的 friends/mine）一并预取 ⇒ **切分类零等待、不闪骨架**。
      // options 由共享事实源构造 ⇒ 与页面 `directoryKey` 逐字段一致（否则命中不了）。
      // 代价：启动请求数上升（语音 5 + 直播 6 + 桌游 6 = 17，全部并发、失败不阻断）。
      for (final AylaDirectoryKind kind in <AylaDirectoryKind>[
        AylaDirectoryKind.voice,
        AylaDirectoryKind.live,
        AylaDirectoryKind.game,
      ])
        for (final String filter in aylaHubFiltersOf(kind))
          if (filter != 'all' && filter != 'public')
            aylaDirectoryStore.load(
              kind,
              aylaHubDirectoryOptions(
                kind: kind,
                filter: filter,
                userId: userId,
              ),
            ),
      _preloadPostsFeed(),
      // ⚠️ **必须带 `filter: 'all'`**：web 的 `loadDirectory(kind)`（无 options）与大厅页
      // `useDirectoryPage(kind, { filter: 'all', … })` 的 `directoryKey` **不一致** ⇒
      // web 现状下这份预取对大厅**读不到**（用户 2026-09-30 实机：「预加载形同虚设」）。
      // 这里按用户明确要求改为与页面同 key（**有意偏离 web**，仅 options 一处，
      // 请求本身仍是 `appInit.ts` 的同一组）。
      aylaDirectoryStore.load(
        AylaDirectoryKind.game,
        const AylaDirectoryOptions(filter: 'all'),
      ),
      // web 40：loadSocial("conversations", { type: "private" })
      aylaSocialStore.load(
        AylaSocialKind.conversations,
        const AylaSocialOptions(type: 'private'),
      ),
      // ⚠️ **按用户 2026-09-30「多用预加载」补的第二层**：目录页的分类 tab
      // （公开 / 好友 / 有人 / 我的）各有**独立的 record key** ⇒ 只预取「全部」档时，
      // **切分类仍要等一次请求 + 骨架**（用户实机「切换卡」的另一处现场）。
      // 这里补预取「公开」档（除「全部」外最常点的档），代价是启动请求数 +3
      //（voice/live/game 各一）；其余档（好友/有人/我的）语义依赖当前用户与在线态，
      // 变化频繁，预取意义小，仍按 web 现状**首次进入时取**。
      aylaDirectoryStore.load(
        AylaDirectoryKind.voice,
        aylaHubDirectoryOptions(
          kind: AylaDirectoryKind.voice,
          filter: 'public',
          userId: userId,
        ),
      ),
      aylaDirectoryStore.load(
        AylaDirectoryKind.live,
        aylaHubDirectoryOptions(
          kind: AylaDirectoryKind.live,
          filter: 'public',
          userId: userId,
        ),
      ),
      aylaDirectoryStore.load(
        AylaDirectoryKind.game,
        aylaHubDirectoryOptions(
          kind: AylaDirectoryKind.game,
          filter: 'public',
          userId: userId,
        ),
      ),
    ]);
    // ⚠️ 预取完成后把会话摘要灌进 chatState（群主页左侧服务器列的数据源）——
    // 见 [_seedChatStateFromSocial] 的注释：这是 web「预加载后组件秒开」的最后一环。
    _seedChatStateFromSocial();
  } catch (error) {
    // web 43–45：失败不阻断流程（用户访问对应页面时会重试）。
    debugPrint('[预加载] 核心数据加载失败 $error');
  }
}

/// web `listPosts({ scope: "feed", limit: 20 })`（38）+ `setPage(...)`（42）。
Future<void> _preloadPostsFeed() async {
  final AylaDirectoryPage<AylaPost> page =
      await AylaPostsApi.listPosts(scope: 'feed');
  aylaPostsStore.setScope('feed');
  aylaPostsStore.setPage(page.results, page.nextCursor, page.hasMore);
}
