/// 分享目标异步分流（web `utils/shareRoutes.ts:86–129` 的 Dart 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [aylaResolveShareTarget] | `shareRoutes.ts:118–129` `resolveShareTarget` |
/// | [aylaShareGroupEntryIds] | `shareRoutes.ts:86–112` `groupEntryIds` |
/// | 分流判据 | `shareRoutes.ts:118–129`（群上下文先查目录，命中走群内，否则群外） |
/// | 卡片点击入口 | `components/chat/ShareBubble.tsx:75–94` `handleClick` |
///
/// ## 语义（与 web 逐条同义）
/// 1. `payload` 为空（含 `fromJson` 已判非法的：`share_type` 未知 / `target_id` 空）
///    ⇒ **null**：不跳转（`shareRoutes.ts:122`）；
/// 2. `groupId` 非空（群聊上下文）时**先查该群的目录条目**：voice / live / post /
///    boardgame 四域（`shareRoutes.ts:89–105`）；group / user 两类 web 同样返回空集
///    （`default: return new Set()`，:106–107）⇒ 直接走群外；
/// 3. 命中（目录里有同 id 条目）⇒ 群内路径；未命中 / 不在群上下文 ⇒ 群外路径
///    —— **路由表复用** `core/models/share_routes.dart` 的 [aylaShareTargetRoute]
///    （= web `inGroupRoute` / `outRoute` + 132–140 的 `shareTargetRoute`）；
/// 4. 目录读取异常一律**保守回落群外**（web `catch { return new Set() }`，
///    `shareRoutes.ts:109–111`）—— 绝不因查询失败把用户导向看不见的群内页。
///
/// ## 与 web 的实现差异（有意，登记）
/// web 四个目录口是**裸数组**接口（`api/voice.ts:33–36` `/voice/channels/?scope=group:<id>`、
/// `api/live.ts:54–61`、`api/boardgame.ts:23–30`、`api/posts.ts:15–34`），
/// Flutter 的 `AylaVoiceApi` / `AylaLiveApi` / `AylaBoardgameApi` 只带出了**游标分页**形态
/// （无 scope 裸数组口；不为没有消费者的能力提前开口子）⇒ 这里改走各分页口的
/// `groupId` 过滤参数。
///
/// ### ⚠️ `group_id` 与 `scope=group:<id>` 的等价性（2026-10-21 **已核后端源码确认等价**）
/// 后端 `apps/common/catalog_pagination.py:24–41` 的 `catalog_scope(params)` 是三个目录
/// 视图的**统一入口**，其 docstring 原话：
/// > `Resolve group_id as an alias for the existing allowed-groups scope.`
///
/// 实现：读到 `group_id` 就把它拼成 `group:<int(group_id)>`；若同时给了 `scope`
/// 且与之不等 ⇒ 400 `group_id 与 scope 不匹配`；否则返回该 scope。
/// ⇒ **`?group_id=<id>` 与 `?scope=group:<id>` 在后端是同一个值的两个写法**，
/// 二者不可能表达不同语义。
/// 三个视图都走这条入口，且都只对 `scope.startswith("group:")` 施加同一过滤
/// （`Q(allowed_groups__id=gid)).distinct()`，命中 `allowed_group_ids` 白名单）：
/// · `apps/voice/views.py:98–107`（`:96` 注释「归属群 group FK 不提供可见性」）；
/// · `apps/live/views.py:139–146`；
/// · `apps/boardgame/views.py:93–100`。
/// 即 Flutter 侧传 `groupId` 与 web 传 `scope` **落到同一条 SQL 过滤**，无需改参数。
///
/// 另两条口径（也已在后端核实）：
/// · 分页口只在**带了 `limit` 或 `cursor`** 时启用（`catalog_pagination.py:112–114`：
///   `if "limit" not in params and "cursor" not in params: return None` ⇒ 走裸数组旧形态）；
///   本文件始终传 `limit`（见 [kAylaShareResolvePageLimit]）⇒ 拿到的是 `DirectoryPage`
///   形状，与 `AylaDirectoryPage.fromJson` 一致。
/// · `limit` 上限 100、默认 20（`catalog_pagination.py:19–20`）。
///
/// ### 只读第一页的保守档
/// web 的存在性判断本就只看「量级很小的群内目录」（`shareRoutes.ts:85` 原话
/// 「量级小，足够判断」），一页足以覆盖正常群；若单群条目超过一页而目标不在首页，
/// 保守档是**回落群外**（不误跳群内）。
/// 帖子域 `AylaPostsApi.listPosts` 直接收 `scope` 参数（与 web 同参数）⇒ 原样传
/// `scope=group:<id>`（web `api/posts.ts:26` 同式）。
library;

