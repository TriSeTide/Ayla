/// 群聊场景容器页（路由 `/group/:id` 及四个子路由）—— web `pages/GroupPage.tsx`（539 行）
/// 的等价物。
///
/// ## 双形态装配（tsx 405–496）
/// - **宽屏（>768）**：`ServerRail` + `ChannelSidebar` + `group-content` 三列；
///   内容区 = **换 key 的 `KeyedSubtree`**（`key = "group:<id>"`）—— web 的
///   `ConversationTransition`（tsx 429–431）在 `panels` 默认档下宿主变体**全为空对象**
///   （`auroraquaMotion.ts:29` 的 `auroraquaPanelOrchestration`）⇒ 当帧卸载旧 owner /
///   挂载新 owner，**不做任何淡出**；不要换成 `AylaConversationTransition` 的 wait 编排
///   （那条路径会给旧件挂 300ms `FadeTransition` 兜底 = 用户实报的「切群闪屏」）；
/// - **窄屏（≤768）**：`GroupTopTabs`（从原底栏位置连续升至顶部，300ms）+ 场景层；
///   壳层在群路由**不出 BottomTabs**（`router/shell_config.dart` 的 `aylaIsGroupScene`），
///   与 tsx 的「底栏本体升上去」等价。
///
/// ## 单一状态源（tsx 215–245）
/// `activeScene` 存 `state/group_state.dart`（= web `stores/group`）；route param 变化时
/// **一处 effect** 同步 store；切场景走 `setActiveScene + go`（store 是交互事实源、URL 是回显）。
/// 宽屏用 [effectiveScene]（新群首帧就按当前路由渲染，避免 effect 同步前把旧群场景挂到新群），
/// 窄屏用 store 的 `activeScene`（tsx 227 `contentScene`）。
///
/// ## 手势（窄屏）
/// - **下拉回主页**（R-G6 / §2.3）：阈值 80px（tsx 64），跟手 1:1 + 内容 scale 1→0.98 /
///   opacity 1→0.6 视差，回弹 200ms `--ease-out`，过阈值退场 250ms `--ease-in` 后 `/group`；
/// - **横滑切场景**（§2.2）：松手判定用 [aylaResolveSwipeCommit]（净位移 ≥ 宽/3 优先，
///   同向甩动 ≥300px/s 且净位移 ≥40px 补充，交叉轴占优让位）；
///   位移层 `dragElastic 0.8`（跟手 80%）；
/// - 场景切换动画：web 的 variants 进/出场**横向位移都是 0**（`GroupPage.tsx:507–511`）
///   ⇒ 只有**淡出**（旧场景 300ms 淡出、新场景直接显示），由 [AylaSceneFade] 表达。
///
/// ## 与 web 的机制差异（登记）
/// 1. **路由守卫卡片不实现**（用户裁决，见 13 号 B5）：web 在「非成员 + summary 403」时
///    渲染 `GroupApplyGate` 申请卡片（tsx 394–403）；Flutter 侧该组件按裁决未建 ⇒
///    直达未加入群时页面按「加载失败 / 空态」呈现，不做守卫卡。
/// 2. **场景切换重叠**：web 用 `AnimatePresence mode="sync"` 让新旧场景同帧重叠；
///    Flutter 用 [Stack] + 单条淡出曲线表达同一效果（新场景无淡入 —— 与 web 的
///    `enter/center` 变体一致）。**切换期间旧场景的 Element/State 必须原地复用**
///    （固定槽位 + 恒定包装链，见 [AylaSceneFade]）—— 否则旧场景重播自己的入场动画。
/// 3. `useTouchAxisGuard`（起步 slop 内压制浏览器垂直滚动接管）无 Flutter 等价需求：
///    Flutter 的手势竞技场本身按方向锁定，不存在 `pointercancel` 夺轴问题。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart';
import '../core/api/voice_api.dart';
import '../core/models/conversation.dart';
import '../core/models/subgroup.dart';
import '../state/boardgame_store.dart' show aylaBoardgameStore;
import '../state/chat_providers.dart' show chatStateProvider;
import '../state/chat_state.dart' show AylaChatState;
import '../state/directory_events.dart';
import '../state/group_providers.dart';
import '../state/subgroup_state.dart'
    show AylaSubGroupState, aylaSortSubgroupsByActivity;
import '../state/group_state.dart';
import '../state/live_state.dart';
import '../state/paged_list.dart';
import '../state/posts_store.dart' show aylaPostsStore;
import '../state/room_providers.dart'
    show directoryEventsProvider, liveStateProvider, voiceStateProvider;
import '../state/voice_state.dart';
import '../theme/tokens.dart';
import '../widgets/base/directory_page.dart' show aylaDirectoryIsWide;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
// 横滑跟手弹性 `kAylaDragElastic`（组件库 motion 域共享常量，web `dragElastic` .8）。
import '../widgets/motion/gestures.dart' show kAylaDragElastic;
import '../widgets/shell/channel_sidebar.dart';
import '../widgets/shell/group_top_tabs.dart';
import '../widgets/shell/server_rail.dart';
import '../layout/create_sheet_forms.dart' show AylaCreateGroupForm;
import 'group_chat_page.dart';
import 'group_games_page.dart';
import 'group_info_page.dart';
import 'group_live_page.dart';
import 'group_posts_page.dart';
import 'group_support.dart';
import 'home_support.dart' show kAylaHomePrefs;
import 'hub_support.dart'
    show aylaHubApplyLiveEvent, aylaHubApplyVoiceEvent, aylaHubSortLive,
        aylaHubSortVoice, AylaVoiceSortFacts;
import 'group_voice_page.dart';

/// 下拉回主页阈值与退场时长（web `GroupPage.tsx:64–65`）。
const double kAylaGroupPullExitThreshold = 80;
const int kAylaGroupExitTransitionMs = 250;

/// 甩动阈值（web `hooks/useSwipeCommit.ts:33/36`）。
const double kAylaSwipeFlickVelocity = 300;
const double kAylaSwipeMinFlickDistance = 40;

/// 松手切换判定（web `resolveSwipeCommit`，units: px / px·s⁻¹）。
int aylaResolveSwipeCommit({
  required double net,
  required double cross,
  required double velocity,
  required double size,
  double? threshold,
  double flickVelocity = kAylaSwipeFlickVelocity,
  double minFlickDistance = kAylaSwipeMinFlickDistance,
}) {
  // 方向锁让位：交叉轴净位移占优 ⇒ 本次手势不属于切页。
  if (cross.abs() >= net.abs()) return 0;
  final double distance = net.abs();
  final bool forward = net < 0; // 左滑 → 下一个
  if (distance >= (threshold ?? size / 3)) return forward ? 1 : -1;
  if (velocity.abs() >= flickVelocity &&
      distance >= minFlickDistance &&
      velocity.sign == net.sign) {
    return forward ? 1 : -1;
  }
  return 0;
}

/// 群场景索引（web `useSceneSwipeDirection.ts:17–19`：`info` 按 `chat` 处理）。
int aylaGroupSceneOrderIndex(AylaGroupScene scene) {
  final AylaGroupScene normalized =
      scene == AylaGroupScene.info ? AylaGroupScene.chat : scene;
  return kAylaGroupSceneOrder.indexOf(normalized);
}

/// 场景切换方向（web `sceneDirection`）。
int aylaGroupSceneDirection(AylaGroupScene from, AylaGroupScene to) {
  final int diff = aylaGroupSceneOrderIndex(to) - aylaGroupSceneOrderIndex(from);
  return diff > 0 ? 1 : (diff < 0 ? -1 : 0);
}

class GroupPage extends ConsumerStatefulWidget {
  const GroupPage({
    super.key,
    required this.groupId,
    this.scene,
    this.postId,
    this.voiceChannelId,
    this.liveChannelId,
  });

  final String groupId;
  final String? scene;
  final String? postId;
  final String? voiceChannelId;
  final String? liveChannelId;

  @override
  ConsumerState<GroupPage> createState() => _GroupPageState();
}

/// 子群取页的**测试注入点**（生产恒为 null ⇒ 走真实 @AylaChatApi.listSubgroupsPage@）。
///
/// 为什么需要它：@AylaChatApi@ 是纯静态类、没有可替换的请求出口，而本轮修复的
/// 判据（@default@ 并入 + 落库排序 + 首个 active）**必须**在真实 GroupPage 上
/// 走一遍才可信 —— 「单元测试绿了但链路是断的」正是上一轮的教训。
/// 形态与 @AylaDirectoryStore.requestOverride@ / @AylaSocialStore.requestOverride@ 同款。
@visibleForTesting
AylaSubgroupsPageLoader? aylaGroupPageSubgroupsLoader;

/// 见 [aylaGroupPageSubgroupsLoader]。
typedef AylaSubgroupsPageLoader = Future<AylaSubgroupPage> Function(
  String groupId,
  String? cursor,
);

