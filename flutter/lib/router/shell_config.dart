/// AppShell 路由配置（web `layout/shellConfig.ts` 262 行的等价物）。
///
/// **纯函数，组件与测试共用同一事实源** —— 与 web 同口径，逐条对照：
/// | 本文件 | web |
/// |---|---|
/// | [aylaResolveModule] | `resolveModule` |
/// | [aylaIsMessagesRoute] | `isMessagesRoute` |
/// | [aylaIsPrivateChatRoute] | `isPrivateChatRoute` |
/// | [aylaIsPrimaryNavRoute] | `isPrimaryNavRoute` |
/// | [aylaIsLiveRoomRoute] | `isLiveRoomRoute` |
/// | [aylaIsGroupScene] | `isGroupScene` |
/// | [aylaIsPostDetailRoute] | `isPostDetailRoute` |
/// | [aylaIsNarrowTopBarRoute] | `isNarrowTopBarRoute` |
/// | [aylaResolveCornerFabs] | `resolveCornerFabs` |
/// | [aylaResolveFabAction] | `resolveFabAction` |
///
/// ⚠️ **实现差异（登记）**：web 的 `matchPath(pattern, pathname)` 来自 React Router 6
/// （`:param` / `*` / 具体度排序）；Flutter 侧无等价函数 ⇒ 本文件用 [aylaMatchPath]
/// 表达同一语义（**只覆盖 shellConfig 用到的语法**：静态段 + `:param` 单段 + 尾段 `*`）。
library;

import '../widgets/shell/bottom_tabs.dart' show AylaPrimaryModule;
// `AylaRefreshFabPosition` 复用 fab.dart 的既有枚举（`corner` / `bottomLeft`）——不另立一套。
import '../widgets/shell/fab.dart' show AylaRefreshFabPosition;

/// React Router `matchPath({ path, end: true })` 的等价物。
///
/// 返回**参数表**（非 null = 匹配；无参数 = 空表），不匹配返回 null。
/// 支持：静态段 · `:param`（单段）· `*`（**仅尾段**，匹配剩余零到多段）。
/// 不支持可选段 `?` 与正则段 —— `shellConfig.ts` 未用到，将来若用到须在此扩展。
Map<String, String>? aylaMatchPath(String pattern, String location) {
  final List<String> ps = _segments(pattern);
  final List<String> ls = _segments(location);
  final Map<String, String> params = <String, String>{};
  for (int i = 0; i < ps.length; i++) {
    final String p = ps[i];
    // 尾段通配：剩余零到多段全部吞掉（React Router 的 `/group/*` 也匹配 `/group`）
    if (p == '*') return params;
    if (i >= ls.length) return null;
    if (p.startsWith(':')) {
      params[p.substring(1)] = Uri.decodeComponent(ls[i]);
      continue;
    }
    if (p != ls[i]) return null;
  }
  return ps.length == ls.length ? params : null;
}

/// 便捷判定（`matchPath(...) != null`）。
bool aylaMatches(String pattern, String location) =>
      aylaMatchPath(pattern, location) != null;

List<String> _segments(String path) => path
    .split('/')
    .where((String s) => s.isNotEmpty)
    .toList(growable: false);

/// 一级模块表（`PRIMARY_MODULES`）：文案与路由复用 [AylaPrimaryModule]（bottom_tabs.dart），
/// **不另立一套** —— 库内该枚举已含 label / path / iconName，与 web 同源。
const List<AylaPrimaryModule> aylaPrimaryModules = <AylaPrimaryModule>[
  AylaPrimaryModule.home,
  AylaPrimaryModule.voice,
  AylaPrimaryModule.live,
  AylaPrimaryModule.posts,
  AylaPrimaryModule.games,
];

/// 一级 tab **视觉顺序**（`PRIMARY_TAB_ORDER`：主页居中）—— 窄屏一级五页横滑的方向计算用。
const List<AylaPrimaryModule> aylaPrimaryTabOrder = <AylaPrimaryModule>[
  AylaPrimaryModule.voice,
  AylaPrimaryModule.live,
  AylaPrimaryModule.home,
  AylaPrimaryModule.posts,
  AylaPrimaryModule.games,
];

