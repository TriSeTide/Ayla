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
///   ⇒ 只有**淡出**（旧场景 300ms 淡出、新场景直接显示），由 [_AylaSceneFade] 表达。
///
/// ## 与 web 的机制差异（登记）
/// 1. **路由守卫卡片不实现**（用户裁决，见 13 号 B5）：web 在「非成员 + summary 403」时
///    渲染 `GroupApplyGate` 申请卡片（tsx 394–403）；Flutter 侧该组件按裁决未建 ⇒
///    直达未加入群时页面按「加载失败 / 空态」呈现，不做守卫卡。
/// 2. **场景切换重叠**：web 用 `AnimatePresence mode="sync"` 让新旧场景同帧重叠；
///    Flutter 用 [Stack] + 单条淡出曲线表达同一效果（新场景无淡入 —— 与 web 的
///    `enter/center` 变体一致）。
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
import '../widgets/group/group_create_dialog.dart' show AylaGroupCreateDialog;
import '../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../widgets/shell/channel_sidebar.dart';
import '../widgets/shell/group_top_tabs.dart';
import '../widgets/shell/server_rail.dart';
import 'group_chat_page.dart';
import 'group_games_page.dart';
import 'group_info_page.dart';
import 'group_live_page.dart';
import 'group_posts_page.dart';
import 'group_support.dart';
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
  double _pullDy = 0;
  double _pullOpacity = 1;
  double _dragDx = 0;
  double _dragDy = 0;

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
  void _pullToHome() {
    setState(() {
      _pullDy = 0;
      _pullOpacity = 1;
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
        if (_showGroupCreate)
          Positioned.fill(
            child: AylaGroupCreateDialog(
              onClose: () => setState(() => _showGroupCreate = false),
            ),
          ),
        if (_directory?.error != null && (_directory?.raw.isEmpty ?? true))
          const SizedBox.shrink(),
      ],
    );
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
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (DragUpdateDetails details) =>
                _onPullUpdate(details, reduced),
            onVerticalDragEnd: (DragEndDetails details) =>
                _onPullEnd(details, reduced),
            onVerticalDragCancel: _resetPull,
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (reduced || _leaving) return;
              setState(() {
                _dragDx += details.delta.dx;
                _dragDy += details.delta.dy;
              });
            },
            onHorizontalDragEnd: (DragEndDetails details) =>
                _onSceneDragEnd(details, contentScene, reduced),
            onHorizontalDragCancel: () => setState(() {
              _dragDx = 0;
              _dragDy = 0;
            }),
            child: ClipRect(
              child: Transform.translate(
                offset: Offset(reduced ? 0 : _dragDx * 0.8, _pullDy),
                child: Transform.scale(
                  scale: 1 - 0.02 * progress,
                  child: Opacity(
                    opacity: _pullOpacity,
                    child: _AylaSceneFade(
                      scene: contentScene,
                      builder: _renderScene,
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

  /// 松手：过阈值且向下 ⇒ 回主页；否则 200ms `--ease-out` 回弹（web tsx 153–169）。
  void _onPullEnd(DragEndDetails details, bool reduced) {
    if (reduced || _leaving) return;
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity > 0 && _pullDy >= kAylaGroupPullExitThreshold) {
      _pullToHome();
      return;
    }
    _resetPull();
  }

  void _resetPull() {
    if (_pullDy == 0 && _pullOpacity == 1) return;
    setState(() {
      _pullDy = 0;
      _pullOpacity = 1;
    });
  }

  /// 横滑切场景（web tsx 355–372）：松手判定走 [aylaResolveSwipeCommit]。
  void _onSceneDragEnd(
    DragEndDetails details,
    AylaGroupScene contentScene,
    bool reduced,
  ) {
    final double width = MediaQuery.sizeOf(context).width;
    final double net = _dragDx;
    final double cross = _dragDy;
    setState(() {
      _dragDx = 0;
      _dragDy = 0;
    });
    if (reduced || _leaving) return;
    final int commit = aylaResolveSwipeCommit(
      net: net,
      cross: cross,
      velocity: details.velocity.pixelsPerSecond.dx,
      size: width,
    );
    if (commit == 0) return;
    final int base = aylaGroupSceneOrderIndex(contentScene);
    final int next = (base + commit + kAylaGroupSceneOrder.length) %
        kAylaGroupSceneOrder.length;
    _goScene(kAylaGroupSceneOrder[next]);
  }
}

/// 窄屏场景切换的**淡出层** —— web `GroupPage.tsx:499–539` 的 `GroupSceneSurface`
/// + `AnimatePresence mode="sync"` 的等价物。
///
/// web 的 variants：`enter/center` 都是 `{x:0, opacity:1}`、`exit` 是 `{x:0, opacity:0}`
/// ⇒ **新场景无淡入、旧场景 300ms 淡出**（横向位移由 drag 层单独拥有，切场景时归零）。
/// 本件用「保留旧场景一帧 + 淡出」表达：`Stack` 里按 `ValueKey(scene)` 匹配 Element，
/// 旧场景的 State（会话历史/滚动位置）在淡出期间**继续存活**，动画结束才卸载
/// —— 与 `AnimatePresence` 保管退出实例同一语义。
class _AylaSceneFade extends StatefulWidget {
  const _AylaSceneFade({required this.scene, required this.builder});

  final AylaGroupScene scene;
  final Widget Function(AylaGroupScene scene) builder;

  @override
  State<_AylaSceneFade> createState() => _AylaSceneFadeState();
}

class _AylaSceneFadeState extends State<_AylaSceneFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AylaDurations.auroraqua,
    value: 1,
  );

  /// 正在退场的旧场景（null = 无）。
  AylaGroupScene? _outgoing;

  @override
  void didUpdateWidget(covariant _AylaSceneFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene == widget.scene) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _outgoing = null);
      return;
    }
    setState(() => _outgoing = oldWidget.scene);
    _fade.value = 1;
    _fade.reverse().whenComplete(() {
      if (mounted) setState(() => _outgoing = null);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaGroupScene? outgoing = _outgoing;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        KeyedSubtree(
          key: ValueKey<AylaGroupScene>(widget.scene),
          child: widget.builder(widget.scene),
        ),
        if (outgoing != null)
          FadeTransition(
            opacity: _fade,
            child: ExcludeFocus(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: KeyedSubtree(
                    key: ValueKey<AylaGroupScene>(outgoing),
                    child: widget.builder(outgoing),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