/// 建群表单的**测试注入点**（生产恒为 null ⇒ 走真实 [AylaCreateGroupForm]）。
///
/// 为什么需要它：建群是全页唯一一条「弹窗 → 注入的 API → 跳转」的链，而
/// [AylaCreateGroupForm] 的三个 API 出口（`searchUsers` / `createGroup` /
/// `openPrivate`）是**构造参数**、由本页内部直接实例化 ⇒ widget test 无法替换网络，
/// 「宽屏点建群 → 填名 → 提交」这条链就会退化成只测组件、不测接线
/// （而问题 14 的根因恰恰**在接线**：`group_create_dialog.dart:184–185` 的
/// `if (submit == null) return;` 静默返回）。
///
/// 形态与 [aylaGroupPageSubgroupsLoader] 同款：文件级 `@visibleForTesting` 出口，
/// 测试注入的仍是**真实** [AylaCreateGroupForm]（只换掉三个 API），
/// 因此覆盖「GroupPage → 表单 → 提交」全链。
@visibleForTesting
AylaGroupPageCreateGroupBuilder? aylaGroupPageCreateGroupBuilder;

/// 见 [aylaGroupPageCreateGroupBuilder]：给定 onClose，返回要挂载的建群弹层。
typedef AylaGroupPageCreateGroupBuilder = Widget Function(VoidCallback onClose);

class _GroupPageState extends ConsumerState<GroupPage> {
  AylaGroupDirectory? _directory;

  // ---- 群级目录：**按群分桶缓存**（web 语义）----
  // web 的 `useDirectoryPage` / `useSocialPage` 都从**全局 store 的 `records[key]`** 读，
  // key = `directoryKey(kind, { groupId, … })` / `socialKey(kind, { groupId, … })`
  // （`stores/directory.ts:83–95`、`stores/social.ts`）⇒ 切群只是**换桶**：旧桶不销毁、
  // 内容仍在；且 `directory.ts:274` / `social.ts:150` 的
  // `mode === "initial" && fetchedAt != null && < 60s ⇒ return` 让**切回旧群不重拉**、
  // 无 loading 闪烁（`ChannelSidebar` 的面板虽然按 `key={groupId}` 重挂，但一挂上就有数据）。
  //
  // ⚠️ 曾经的错法（2026-09-29 用户实报「每次切换群，左侧选项卡就刷掉了」的根因）：
  // 在 `didUpdateWidget` 里对三条分页状态 **dispose + 重建 + 立即 `load()`** ⇒ 每次切群
  // 都清空重拉；`AylaPagedList.load()` 没有「已加载则跳过」的保护（`paged_list.dart:93`），
  // 于是面板重挂的那一刻是**空的**，用户看到的就是「选项卡被刷掉」。
  final Map<String, AylaPagedList<AylaSubGroup>> _subgroupsByGroup =
      <String, AylaPagedList<AylaSubGroup>>{};

  /// 每个群的**服务端默认组**（`listSubgroupsPage` 响应独有的 default 字段）。
  ///
  /// ## 为什么单独存（web `GroupPage.tsx:265–270`）
  /// web 用 `subgroupPage.items.find((item) => item.is_default)` 确立首个 active 子群。
  /// 该页的 items 是 **social record**，而 social 的落地段会把 `page.default`
  /// **显式并入** items（`stores/social.ts:174–178`）⇒ 那个 find 必然能找到。
  ///
  /// ⚠️ Flutter 侧不能照抄这个 find：本页的子群列表是**页面级 `AylaPagedList`**
  /// （不落 social record），而 default 是**响应级字段**、会随分页游标消失
  /// （后端 `views.py:238–247`：游标页的 rows 按 SUBGROUP_ORDER 分页，
  /// default 在**响应外层**另给）⇒ 必须在首次见到时**存下来**，
  /// 否则「默认组不落在本页 rows 内」时首个 active 永远确立不了（发送就不带子群）。
  final Map<String, AylaSubGroup> _defaultSubgroups = <String, AylaSubGroup>{};
  final Map<String, AylaPagedList<AylaDirectoryVoiceEntry>> _voiceByGroup =
      <String, AylaPagedList<AylaDirectoryVoiceEntry>>{};
  final Map<String, AylaPagedList<AylaDirectoryLiveEntry>> _liveByGroup =
      <String, AylaPagedList<AylaDirectoryLiveEntry>>{};

  /// 当前群对应的三个桶（切群只换引用，不销毁旧桶）。
  AylaPagedList<AylaSubGroup>? _subgroups;
  AylaPagedList<AylaDirectoryVoiceEntry>? _voice;
  AylaPagedList<AylaDirectoryLiveEntry>? _live;

  bool _showGroupCreate = false;

  /// 目录热更新事件总线（`voice.channel.*` / `live.channel.*`；见 `state/directory_events.dart`）。
  ///
  /// ## 为什么必须有（2026-10-01 用户实报「宽屏第二列侧栏排序依然错误」的第二根因）
  /// 侧栏的语音/直播列表来自本页的两条**页面级** `AylaPagedList`（[_createVoice] / [_createLive]），
  /// 它们只在首次 `load()` 时取一次。而 WS 帧桥（`core/ws/room_frames.dart`）确实在广播
  /// 目录事件 —— `emitPatched(voice, …)`（`:195`）/ `emitPatched(live, …)`（`:229`）、
  /// `emitDeleted`（`:113/124`）、`emitInvalidated`（`:165/211`）—— 但消费侧此前只有两个
  /// **一级大厅页**（`voice_hub_page.dart:110–128`、`games_hub_page.dart:106–120`）。
  /// ⇒ 群页侧栏：语音房有人进出（`member_count_changed`）时**行上的人数与排序都不变**；
  /// 新开播/下播（`live.channel.status.changed`）时 **LIVE 标记与排序都不变**；
  /// 新建/删除语音房或直播间时**列表不增不减**。
  /// ⇒ 光是接排序（[aylaHubSortVoice] / [aylaHubSortLive]）仍然错：**数据先得是新的**。
  AylaDirectoryEvents? _directoryEvents;
  int _directoryEventRevision = 0;

  /// 已同步过的 (群, 场景) —— 只在变化时写 store（web tsx 229–245 的 effect）。
  String? _syncedGroupId;
  AylaGroupScene? _syncedScene;

  // ---- 窄屏手势状态 ----
  bool _entered = false;
  bool _leaving = false;
  Timer? _leaveTimer;
  /// 未过阈值的**回弹动画**进行中（让 `tabsDy` 走 200ms `--ease-out`，而不是瞬时跳回）。
  bool _resetting = false;
  Timer? _resetTimer;
  double _pullDy = 0;
  double _pullOpacity = 1;
  double _dragDx = 0;
  double _dragDy = 0;
  /// 横向**未触发切换**时的回弹动画进行中（200ms `--ease-out`，防跳变）。
  bool _sceneResetting = false;
  Timer? _dragResetTimer;

  @override
  void initState() {
    super.initState();
    // 会话目录**与群无关**（web `useSocialPage("conversations", { type: "group" })` 的依赖里没有 id）
    // ⇒ 切群不重建它：ServerRail 的列表、游标与滚动位置因此跨群保留（web 同一实例、只换 props）。
    _directory = AylaGroupDirectory(chatState: ref.read(chatStateProvider))
      ..addListener(_onChanged);
    _bindGroupLists();
    // 群排序的两个**实时源**（桌游房表 / 帖子流）不是 Riverpod provider，
    // 而是模块级 store（与 web 的 zustand store 同层）⇒ 按既有 `_directory` 同款
    // 用 addListener 订阅（web 是 zustand 订阅，语义等价：变化即重排）。
    aylaBoardgameStore.addListener(_onChanged);
    aylaPostsStore.addListener(_onChanged);
    _registerDirectoryEvents();
    // 顶栏从原底栏位置升到顶部（web useEnterGroupAnimation 的「首帧后再进入」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void didUpdateWidget(covariant GroupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切群：**只换桶**（web `records[key]` 的 key 里含 groupId ⇒ 切群就是换 key）。
    // 旧桶不销毁、不重拉 ⇒ 切回旧群时面板一挂上就是满内容（无 loading 闪烁）。
    //
    // ⚠️ 这条路径存在的前提是路由**不给页面加 `key: ValueKey(id)`**（见 `router/app_router.dart`）
    // 与分页容器**有「已加载即跳过」保护**；曾经的实现在这里 dispose + 重建 + 立即 load()
    // ⇒ 每次切群清空重拉 = 用户实报的「左侧选项卡被刷掉」。
    if (oldWidget.groupId == widget.groupId) return;
    _bindGroupLists();
  }

  /// 把当前群的三个桶挂到 [_subgroups] / [_voice] / [_live]（**惰性建桶**）。
  ///
  /// 新建的桶立即 `load()`（等价 web `useDirectoryPage` 挂载后的首次 `loadDirectory`）；
  /// 已在缓存里的桶**不重拉**（等价 `directory.ts:274` / `social.ts:150` 的 60s 防抖 ——
  /// 那边是 60s 窗口，这边是会话内复用，差异见 `paged_list.dart` 文件头的登记）。
  void _bindGroupLists() {
    final String gid = widget.groupId;
    _subgroups = _subgroupsByGroup.putIfAbsent(
      gid,
      () => _createSubgroups(gid)..load(),
    );
    _voice = _voiceByGroup.putIfAbsent(gid, () => _createVoice(gid)..load());
    _live = _liveByGroup.putIfAbsent(gid, () => _createLive(gid)..load());
  }