/// 当前路径归属的一级模块；`/messages` `/search` `/profile` 等无归属返回 null（无高亮）。
AylaPrimaryModule? aylaResolveModule(String pathname) {
  for (final AylaPrimaryModule m in aylaPrimaryModules) {
    if (m == AylaPrimaryModule.home) {
      // `/group/*` 群聊场景归「主页」（宽屏主页 = 三列群聊界面）；
      // 私聊窗口 `/chat/:id` 无模块高亮。
      if (aylaMatches('/group', pathname) ||
          aylaMatches('/home', pathname) ||
          aylaMatches('/group/*', pathname)) {
        return m;
      }
      continue;
    }
    if (aylaMatches(m.path, pathname) || aylaMatches('${m.path}/*', pathname)) {
      return m;
    }
  }
  return null;
}

/// 消息路由（宽屏 TopNav 消息项选中态）：消息中心 / 私聊窗口。
bool aylaIsMessagesRoute(String pathname) =>
      aylaMatches('/messages', pathname) ||
      aylaMatches('/chat/:conversationId', pathname);

/// 私聊聊天路由（窄屏）：底部有输入框 ⇒ 壳层不渲染 BottomTabs / MessageFab。
bool aylaIsPrivateChatRoute(String pathname) =>
      aylaMatches('/chat/:conversationId', pathname);

/// 五个一级导航页（窄屏左下角私信按钮「常态显示、点击跳 /messages」的**唯一**范围）。
/// 精确匹配（不包含子路由：`/live/:channelId`、`/posts/:postId` 属「其它页面」）。
bool aylaIsPrimaryNavRoute(String pathname) {
  for (final AylaPrimaryModule m in aylaPrimaryModules) {
    if (aylaMatches(m.path, pathname)) return true;
  }
  return aylaMatches('/home', pathname);
}

/// 直播间路由（`/live/:channelId`、`/live/start/:channelId`）。
/// 窄屏：进房动画 = 底栏下滑走；宽屏：TopNav 常驻 + 视频主区 + 弹幕侧列。
bool aylaIsLiveRoomRoute(String pathname) =>
      aylaMatches('/live/:channelId', pathname) ||
      aylaMatches('/live/start/:channelId', pathname);

/// 群聊场景路由（窄屏 GroupPage 自渲染顶部导航条 ⇒ 壳层不出 BottomTabs / MessageFab）。
bool aylaIsGroupScene(String pathname) =>
      aylaMatches('/group/:id', pathname) ||
      aylaMatches('/group/:id/:scene', pathname) ||
      aylaMatches('/group/:id/posts/:postId', pathname) ||
      aylaMatches('/group/:id/voice/:voiceChannelId', pathname);

/// 帖子详情路由（窄屏底栏下滑离场，评论输入框延迟滑入）。
bool aylaIsPostDetailRoute(String pathname) =>
      aylaMatches('/posts/:postId', pathname);

/// 窄屏顶栏（`NarrowTopBar`）渲染路由 —— 一级/二级列表页窄屏顶部有常驻顶栏。
/// 群场景 / 私聊 / 语音房 / 直播间 / 帖子详情等沉浸路由与个人页不渲染。
bool aylaIsNarrowTopBarRoute(String pathname) {
  const List<String> paths = <String>[
    '/group',
    '/home',
    '/voice',
    '/live',
    '/posts',
    '/posts/mine',
    '/games',
    '/search',
    '/favorites',
    '/messages',
  ];
  for (final String p in paths) {
    if (aylaMatches(p, pathname)) return true;
  }
  return false;
}

/// 浮层按钮组显示配置（`CornerFabConfig`）。
class AylaCornerFabConfig {
  const AylaCornerFabConfig({
    required this.refresh,
    required this.refreshPosition,
    required this.scrollTop,
  });

  /// 不显示任何浮层键（`NO_CORNER_FAB`）。
  static const AylaCornerFabConfig none = AylaCornerFabConfig(
    refresh: false,
    refreshPosition: AylaRefreshFabPosition.corner,
    scrollTop: false,
  );

  final bool refresh;
  final AylaRefreshFabPosition refreshPosition;
  final bool scrollTop;
}

/// 宽屏（>768）需要「刷新 + 回顶」右下堆叠的列表页（`WIDE_CORNER_LIST_PATHS`）。
const List<String> aylaWideCornerListPaths = <String>[
  '/live',
  '/posts',
  '/voice',
  '/games',
  '/group/:id/posts',
  '/group/:id/voice',
  '/group/:id/games',
];

/// 窄屏（≤768）需要回顶键的列表页（`NARROW_SCROLL_TOP_PATHS`；刷新由各页 PullToRefresh 提供）。
const List<String> aylaNarrowScrollTopPaths = <String>[
  '/live',
  '/posts',
  '/voice',
  '/games',
  '/group/:id/posts',
  '/group/:id/voice',
  '/group/:id/games',
];