import '../models/post.dart' show AylaPost;
import '../models/share_payload.dart' show AylaSharePayload, AylaShareType;
import '../models/share_routes.dart' show aylaShareTargetRoute;
import 'boardgame_api.dart' show AylaBoardgameApi, AylaDirectoryGameEntry;
import 'directory_page.dart' show AylaDirectoryPage;
import 'live_api.dart' show AylaDirectoryLiveEntry, AylaLiveApi;
import 'posts_api.dart' show AylaPostsApi;
import 'voice_api.dart' show AylaDirectoryVoiceEntry, AylaVoiceApi;

/// 群内目录查询条数（只作存在性判断 ⇒ 一页足够；见文件头「与 web 的实现差异」）。
const int kAylaShareResolvePageLimit = 20;

/// 分享目标在**该群目录**中的条目 id 集合（web `groupEntryIds`，`shareRoutes.ts:86–112`）。
///
/// 返回 `Set<String>`（与 web 同型，便于调用方直接 `.contains(targetId)`）；
/// 查询异常 ⇒ **空集**（保守回落群外，`shareRoutes.ts:109–111`）。
Future<Set<String>> aylaShareGroupEntryIds(
  AylaShareType shareType,
  String groupId,
) async {
  try {
    switch (shareType) {
      case AylaShareType.voice:
        final AylaDirectoryPage<AylaDirectoryVoiceEntry> page =
            await AylaVoiceApi.listVoiceChannelsPage(
          groupId: groupId,
          limit: kAylaShareResolvePageLimit,
        );
        return <String>{
          for (final AylaDirectoryVoiceEntry item in page.results) item.card.id,
        };
      case AylaShareType.live:
        final AylaDirectoryPage<AylaDirectoryLiveEntry> page =
            await AylaLiveApi.listLiveChannelsPage(
          groupId: groupId,
          limit: kAylaShareResolvePageLimit,
        );
        return <String>{
          for (final AylaDirectoryLiveEntry item in page.results) item.card.id,
        };
      case AylaShareType.post:
        final AylaDirectoryPage<AylaPost> page = await AylaPostsApi.listPosts(
          scope: 'group:$groupId',
          limit: kAylaShareResolvePageLimit,
        );
        return <String>{
          // AylaPost.id 是 int（core/models/post.dart:179）⇒ 分享载荷的 String 口径。
          for (final AylaPost post in page.results) '${post.id}',
        };
      case AylaShareType.boardgame:
        final AylaDirectoryPage<AylaDirectoryGameEntry> page =
            await AylaBoardgameApi.listGameRoomsPage(
          groupId: groupId,
          limit: kAylaShareResolvePageLimit,
        );
        return <String>{
          // 卡投影 id 是 String（core/models/game_room.dart:198）。
          for (final AylaDirectoryGameEntry item in page.results) item.card.id,
        };
      // web `groupEntryIds` 的 default：群聊 / 用户不查目录（`shareRoutes.ts:106–107`）。
      case AylaShareType.group:
      case AylaShareType.user:
        return <String>{};
    }
  } catch (_) {
    // 目录读取失败 ⇒ 空集（web `catch { return new Set() }`，:109–111）。
    return <String>{};
  }
}

/// 分享目标分流（web `resolveShareTarget`，`shareRoutes.ts:118–129`）。
///
/// - `payload` 为 null ⇒ null（不跳转；web 的 `!payload || !payload.target_id` 判据
///   在 Flutter 侧已由 `AylaSharePayload.fromJson` 消化）；
/// - 群上下文 + 目标在该群目录中 ⇒ 群内路径；否则 ⇒ 群外路径；
/// - 目录异常 ⇒ 群外路径（保守）。
Future<String?> aylaResolveShareTarget(
  AylaSharePayload? payload,
  String? groupId,
) async {
  if (payload == null) return null;
  if (groupId != null && groupId.isNotEmpty) {
    final Set<String> ids = await aylaShareGroupEntryIds(
      payload.shareType,
      groupId,
    );
    if (ids.contains(payload.targetId)) {
      return aylaShareTargetRoute(payload, groupId);
    }
  }
  return aylaShareTargetRoute(payload, null);
}

/// 把 `fromShare=1` 追加到路由（web `navigate(route, { state: { fromShare: true } })`
/// 的 Flutter 等价物，`ShareBubble.tsx:90`）。
///
/// Flutter 的路由是 URL 字符串（无 React Router 的 `state`）⇒ 用 query 参数承载同一事实，
/// 由 `router/app_router.dart` 的五条 `/group/*` 路由读 `?fromShare=` 并下传
/// `GroupPage.fromShare`（`GroupVoice.tsx:25` / `GroupLive.tsx:25` 的 `location.state`）。
///
/// 已有其它 query 时**合并**而不是覆盖（例如藏品定位的 `?msg=&seq=`）。
String aylaShareRouteWithFromShare(String route) {
  final Uri uri = Uri.parse(route);
  if (uri.queryParameters['fromShare'] == '1') return route;
  final Map<String, String> query = <String, String>{
    ...uri.queryParameters,
    'fromShare': '1',
  };
  return Uri(path: uri.path, queryParameters: query).toString();
}