  AylaPagedList<AylaSubGroup> _createSubgroups(String gid) {
    final AylaPagedList<AylaSubGroup> list = AylaPagedList<AylaSubGroup>(
      // `listSubgroupsPage` 的响应多带一个 `default` 字段（[AylaSubgroupPage]）——
      // 通用游标页装不下它，因此在**本闭包里先取出来存进 [_defaultSubgroups]**
      // （web `stores/social.ts:174–178` 把它并进 items；本页的子群列表不落 social
      // record，故等价物是这张表）。
      request: (String? cursor) async {
        final AylaSubgroupsPageLoader? override =
            aylaGroupPageSubgroupsLoader;
        final AylaSubgroupPage page = override != null
            ? await override(gid, cursor)
            : await AylaChatApi.listSubgroupsPage(gid, cursor: cursor);
        final AylaSubGroup? fallback = page.defaultSubgroup;
        if (fallback != null) _defaultSubgroups[gid] = fallback;
        return AylaDirectoryPage<AylaSubGroup>(
          results: page.results,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          total: page.total,
        );
      },
      keyOf: (AylaSubGroup sg) => sg.id,
    )..addListener(_onChanged);
    // 子群列表落库后同步到状态层（默认组兜底，web tsx 265–272）。
    // ⚠️ 监听器必须**绑定本桶的 groupId**：非当前群的桶也会在后台完成请求，
    // 用 `widget.groupId` 会把 A 群的数据写进 B 群（串群）。
    list.addListener(() => _syncSubgroupsFor(gid, list));
    return list;
  }

  AylaPagedList<AylaDirectoryVoiceEntry> _createVoice(String gid) {
    return AylaPagedList<AylaDirectoryVoiceEntry>(
      request: (String? cursor) =>
          AylaVoiceApi.listVoiceChannelsPage(cursor: cursor, groupId: gid),
      keyOf: (AylaDirectoryVoiceEntry e) => e.card.id,
    )..addListener(_onChanged);
  }

  AylaPagedList<AylaDirectoryLiveEntry> _createLive(String gid) {
    return AylaPagedList<AylaDirectoryLiveEntry>(
      request: (String? cursor) =>
          AylaLiveApi.listLiveChannelsPage(cursor: cursor, groupId: gid),
      keyOf: (AylaDirectoryLiveEntry e) => e.card.id,
    )..addListener(_onChanged);
  }