/// 浮层按钮组配置（`resolveCornerFabs`）。
AylaCornerFabConfig aylaResolveCornerFabs(String pathname, bool isNarrow) {
  if (isNarrow) {
    for (final String p in aylaNarrowScrollTopPaths) {
      if (aylaMatches(p, pathname)) {
        return const AylaCornerFabConfig(
          refresh: false,
          refreshPosition: AylaRefreshFabPosition.corner,
          scrollTop: true,
        );
      }
    }
    return AylaCornerFabConfig.none;
  }
  // 私信列表：刷新键放左下（无回顶）
  if (aylaMatches('/messages', pathname)) {
    return const AylaCornerFabConfig(
      refresh: true,
      refreshPosition: AylaRefreshFabPosition.bottomLeft,
      scrollTop: false,
    );
  }
  for (final String p in aylaWideCornerListPaths) {
    if (aylaMatches(p, pathname)) {
      return const AylaCornerFabConfig(
        refresh: true,
        refreshPosition: AylaRefreshFabPosition.corner,
        scrollTop: true,
      );
    }
  }
  return AylaCornerFabConfig.none;
}

/// 创建动作（`FabAction`）。
class AylaFabAction {
  const AylaFabAction({
    required this.key,
    required this.label,
    required this.groupId,
    required this.plannedStep,
    this.handler,
  });

  /// 动作标识（测试锚点）。
  final String key;

  /// 面板主动作文案。
  final String label;

  /// 群内创建时归属的群 id；一级 tab 创建为 null。
  final String? groupId;

  /// 该创建表单预计落地的步骤标识（F1 阶段点击动作项仅提示，不打开表单）。
  final String plannedStep;

  /// 已接线的真表单处理（live / voice / post / game / group）；null = 仍提示落步骤。
  final String? handler;
}

/// CreateFAB 路由匹配表（`resolveFabAction`）。
///
/// 直播间无 FAB；群内：语音/桌游有、直播（入口在侧栏）与帖子（走底部输入框）没有；
/// 群聊聊天子界面无 FAB；`/messages` `/search` `/profile` 等无 FAB。
AylaFabAction? aylaResolveFabAction(String pathname) {
  if (aylaIsLiveRoomRoute(pathname)) return null;

  final Map<String, String>? groupScene =
      aylaMatchPath('/group/:id/:scene', pathname);
  final String? groupId = groupScene?['id'];
  final String? scene = groupScene?['scene'];
  if (groupId != null && scene != null) {
    switch (scene) {
      case 'voice':
        return AylaFabAction(
          key: 'group-voice',
          label: '创建群内语音房',
          groupId: groupId,
          plannedStep: 'F5',
          handler: 'voice',
        );
      case 'live':
        return null; // 群内直播创建入口在直播侧栏左下角
      case 'posts':
        return null; // 群内帖子发帖走底部输入框，FAB 隐藏
      case 'games':
        return AylaFabAction(
          key: 'group-game',
          label: '创建群内桌游室',
          groupId: groupId,
          plannedStep: 'F7',
          handler: 'game',
        );
      default:
        return null; // info 等无创建语义
    }
  }
  // 群聊聊天子界面 FAB 隐藏
  if (aylaMatches('/group/:id', pathname)) return null;

  if (aylaMatches('/group', pathname) || aylaMatches('/home', pathname)) {
    return const AylaFabAction(
      key: 'create-group',
      label: '创建群聊',
      groupId: null,
      plannedStep: 'F2',
      handler: 'group',
    );
  }
  if (aylaMatches('/voice', pathname)) {
    return const AylaFabAction(
      key: 'create-voice',
      label: '创建语音房',
      groupId: null,
      plannedStep: 'F5',
      handler: 'voice',
    );
  }
  if (aylaMatches('/live', pathname)) {
    return const AylaFabAction(
      key: 'create-live',
      label: '创建直播间',
      groupId: null,
      plannedStep: 'F4',
      handler: 'live',
    );
  }
  if (aylaMatches('/posts', pathname)) {
    return const AylaFabAction(
      key: 'create-post',
      label: '发帖',
      groupId: null,
      plannedStep: 'F6',
      handler: 'post',
    );
  }
  if (aylaMatches('/games', pathname)) {
    return const AylaFabAction(
      key: 'create-game',
      label: '创建桌游室',
      groupId: null,
      plannedStep: 'F7',
      handler: 'game',
    );
  }
  return null;
}