  /// 页面销毁才清空全部桶（web 对应 `reset()`：登出/账号切换时清 `records`）。
  void _disposeGroupLists() {
    for (final AylaPagedList<AylaSubGroup> list in _subgroupsByGroup.values) {
      list.dispose();
    }
    for (final AylaPagedList<AylaDirectoryVoiceEntry> list in _voiceByGroup.values) {
      list.dispose();
    }
    for (final AylaPagedList<AylaDirectoryLiveEntry> list in _liveByGroup.values) {
      list.dispose();
    }
    _subgroupsByGroup.clear();
    _defaultSubgroups.clear();
    _voiceByGroup.clear();
    _liveByGroup.clear();
    _subgroups = null;
    _voice = null;
    _live = null;
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    _resetTimer?.cancel();
    _dragResetTimer?.cancel();
    _directoryEvents?.removeListener(_onDirectoryEvents);
    _directoryEvents = null;
    _disposeGroupLists();
    aylaBoardgameStore.removeListener(_onChanged);
    aylaPostsStore.removeListener(_onChanged);
    _directory?.removeListener(_onChanged);
    _directory?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 订阅目录事件总线 —— 照 `pages/voice_hub_page.dart:113–122` 的既有范式
  /// （`_registerDirectoryEvents` / `_onDirectoryEvents` / dispose 解绑）。
  void _registerDirectoryEvents() {
    final AylaDirectoryEvents events = ref.read(directoryEventsProvider);
    _directoryEvents = events;
    _directoryEventRevision = events.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      events.addListener(_onDirectoryEvents);
    });
  }

  /// 目录事件处理 —— 逐条对应 web `ws/chat.ts` 的 `voice.channel.*` / `live.channel.*`
  /// 分支对目录列表的效应（`voice_hub_page.dart:124–154` 是同一套）：
  /// - `deleted` ⇒ 从对应桶移除该条（web `items.filter`）；
  /// - 人数 `patched` ⇒ 就地换该条的人数（`AylaPagedList.setItems`）；
  /// - 其余（`emitInvalidated`）⇒ **重取首页**（web 是置 `invalidated` 由用户点刷新；
  ///   照 `voice_hub_page.dart:153` 的 Flutter 口径直接重取，同一处偏离登记）。
  ///
  /// ⚠️ **只处理 voice / live**：`game` 不属本页侧栏（群内桌游页自己管，
  /// web 的侧栏也只有语音房与直播间两条列表）。
  /// ⚠️ 两条桶都按 groupId 分桶（[`_voiceByGroup`] / [`_liveByGroup`]）——
  /// 事件里的 id 只说明「哪个房间变了」，**不能**据此判断它属于哪个群 ⇒
  /// 必须遍历全部桶逐条比对（漏掉非当前群 = 切回旧群时列表仍是旧的）。
  void _onDirectoryEvents() {
    final AylaDirectoryEvents? events = _directoryEvents;
    if (events == null || events.revision == _directoryEventRevision) return;
    _directoryEventRevision = events.revision;
    final AylaDirectoryEvent? event = events.last;
    if (event == null) return;
    switch (event.kind) {
      case AylaDirectoryKind.voice:
        _applyVoiceDirectoryEvent(event);
      case AylaDirectoryKind.live:
        _applyLiveDirectoryEvent(event);
      case AylaDirectoryKind.game:
        // 侧栏没有桌游列表（web `ChannelSidebar.tsx:124–128` 只有 voice / live
        // 两条 `useDirectoryPage`）⇒ 不处理，也不假装修好了。
        break;
    }
  }

  void _applyVoiceDirectoryEvent(AylaDirectoryEvent event) {
    for (final AylaPagedList<AylaDirectoryVoiceEntry> list
        in _voiceByGroup.values) {
      if (event.deleted) {
        list.removeWhere(
          (AylaDirectoryVoiceEntry entry) => entry.card.id == event.id,
        );
        continue;
      }
      // 效应判据抽在 hub_support 的纯函数里（可定向测试，见 sort_channels_test）。
      // web `stores/voice.ts:156–165` 的 `patchChannel`：只改描述符；
      // 排序由 store 的 `sortVoiceChannels` 承担 ⇒ Flutter 侧排序表达在页面投影处
      // （见 _buildWide 的 aylaHubSortVoice）。
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) next =
          aylaHubApplyVoiceEvent(list.items, event);
      if (next.refresh) {
        unawaited(list.refresh());
        continue;
      }
      list.setItems(next.items);
    }
  }

  void _applyLiveDirectoryEvent(AylaDirectoryEvent event) {
    for (final AylaPagedList<AylaDirectoryLiveEntry> list
        in _liveByGroup.values) {
      if (event.deleted) {
        list.removeWhere(
          (AylaDirectoryLiveEntry entry) => entry.card.id == event.id,
        );
        continue;
      }
      // 同 voice：`live.channel.created` / `.updated` / `.status.changed` ⇒ 重取首页
      // （新开播/下播/改名都走这条）；`live.viewers.changed` ⇒ 只换在看人数
      // （web `stores/live.ts:218–224` 的 `patchViewerCount`：瞬态投影、不改排序）。
      final ({List<AylaDirectoryLiveEntry> items, bool refresh}) next =
          aylaHubApplyLiveEvent(list.items, event);
      if (next.refresh) {
        unawaited(list.refresh());
        continue;
      }
      list.setItems(next.items);
    }
  }

  /// 子群桶 → 状态层（web `GroupPage.tsx:265–283`）：
  /// 未选中时取服务端标出的默认组（缺席时退回列表里 `is_default` 的第一项）。
  ///
  /// ⚠️ 与 web 的**两处必要差异**（都登记，且都被端到端回归锁覆盖）：
  /// 1. web 的 `subgroupPage.items` 是 social record，**已含** `page.default`
  ///    （`stores/social.ts:174–178` 并进 items）⇒ `find(is_default)` 必然命中。
  ///    本页的子群列表是页面级 [AylaPagedList]、`default` 存在 [_defaultSubgroups]
  ///    ⇒ 这里必须**先把它并进待落盘列表**，否则「默认组不在本页 rows 里」时
  ///    未读/活跃度会挂到主群 key 上（用户实报「子群接到主群去了」的投影面）。
  /// 2. web 由 `stores/subgroup.ts` 在**写入侧**保证顺序（`setSubgroups` 保持服务端
  ///    顺序、默认组在前）；本页服务端 rows 已是 SUBGROUP_ORDER（`views.py:238`），
  ///    但**默认组是被并进来的**、可能落在尾部 ⇒ 这里按
  ///    [aylaSortSubgroupsByActivity] 排一遍，判据与 `ChannelSidebar.tsx:137` 一致。
  ///    （`widgets/shell/channel_sidebar.dart:465–480` 内部还有一套等价排序，
  ///    两套并存不冲突 —— 排序是幂等的；本文件不改那个件。）
  void _syncSubgroupsFor(String gid, AylaPagedList<AylaSubGroup> pager) {
    if (!pager.loaded) return;
    final AylaSubGroupState state = ref.read(subgroupStateProvider);
    if (state.subgroupsOf(gid).isEmpty && pager.items.isNotEmpty) {
      final AylaSubGroup? fallback = _defaultSubgroups[gid];
      final bool fallbackMissing = fallback != null &&
          !pager.items.any((AylaSubGroup sg) => sg.id == fallback.id);
      state.setSubgroups(
        gid,
        aylaSortSubgroupsByActivity(<AylaSubGroup>[
          if (fallbackMissing) fallback,
          ...pager.items,
        ]),
      );
    }
    if (state.activeSubgroupOf(gid) != null) return;
    // web tsx 268–269：未选中 ⇒ 用**服务端标出的默认组**确立首个 active。
    // 先试响应级 default（权威），再退回列表里 `is_default` 的第一项。
    final AylaSubGroup? fallback = _defaultSubgroups[gid];
    if (fallback != null) {
      state.setActiveSubgroup(gid, fallback.id);
      return;
    }
    for (final AylaSubGroup sg in state.subgroupsOf(gid)) {
      if (sg.isDefault) {
        state.setActiveSubgroup(gid, sg.id);
        return;
      }
    }
  }

  /// route param → store（web tsx 229–245）。只在值变化时写，避免 build 期间通知。
  void _syncRoute(AylaGroupScene effectiveScene) {
    if (_syncedGroupId == widget.groupId && _syncedScene == effectiveScene) {
      return;
    }
    _syncedGroupId = widget.groupId;
    _syncedScene = effectiveScene;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AylaGroupState group = ref.read(groupStateProvider);
      group.setCurrentGroup(widget.groupId);
      group.setActiveScene(effectiveScene);
      // web tsx 233：`useHomeStore.getState().setRecentGroup(id);`
      // —— **每次进群都写**（effect 依赖 [id, effectiveScene]；侧栏切群 ⇒ id 变 ⇒ 重写）。
      // 写的是共享单例 [kAylaHomePrefs]（= web 的 zustand 单例，见 home_support.dart 的说明）：
      // 宽屏侧栏切群（_buildWide 的 ServerRail.onSelectGroup）**只 context.go**、
      // 不经过 home_page 的 _openGroup ⇒ 此前 recent 永不更新，宽屏「回主页」跳错群。
      // 窄屏主页点卡片另有 HomePage.tsx:97 的写点（home_page.dart 的 _openGroup），
      // 与本行**同源不重复**：两条都是 web 真实存在的写点，写入同一个 key 幂等。
      kAylaHomePrefs.setRecentGroup(widget.groupId);
      // 非 chat 子场景显式关闭会话（web tsx 241–243：只有真的在聊天窗口里才自动已读）。
      if (effectiveScene != AylaGroupScene.chat &&
          ref.read(chatStateProvider).activeConversationId == widget.groupId) {
        ref.read(chatStateProvider).closeConversation();
      }
    });
  }

  /// 切场景：store + URL 回显（web tsx 286–292）。
  void _goScene(AylaGroupScene next) {
    ref.read(groupStateProvider).setActiveScene(next);
    final String id = Uri.encodeComponent(widget.groupId);
    context.go(next == AylaGroupScene.chat ? '/group/$id' : '/group/$id/${next.name}');
  }

  /// 打开群信息（web tsx 294–297）。
  void _openInfo() => _goScene(AylaGroupScene.info);

  /// 群头像两级点击（R-G4，tsx 317–324）：已在聊天 → 群信息；否则 → 回聊天。
  void _onAvatarClick(AylaGroupScene current) {
    if (current == AylaGroupScene.chat) {
      _openInfo();
    } else {
      _goScene(AylaGroupScene.chat);
    }
  }

  /// 下拉回主页（web tsx 120–135）：清 store + 退场 250ms 后回 `/group`。
  ///
  /// ⚠️ **不得把 `_pullDy` / `_pullOpacity` 归零**（2026-10-03 用户实报）。
  ///
  /// 此前这里写的是 `_pullDy = 0; _pullOpacity = 1;` ⇒ 松手后内容区**先瞬间弹回原位**
  /// （用户截图序列里那一帧「群聊天页面回弹」），再开始播退场动画，观感是「回弹一下才切换」。
  ///
  /// 组件库样张 `group_top_tabs.dart:501–520` 的 `_exitToHome` 是**正确口径**：
  /// > ≥80px 的落点：**顶栏与内容一起继续向下滑出**（250ms `--ease-in`）→ 250ms 后回主页。
  /// > ⚠️ 偏离 web 的调整（2026-09-20 用户要求）：web `pullToHome()` 写的是 `setPullOffset(0)`
  /// > —— 顶栏回到原位、内容继续下滑出屏，两者方向相反，观感上顶栏会先往上弹一段。
  /// > 用户要求 ≥80px 时不要回弹，改为**一起向下滑出**。
  ///
  /// ⇒ 保持当前 `_pullDy`（内容已下移的位置）与 `_pullOpacity`，由 `tabsDy = hiddenDy`
  /// 分支把**顶栏**也一起带下去；内容区随 `Transform.translate(0, _pullDy)` 保持在下移位。
  void _pullToHome() {
    setState(() {
      _leaving = true;
    });
    ref.read(groupStateProvider).reset();
    _leaveTimer?.cancel();
    _leaveTimer = Timer(
      const Duration(milliseconds: kAylaGroupExitTransitionMs),
      () {
        if (mounted) context.go('/group');
      },
    );
  }

  Widget _renderScene(AylaGroupScene scene) {
    switch (scene) {
      case AylaGroupScene.info:
        return GroupInfoPage(groupId: widget.groupId);
      case AylaGroupScene.chat:
        return GroupChatPage(groupId: widget.groupId);
      case AylaGroupScene.live:
        return GroupLivePage(
          groupId: widget.groupId,
          routeChannelId: widget.liveChannelId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.voice:
        return GroupVoicePage(
          groupId: widget.groupId,
          routeChannelId: widget.voiceChannelId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.posts:
        return GroupPostsPage(
          groupId: widget.groupId,
          postId: widget.postId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
      case AylaGroupScene.games:
        return GroupGamesPage(
          groupId: widget.groupId,
          onExit: () => _goScene(AylaGroupScene.chat),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isNarrow = !aylaDirectoryIsWide(context);
    final AylaGroupState groupState = ref.watch(groupStateProvider);
    final AylaChatState chat = ref.watch(chatStateProvider);
    final AylaSubGroupState subgroups = ref.watch(subgroupStateProvider);
    final AylaVoiceState voice = ref.watch(voiceStateProvider);
    final AylaLiveState live = ref.watch(liveStateProvider);
    final AylaGroupScene effectiveScene = aylaGroupSceneFromRoute(
      scene: widget.scene,
      postId: widget.postId,
      voiceChannelId: widget.voiceChannelId,
      liveChannelId: widget.liveChannelId,
    );
    _syncRoute(effectiveScene);
    // 宽屏渲染路由场景（新群首帧即正确），窄屏用 store（tsx 227）。
    final AylaGroupScene contentScene =
        isNarrow ? groupState.activeScene : effectiveScene;
    final AylaConversationSummary? currentGroup =
        chat.byId(widget.groupId);
    final String groupName = currentGroup?.title ?? '群聊';

    if (isNarrow) {
      return _buildNarrow(context, groupState, contentScene, groupName, currentGroup);
    }
    return _buildWide(
      context,
      chat,
      subgroups,
      voice,
      live,
      contentScene,
      groupName,
      currentGroup,
    );
  }

  // ======================= 宽屏三列（tsx 405–436）=======================

  Widget _buildWide(
    BuildContext context,
    AylaChatState chat,
    AylaSubGroupState subgroups,
    AylaVoiceState voice,
    AylaLiveState live,
    AylaGroupScene contentScene,
    String groupName,
    AylaConversationSummary? currentGroup,
  ) {
    final List<AylaConversationSummary> groups =
        _directory?.groupsWith(widget.groupId) ??
            const <AylaConversationSummary>[];
    // 排序按「新内容」事件（web tsx 205–209 + groupActivity.ts:238–259）。
    final List<AylaConversationSummary> sorted =
        aylaSortGroupsByActivity(
      groups,
      (AylaConversationSummary c) => aylaGroupActivityOf(
        groupId: c.id,
        lastMessage: c.lastMessage,
        liveChannels: live.channels.values,
        voiceChannels: voice.channels.values,
        gameRooms: aylaBoardgameStore.rooms,
        posts: aylaPostsStore.posts,
        groupActivityAt: chat.groupActivityAt,
      ),
    );
    return Stack(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AylaServerRail(
              groups: aylaServerRailGroups(
                groups: sorted,
                liveChannels: live.channels.values,
                voiceChannels: voice.channels.values,
                gameRooms: aylaBoardgameStore.rooms,
              ),
              currentGroupId: widget.groupId,
              onSelectGroup: (String gid) =>
                  context.go('/group/${Uri.encodeComponent(gid)}'),
              onCreateGroup: () => setState(() => _showGroupCreate = true),
              loadMore: () => _directory?.loadMore() ?? Future<void>.value(),
              refresh: () => _directory?.refresh() ?? Future<void>.value(),
              loading: _directory?.loading ?? false,
              error: _directory?.error,
              hasMore: _directory?.hasMore ?? false,
              invalidated: _directory?.invalidated ?? false,
            ),
            AylaChannelSidebar(
              groupId: widget.groupId,
              groupName: groupName,
              activeScene: contentScene,
              onSelectScene: _goScene,
              onOpenInfo: _openInfo,
              subgroups: <AylaChannelSubgroup>[
                for (final AylaSubGroup sg
                    in subgroups.subgroupsOf(widget.groupId))
                  AylaChannelSubgroup(
                    id: sg.id,
                    name: sg.name,
                    isDefault: sg.isDefault,
                    muted: sg.muted ?? false,
                    unreadCount: sg.unreadCount,
                    lastMessageSeq: sg.lastMessageSeq ?? 0,
                  ),
              ],
              activeSubgroupId: subgroups.activeSubgroupOf(widget.groupId),
              onSelectSubgroup: (String sgId) => ref
                  .read(subgroupStateProvider)
                  .setActiveSubgroup(widget.groupId, sgId),
              subgroupDirectory: _channelDirectory(_subgroups),
              // 子群编辑入口 = 群主/管理员（web `ChannelSidebar.tsx:139` 同源）。
              canManageSubgroups: _canManage(currentGroup),
              // ⚠️ **排序表达在投影处**（不改 `widgets/shell/channel_sidebar.dart` —— 它归
              // sidebar-dev；组件在 build 里排序会与 `AnimatedPositioned` 的重排动画打架，
              // 见 task-5 的落点说明）。web 是 store 层排好（`stores/voice.ts:128/147/158`
              // 每次写都过 `sortVoiceChannels`）⇒ 数据进组件前就是有序的，这里等价。
              // 排序事实源 `utils/sortChannels.ts:32–46`，判据见 [aylaHubSortVoice]。
              // 时间戳取自**全局** `voiceState` 的快照（web 同源：`stores/directory.ts:161`
              // 用 voice store 的描述符替换 record 的同 id 项）。
              voiceRooms: <AylaChannelVoiceRoom>[
                for (final AylaDirectoryVoiceEntry entry in aylaHubSortVoice(
                  _voice?.items ?? const <AylaDirectoryVoiceEntry>[],
                  factsOf: <String, AylaVoiceSortFacts>{
                    for (final AylaVoiceChannelSnapshot c in voice.channels.values)
                      c.id: AylaVoiceSortFacts.ofSnapshot(c),
                  },
                ))
                  AylaChannelVoiceRoom(
                    id: entry.card.id,
                    name: entry.card.name,
                    memberCount: entry.card.memberCount ?? 0,
                  ),
              ],
              activeVoiceChannelId: widget.voiceChannelId,
              onSelectVoiceChannel: _openVoiceChannel,
              voiceMemberCount: _voiceMemberCount(voice),
              voiceDirectory: _channelDirectory(_voice),
              // 同 voiceRooms：排序在投影处表达（web store 层排好，`stores/live.ts:152/168/177`）。
              // 判据 `utils/sortChannels.ts:48–61`（在播 → 曾播 → 从未），
              // 实现 [aylaHubSortLive]（库内既有件，本页此前未用 ⇒ 开播/下播后不重排）。
              liveRooms: <AylaChannelLiveRoom>[
                for (final AylaDirectoryLiveEntry entry
                    in aylaHubSortLive(
                  _live?.items ?? const <AylaDirectoryLiveEntry>[],
                ))
                  AylaChannelLiveRoom(
                    id: int.tryParse(entry.card.id) ?? 0,
                    title: entry.card.title,
                    cover: entry.card.cover,
                    isLive: entry.card.status == AylaLiveStatus.live,
                  ),
              ],
              activeLiveChannelId: widget.liveChannelId,
              onSelectLiveChannel: (int id) => _openLiveChannel('$id'),
              liveDirectory: _channelDirectory(_live),
              postUnread: currentGroup?.postUnreadCount ?? 0,
              // ⚠️ **不要传 `playing: false`**：该参数是 web `useIsPresent()` 的等价物
              // （`ChannelSidebar.tsx:83–97`：面板退场中才 `inert` = 禁指针 + 排除语义）。
              // 常驻面板必须为在场态（默认 true）；传 false 会让整列频道侧栏
              // 永久 `IgnorePointer(ignoring: true)` —— 视觉正常但**完全点不动**
              // （2026-09-29 用户实报「宽屏第二列根本无法点击」）。
            ),
            Expanded(
              // ⚠️ **不要用 `AylaConversationTransition` 的 wait 编排**（2026-09-29 用户二次实报
              // 「切群还是在跳转闪屏」后的收口）：
              //
              // web 的 `ConversationTransition(identity="group:<id>", panels=true)`
              // （`components/motion/ConversationTransition.tsx:12–24`）里，`ConversationOwner` 的变体是
              // **`auroraquaPanelOrchestration` —— enter / center / exit 三个全是空对象**
              // （`motion/auroraquaMotion.ts:29`）⇒ `AnimatePresence mode="wait"` 的「等旧件退完」
              // **当帧即满足**：旧 owner 立即卸载、新 owner 立即挂载，**宿主不做任何淡出/位移**；
              // 入场只由新 owner 内部各分区自己播（`GroupChat.tsx:283–332` 的 `initial="enter"`）。
              //
              // 而 `AylaConversationTransition` 在 `panels: true && childOwnsPanels: false` 档
              // （= 本页上轮的调用形状）走的是**「宿主整体淡出旧件」的兜底**（`gestures.dart:402–415`）：
              // 旧件被 `FadeTransition(300ms)` 淡到 0、**期间不挂新件**，300ms 后才换 ⇒ 实测
              // 内容区出现「0.95 → 0.00 历时 304ms」的淡出段。叠加本页 builder 之前**不消费
              // identity**（旧槽里渲染的是**新群**内容）⇒ 用户看到的就是「新群内容闪一下 →
              // 消失 300ms → 又出现」。
              //
              // ⇒ Flutter 等价物 = **换 key 的 `KeyedSubtree`**：旧子树与新子树在**同一帧**内
              // 卸载/挂载（同一时刻只有一个会话 owner，与 web 的净效果一致），无淡出、无空档。
              child: KeyedSubtree(
                key: ValueKey<String>('group:${widget.groupId}'),
                child: _renderScene(contentScene),
              ),
            ),
          ],
        ),
        // 建群弹窗（web tsx 433：`{showGroupCreate && <GroupCreateDialog onClose/>}`）。
        //
        // ⚠️ **必须接完整接线**（2026-10-02 问题 14）：本件按「装配口径」把成员搜索
        // （web `GroupCreateDialog.tsx:29` 的 `useSocialPage("users", {q})`）与两条提交
        // （tsx 46–64 建群 / 66–80 私聊）交给页面注入；只传 `onClose` 时
        // `group_create_dialog.dart:184–185` 的 `if (submit == null) return;` 会
        // **静默返回** ⇒ 宽屏点「建群」既不报错也不建群（用户实报）。
        //
        // 复用 [AylaCreateGroupForm]（`layout/create_sheet_forms.dart`）而不是复制装配：
        // 它就是 web 同一份 `GroupCreateDialog` 的接线（CreateFab 的 group 分支
        // `tsx:75–77`，**不带 CreateSheet 外壳** —— 组件自带弹层），
        // 内含搜索分页 + 300ms 防抖消费 + 建群/私聊 + 跳转（tsx:57–58 / 73–74）。
        if (_showGroupCreate)
          Positioned.fill(child: _buildGroupCreate()),
        if (_directory?.error != null && (_directory?.raw.isEmpty ?? true))
          const SizedBox.shrink(),
      ],
    );
  }

  /// 建群弹层（web tsx 433：`{showGroupCreate && <GroupCreateDialog onClose/>}`）。
  ///
  /// 默认挂真实 [AylaCreateGroupForm]（= web 同一份 `GroupCreateDialog` 的接线：
  /// 成员搜索 `GroupCreateDialog.tsx:29`、建群 `tsx:46–64`、私聊 `tsx:66–80`、
  /// 跳转 `tsx:58/74`）；[aylaGroupPageCreateGroupBuilder] 非 null 时用它（测试注入）。
  Widget _buildGroupCreate() {
    void close() {
      if (mounted) setState(() => _showGroupCreate = false);
    }
    final AylaGroupPageCreateGroupBuilder? builder =
        aylaGroupPageCreateGroupBuilder;
    if (builder != null) return builder(close);
    return AylaCreateGroupForm(onClose: close);
  }

  static bool _canManage(AylaConversationSummary? conv) =>
      conv?.myRole == AylaConversationMemberRole.owner ||
      conv?.myRole == AylaConversationMemberRole.admin;

  /// 「语音在麦人数」——web 侧栏场景项的状态文本（`ChannelSidebar.tsx:271`）；
  /// 取**当前群下有人房间**的在麦总数（无人 = 0 ⇒ 不显示裸文本，`voiceMemberCount > 0` 才渲染）。
  int _voiceMemberCount(AylaVoiceState voice) => voice.channels.values
      .where((AylaVoiceChannelSnapshot c) =>
          c.allowedGroupIds.contains(widget.groupId))
      .fold<int>(0, (int sum, AylaVoiceChannelSnapshot c) =>
          sum + (c.memberCount ?? 0));

  AylaChannelDirectory _channelDirectory<T>(AylaPagedList<T>? pager) {
    if (pager == null) return AylaChannelDirectory.none;
    return AylaChannelDirectory(
      total: pager.total,
      loading: pager.loading,
      error: pager.error,
      hasMore: pager.hasMore,
      invalidated: pager.invalidated,
      loadMore: pager.loadMore,
      refresh: pager.refresh,
    );
  }

  void _openVoiceChannel(String channelId) {
    ref.read(groupStateProvider).setActiveScene(AylaGroupScene.voice);
    context.go(
      '/group/${Uri.encodeComponent(widget.groupId)}/voice/'
      '${Uri.encodeComponent(channelId)}',
    );
  }

  void _openLiveChannel(String channelId) {
    ref.read(groupStateProvider).setActiveScene(AylaGroupScene.live);
    context.go(
      '/group/${Uri.encodeComponent(widget.groupId)}/live/'
      '${Uri.encodeComponent(channelId)}',
    );
  }

  // ======================= 窄屏（tsx 438–496）=======================

  Widget _buildNarrow(
    BuildContext context,
    AylaGroupState groupState,
    AylaGroupScene contentScene,
    String groupName,
    AylaConversationSummary? currentGroup,
  ) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final double viewportHeight = MediaQuery.sizeOf(context).height;
    final double safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    // 首帧的顶栏位置 = 原底栏位置（web tsx 455：`100dvh - 64px - safe-area`）。
    final double hiddenDy = viewportHeight - 64 - safeBottom;
    final double progress =
        (_pullDy / kAylaGroupPullExitThreshold).clamp(0.0, 1.0);

    double tabsDy;
    Duration tabsDuration;
    Curve tabsCurve;
    if (reduced) {
      tabsDy = 0;
      tabsDuration = Duration.zero;
      tabsCurve = Curves.linear;
    } else if (_leaving) {
      tabsDy = hiddenDy;
      tabsDuration = const Duration(milliseconds: kAylaGroupExitTransitionMs);
      tabsCurve = AylaCurves.easeIn;
    } else if (_pullDy > 0) {
      tabsDy = _pullDy;
      tabsDuration = Duration.zero;
      tabsCurve = Curves.linear;
    } else if (_resetting) {
      // 未过阈值 ⇒ 200ms --ease-out 平滑回弹（样张 group_top_tabs.dart:492–496 /
      // web GroupPage.tsx 的 pullTransition）。**不能瞬时归零**（用户实报跳变）。
      tabsDy = 0;
      tabsDuration = const Duration(milliseconds: 200);
      tabsCurve = Curves.easeOut;
    } else {
      tabsDy = _entered ? 0 : hiddenDy;
      tabsDuration = AylaDurations.auroraqua;
      tabsCurve = AylaCurves.auroraquaEaseOut;
    }

    return Column(
      children: <Widget>[
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: tabsDy),
          duration: tabsDuration,
          curve: tabsCurve,
          builder: (BuildContext context, double value, Widget? child) =>
              AylaGroupTopTabs(
            groupName: groupName,
            activeScene: contentScene,
            avatarUrl: (currentGroup?.avatar.isEmpty ?? true)
                ? null
                : currentGroup!.avatar,
            onSelectScene: _goScene,
            onAvatarClick: () => _onAvatarClick(groupState.activeScene),
            postUnread: currentGroup?.postUnreadCount ?? 0,
            offset: Offset(0, value),
            // ★ 窄屏「下拉顶部导航栏返回」（用户 2026-10-02 实报：内容区能触发、顶栏反而没反应）。
            //
            // web 把 pullHandlers 展开在 **.group-top-tabs 那一条**上
            // （GroupTopTabs.tsx:62 的 {...pullHandlers}），几何 = 宽 100% x 高 64px
            // （group.css:23-31 + :36 的 .group-top-nav{height:64px}）
            // => **触发区就是顶栏这一条，内容区不参与起手**。
            // 本件 group_top_tabs.dart:280-295 已按此实现（HitTestBehavior.opaque），
            // 只是此前没接线 => 顶栏下拉无反应。此处补上。
            onPullUpdate: (DragUpdateDetails details) =>
                _onPullUpdate(details, reduced),
            onPullEnd: (DragEndDetails details) =>
                _onPullEnd(details, reduced),
            onPullCancel: _resetPull,
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // ⚠️ **内容区不接下拉**（用户 2026-10-02 实报：整个页面下拉都生效返回手势）。
            //
            // web 的 pullHandlers **只展开在 .group-top-tabs 那一条**（GroupTopTabs.tsx:62），
            // 内容区（.group-content）不参与起手 => 下拉返回**只在顶栏 64px 内触发**。
            // 本页此前把 onVerticalDrag* 挂在内容区 GestureDetector 上，导致：
            //   ① 整页下拉都能触发返回（与 web 不符）；
            //   ② 顶栏反而没反应（回调没接到 AylaGroupTopTabs）。
            // 现已把下拉接线移到上面的 AylaGroupTopTabs（见其注释），此处只保留**横向**手势。
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (reduced || _leaving) return;
              setState(() {
                _dragDx += details.delta.dx;
                _dragDy += details.delta.dy;
              });
            },
            onHorizontalDragEnd: (DragEndDetails details) =>
                _onSceneDragEnd(details, contentScene, reduced),
            onHorizontalDragCancel: _resetDrag,
            child: ClipRect(
              // ★ 纵向位移（退场时「内容区继续向下滑出，与顶栏同向」）：
              // 组件库样张 `_exitToHome`（group_top_tabs.dart:501–520）的正确口径 ——
              // 「顶栏与内容**一起**继续向下滑出（250ms --ease-in）→ 250ms 后回主页」，
              // 并注明「用户要求 ≥80px 时**不要回弹**」（web 原版会让顶栏先往上弹一段）。
              //
              // ⚠️ 此前 `_pullToHome` 写 `_pullDy = 0; _pullOpacity = 1;` ⇒ 松手后内容区
              // **先瞬间弹回原位**再播退场（用户 2026-10-03 截图里那一帧「回弹」）。
              // 现在：跟手期 = 瞬时（Duration.zero）、退场期 = 250ms 滑到 hiddenDy。
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _leaving ? hiddenDy : _pullDy),
                duration: _leaving
                    ? const Duration(milliseconds: kAylaGroupExitTransitionMs)
                    : Duration.zero,
                curve: AylaCurves.easeIn,
                builder: (
                  BuildContext context,
                  double dy,
                  Widget? child,
                ) =>
                    Transform.translate(offset: Offset(0, dy), child: child),
                child: ClipRect(
              // ⚠️ 横向位移走 [TweenAnimationBuilder]：
              // · **跟手中**（`_sceneResetting == false`）→ `Duration.zero`，1:1 跟手；
              // · **未触发切换的回弹**（`_sceneResetting == true`）→ **200ms --ease-out**；
              // · **触发切换** → `_goScene` 换场景，`_dragDx` 已瞬时归零 ⇒ 新场景从 0 起（不回弹）。
              // 此前直接 `Transform.translate(_dragDx)` 且松手瞬时归零 ⇒ 未过阈值时**跳变**
              // （用户 2026-10-03 实报「不触发页面切换时回弹也不是跳变的」）。
              child: Transform.scale(
                scale: 1 - 0.02 * progress,
                child: Opacity(
                  opacity: _pullOpacity,
                  // ★ 横滑位移**不再包在这里**（web 两层分离，见 [AylaSceneFade.dragDx]）：
                  // 由 `AylaSceneFade` 的**每个槽位各自**施加 ⇒
                  //   · 在场槽位跟手；退场槽位用**冻结值**（保留 held offset，不跳回中心）；
                  //   · 新旧场景**不共享**一个位移值（`useMotionDrag.ts:12–14`：
                  //     `values cannot be shared between the outgoing and incoming scene`）。
                  child: AylaSceneFade(
                    scene: contentScene,
                    builder: _renderScene,
                    dragDx: reduced ? 0 : _dragDx,
                    // 跟手瞬时；未提交 ⇒ 200ms `--ease-out` 回弹（`dragSnapToOrigin`）。
                    dragDuration: _sceneResetting
                        ? const Duration(milliseconds: 200)
                        : Duration.zero,
                    elastic: kAylaDragElastic,
                    // 先冻结（`_outgoingDragDx = widget.dragDx`）再复位 ⇒ 新场景从 0 起。
                    onDragReset: () {
                      if (_dragDx != 0) setState(() => _dragDx = 0);
                    },
                  ),
                ),
              ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 下拉跟手（web tsx 145–152）：只在向下拉时位移，上推不跟手。
  void _onPullUpdate(DragUpdateDetails details, bool reduced) {
    if (reduced || _leaving) return;
    final double next = _pullDy + details.delta.dy;
    if (details.delta.dy <= 0 && next <= 0) return;
    setState(() {
      _pullDy = next < 0 ? 0 : next;
      final double p =
          (_pullDy / kAylaGroupPullExitThreshold).clamp(0.0, 1.0);
      _pullOpacity = 1 - 0.4 * p;
    });
  }

  /// 松手：位移 ≥80px ⇒ 回主页；否则 **200ms `--ease-out` 平滑回弹**。
  ///
  /// ⚠️ **不要加 velocity 判据**（2026-10-03 用户实报「下拉了但内容区最后回弹了」）：
  /// 组件库样张 `group_top_tabs.dart:485–499` 的口径是 **`_pullY >= _threshold` 单条件**
  /// （web `GroupPage.tsx` 的 `onEnd` 同样只看 `pullY >= 80`）。
  /// 此前多写了一个 `velocity > 0` ⇒ **慢慢拉过 80px 后松手（速度为 0 或微负）不回主页**，
  /// 观感就是「明明拉够了却又弹回去」。
  void _onPullEnd(DragEndDetails details, bool reduced) {
    if (reduced || _leaving) return;
    if (_pullDy >= kAylaGroupPullExitThreshold) {
      _pullToHome();
      return;
    }
    _resetPull();
  }

  /// 未过阈值 ⇒ 回弹。
  ///
  /// ⚠️ **必须走动画**（同用户 2026-10-03 实报）：此前直接 `_pullDy = 0` **无动画**，
  /// 内容区从半途位置**瞬时跳回**（跳变）。样张 `group_top_tabs.dart:492–496` 是
  /// **200ms `--ease-out`**（web `GroupPage.tsx` 的 `pullTransition` 同档）。
  /// 这里用 `_resetting` 标记让 `tabsDy` 分支走 200ms easeOut，动画结束后复位。
  void _resetPull() {
    if (_pullDy == 0 && _pullOpacity == 1) return;
    setState(() {
      _resetting = true;
      _pullDy = 0;
      _pullOpacity = 1;
    });
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _resetting = false);
    });
  }

  /// 横滑切场景（web tsx 355–372）：松手判定走 [aylaResolveSwipeCommit]。
  ///
  /// ## ⚠️ 关键：触发切换时**保留 `_dragDx`，不归零**（2026-10-03 用户实报修复）
  ///
  /// web 的 `GroupSceneSurface`（`GroupPage.tsx:499–538`）把「淡出层」与「位移层」**分成两层**，
  /// 其文件级注释原文：
  /// > **Panels enter from their own edges; the drag layer retains the held offset
  /// >  throughout exit.**
  ///
  /// - 外层 `group-scene-inner` 的 `exit` 是 `{ x: 0, opacity: 0 }` ⇒ **x 恒 0**，退场只淡出；
  /// - 内层 `group-scene-drag` 的 `style={{ x: drag.offset }}` ⇒ **退场期间保留 held offset**
  ///   （`useMotionDrag.ts:14–17`：`Normal exit releases the gesture but preserves its visible
  ///    displacement; the route layer can continue from that frame instead of snapping back
  ///    to center.`）；
  /// - `dragSnapToOrigin` ⇒ 未提交时才回弹到 0。
  ///
  /// ⇒ 所以提交时**绝不能先归零**：那正是用户看到的「滑动结束后上一个页面有跳变回弹」
  ///   （旧场景被同一个值带着瞬间跳回中心）。
  ///   正确做法：保留当前位移 → `_goScene` 换场景 → `AylaSceneFade.didUpdateWidget`
  ///   **冻结**该位移给退场槽位 ⇒ 旧场景停在原处淡出；新场景从 0 起（位移不共享）。
  ///
  /// 未提交（`commit == 0`）才走 **200ms `--ease-out`** 回弹（`dragSnapToOrigin` 语义）。
  void _onSceneDragEnd(
    DragEndDetails details,
    AylaGroupScene contentScene,
    bool reduced,
  ) {
    final double width = MediaQuery.sizeOf(context).width;
    final double net = _dragDx;
    final double cross = _dragDy;
    if (reduced || _leaving) {
      setState(() {
        _dragDx = 0;
        _dragDy = 0;
      });
      return;
    }
    final int commit = aylaResolveSwipeCommit(
      net: net,
      cross: cross,
      velocity: details.velocity.pixelsPerSecond.dx,
      size: width,
    );
    if (commit == 0) {
      // 未提交 ⇒ `dragSnapToOrigin`：200ms `--ease-out` 平滑回弹（**不跳变**）。
      _resetDrag();
      return;
    }
    // ★ 提交 ⇒ **保留 `_dragDx`**（web「retains the held offset throughout exit」）。
    //   只清纵向（纵向由下拉链路单独拥有，与本次切换无关）；
    //   横向会在下一次拖动开始时被覆盖，故不需在此复位。
    setState(() => _dragDy = 0);
    final int base = aylaGroupSceneOrderIndex(contentScene);
    final int next = (base + commit + kAylaGroupSceneOrder.length) %
        kAylaGroupSceneOrder.length;
    _goScene(kAylaGroupSceneOrder[next]);
  }

  /// 未触发切换时的横向回弹：**200ms `--ease-out`**（`_sceneResetting` 驱动）。
  ///
  /// 与下拉回弹同理：**不能瞬时归零**，否则内容区从半途位置跳回（用户实报）。
  void _resetDrag() {
    if (_dragDx == 0 && _dragDy == 0) return;
    setState(() {
      _sceneResetting = true;
      _dragDx = 0;
      _dragDy = 0;
    });
    _dragResetTimer?.cancel();
    _dragResetTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _sceneResetting = false);
    });
  }
}

/// 窄屏场景切换的**淡出层** —— web `GroupPage.tsx:499–539` 的 `GroupSceneSurface`
/// + `AnimatePresence mode="sync"` 的等价物。
///
/// web 的 variants：`enter/center` 都是 `{x:0, opacity:1}`、`exit` 是 `{x:0, opacity:0}`
/// ⇒ **新场景无淡入、旧场景 300ms 淡出**（横向位移由 drag 层单独拥有，切场景时归零）。
/// 本件用「固定槽位 + 保留旧场景子树淡出」表达：同一场景在切换前后位于**同一 child index**、
/// 槽位内**包装链恒定**（见 [_AylaSceneFadeState.build] 的说明）⇒ 旧场景的
/// Element/State（会话历史/滚动位置/入场动画进度）在淡出期间**原地存活**、
/// 不重建、不重播入场，动画结束才卸载 —— 与 `AnimatePresence` 保管退出实例同一语义。
///
/// 公开命名（2026-10-02 问题 7 修复）：本件的判据是「切场景时旧场景的 `initState`
/// **不得**被再次调用」，只有能注入**可观测的自定义场景组件**才能验证 ⇒ 需要从
/// 测试直接挂载它。私有类无法在 widget test 里构造（`invalid_use_of_visible_for_testing`
/// 之外的私名引用根本编译不过）。
class AylaSceneFade extends StatefulWidget {
  const AylaSceneFade({
    super.key,
    required this.scene,
    required this.builder,
    this.dragDx = 0,
    this.dragDuration = Duration.zero,
    this.elastic = 1,
    this.onDragReset,
  });

  /// 当前场景（web 的 `activeScene` 传入 `AnimatePresence` 的那一个）。
  final AylaGroupScene scene;

  /// 场景构建器（GroupPage 传 `_renderScene`）。
  final Widget Function(AylaGroupScene scene) builder;

  /// 横滑位移（**只作用于在场场景**；退场场景用切换那一刻冻结的值）。
  ///
  /// ## 事实源（web `GroupPage.tsx:499–538` 的两层结构）
  /// ```jsx
  /// // "Panels enter from their own edges; the drag layer retains the held offset
  /// //  throughout exit."
  /// <motion.div className="group-scene-inner" variants={variants} …>   // ← 外层：只做 opacity
  ///   <motion.div className="group-scene-drag" style={{ x: drag.offset }}
  ///     dragConstraints={SCENE_DRAG_CONSTRAINTS} dragSnapToOrigin …>     // ← 内层：持位移
  /// ```
  /// - 外层 `exit` = `{ x: 0, opacity: 0 }` ⇒ **x 恒 0**，退场只淡出；
  /// - 内层 `style={{ x: drag.offset }}` ⇒ **退场期间保留 held offset**
  ///   （`useMotionDrag.ts:14–17`：`Normal exit releases the gesture but preserves its
  ///    visible displacement; the route layer can continue from that frame instead of
  ///    snapping back to center.`）；
  /// - `dragSnapToOrigin` ⇒ 未提交时**回弹到 0**。
  ///
  /// ⚠️ 两层必须**分离**：此前 `GroupPage` 用**单个**共享 `_dragDx` 包住整个场景栈 ⇒
  /// 触发切换后新旧场景被同一个值驱动 ⇒ 旧场景在淡出时位移被一起归零
  /// （用户 2026-10-03 实报「滑动结束后上一个页面有跳变回弹」）。
  final double dragDx;

  /// 位移变化的时长：跟手期 `Duration.zero`（1:1）；回弹期 200ms `--ease-out`。
  final Duration dragDuration;

  /// 跟手弹性（web `dragElastic`，`kAylaDragElastic` = .8）。
  final double elastic;

  /// 切场景并冻结退场位移后回调 ⇒ 宿主把 `_dragDx` 复位（**新场景从 0 起**）。
  ///
  /// 时序必须是「**先冻结、后复位**」：若宿主先复位，本件 `didUpdateWidget` 里读到的
  /// `widget.dragDx` 已是 0 ⇒ 旧场景冻结到 0 ⇒ 仍然跳回中心（本次修复的反例）。
  final VoidCallback? onDragReset;

  @override
  State<AylaSceneFade> createState() => _AylaSceneFadeState();
}

class _AylaSceneFadeState extends State<AylaSceneFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AylaDurations.auroraqua,
    value: 1,
  );

  /// 正在退场的旧场景（null = 无）。
  AylaGroupScene? _outgoing;

  /// 切换那一刻**冻结**的横滑位移 —— 退场槽位用它（web `GroupPage.tsx:499`：
  /// `the drag layer retains the held offset throughout exit`）。
  double _outgoingDragDx = 0;

  /// 淡出代际（见 [didUpdateWidget] 的守卫说明）。
  int _fadeGeneration = 0;

  @override
  void didUpdateWidget(covariant AylaSceneFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene == widget.scene) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _outgoing = null);
      _outgoingDragDx = 0;
      return;
    }
    setState(() => _outgoing = oldWidget.scene);
    // ★ ① 冻结退出那一刻的可见位移给**退场槽位**（web：内层 drag 层在 exit 期间
    //   **保留** held offset，而不是 snap 回中心 —— 后者就是用户看到的跳变回弹）。
    _outgoingDragDx = widget.dragDx;
    // ★ ② 冻结后把**在外**的位移复位为 0 ⇒ **新场景从 0 起**
    //   （`useMotionDrag.ts:12–14`：`values cannot be shared between the outgoing and
    //    incoming scene`）。
    //
    // ⚠️ **必须排到帧末**：本方法在 `didUpdateWidget` 内（build 阶段），
    //   此刻调 `setState` 会让宿主二次重建，破坏本件「固定槽位 + 同型包装」的不变量
    //   （实测：问题 7 的三个回归锁立刻转红 —— 旧场景被重建、initState 重跑）。
    //   排到帧末则只影响**下一帧**的新场景起始位移，观感无差。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDragReset?.call();
    });
    _fade.value = 1;
    // 代际守卫：快速连切（A→B→A，300ms 内）时，前一次的 reverse() 也会 complete，
    // 若不加守卫会把**后一次**的退场场景提前清掉（场景直接消失、无淡出）。
    final int generation = ++_fadeGeneration;
    _fade.reverse().whenComplete(() {
      if (mounted && generation == _fadeGeneration) {
        setState(() => _outgoing = null);
        _outgoingDragDx = 0;
      }
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  /// 每个场景一个**固定槽位**（index = [AylaGroupScene.values] 的序号），
  /// 且槽位内的**包装链恒定**——这是本件正确性的核心不变量。
  ///
  /// ## 根因（2026-10-02 问题 7）
  /// 旧实现把退场场景包进一层**临时新建的 `FadeTransition`**（外层还叠了
  /// `ExcludeFocus/ExcludeSemantics/IgnorePointer`）⇒ 旧场景的**父 Element 类型变了**
  /// ⇒ Flutter 判定「不同 widget」⇒ 旧场景子树**整体重建 Element/State**
  /// ⇒ 场景页重新 `initState` ⇒ **重播它自己的入场动画**，然后才开始淡出。
  /// 用户看到的就是「离开的页面又播了一遍入场动画」（本次验收核心）。
  ///
  /// ## 修法
  /// ① **固定槽位**：同一场景在切换前后永远落在同一个 child index（槽位永不移位）；
  /// ② **同型包装**：每个非空槽位都套**完全相同类型序列**的包装
  ///   （`FadeTransition → ExcludeFocus → ExcludeSemantics → IgnorePointer → KeyedSubtree`），
  ///   只在**参数**上区分在场/退场 ⇒ Element 逐层原地复用、State 不重建。
  ///   直接让 `builder(...)` 上抬一层是**不够的**：当前场景原本不套包装，
  ///   退场时类型序列会从「1 层」变「5 层」，第 2 层就分叉了。
  ///
  /// ## 为什么占位用 [Offstage]
  /// `Stack(fit: StackFit.expand)` 会给**无定位**子件发 `BoxConstraints.tight(stackSize)`
  /// ⇒ 裸 `SizedBox.shrink()` 会被强制撑满、变成挡住整个当前场景的命中层；
  /// [Offstage] 撑满但不绘制、不参与 hit test 与语义。
  ///
  /// 语义对照（web `GroupPage.tsx:507–511` 的 variants）：
  /// · 在场（`enter/center`）= `{x:0, opacity:1}` ⇒ `kAlwaysCompleteAnimation`（恒 1、无淡入）；
  /// · 退场（`exit`）= `{x:0, opacity:0, 300ms}` ⇒ [_fade] 反向播放。
  /// 退场期间 `IgnorePointer` + `ExcludeFocus` + `ExcludeSemantics` 与原实现一致
  /// （web 侧由 `pointerEvents: drag.present ? undefined : "none"` 表达，tsx 520）。
  Widget _slot(AylaGroupScene scene, {required bool outgoing}) {
    // ★ **两层分离**（web `GroupPage.tsx:512–536`）：
    //   · 外层 = opacity 层（`group-scene-inner`，其 exit 的 `x` 恒 0）；
    //   · 内层 = 位移层（`group-scene-drag`，`style={{ x: drag.offset }}`）。
    //
    // 在场：位移 = 实时 `dragDx`（跟手瞬时 / 未提交时 200ms 回弹 → `dragSnapToOrigin`）。
    // 退场：位移 = **切换那一刻冻结的值**，此后不再变化
    //      （`Panels enter from their own edges; the drag layer retains the held offset
    //        throughout exit.`）⇒ 旧场景淡出时**停在原处**，不会跳回中心。
    final double dx = outgoing
        ? _outgoingDragDx * widget.elastic
        : widget.dragDx * widget.elastic;
    // ⚠️ **两档必须同型**（本件的核心不变量，见 `_slot` 文档的「同型包装」）：
    // 早前写成 `outgoing ? Transform.translate(...) : TweenAnimationBuilder(...)`
    // ⇒ 槽位内的**第一层类型**在切场景时从 A 变 B ⇒ Flutter 判定「不同 widget」
    // ⇒ 场景子树整体重建 Element/State ⇒ 旧场景 `initState` 重跑（问题 7 复发）。
    // 实测：`group_home_fixes_test` 的三个回归锁立刻转红。
    // ⇒ 退场用 `duration: Duration.zero`（冻结值，本就不再变化），保持与在场同型。
    final Widget dragLayer = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: dx),
      duration: outgoing ? Duration.zero : widget.dragDuration,
      curve: Curves.easeOut,
      builder: (
        BuildContext context,
        double value,
        Widget? child,
      ) =>
          Transform.translate(
        offset: Offset(value, 0),
        child: child,
      ),
      child: widget.builder(scene),
    );
    return FadeTransition(
      opacity: outgoing ? _fade : kAlwaysCompleteAnimation,
      child: ExcludeFocus(
        excluding: outgoing,
        child: ExcludeSemantics(
          excluding: outgoing,
          child: IgnorePointer(
            ignoring: outgoing,
            child: KeyedSubtree(
              key: ValueKey<AylaGroupScene>(scene),
              child: dragLayer,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AylaGroupScene? outgoing = _outgoing;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final AylaGroupScene scene in AylaGroupScene.values)
          if (scene == widget.scene)
            _slot(scene, outgoing: false)
          else if (scene == outgoing)
            _slot(scene, outgoing: true)
          else
            // 空槽位：占位但保持 index 稳定（[Offstage] 不绘制、不参与命中）。
            const Offstage(child: SizedBox.shrink()),
      ],
    );
  }
}
