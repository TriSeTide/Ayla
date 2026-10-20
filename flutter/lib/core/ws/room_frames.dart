/// 房内域目录帧桥 —— web `ws/chat.ts` 的 `voice.channel.*` / `live.*` /
/// `boardgame.room.*` 分支 + `stores/directory.ts` 的创建/删除跟踪，Flutter 侧等价物。
///
/// ## 架构（2026-10-08 按 web 收口，与消息域同型）
/// web 是**两条彼此独立**的通路（`stores/directory.ts:205–259`）：
/// 1. **store 订阅通路**（:208–216）：帧先落域 store（`ws/chat.ts` 的对应分支），
///    `ensureDirectoryTracking` 再 diff 出目录 patch —— 负责**新增/更新/重排/成员数**。
///    Flutter 侧 = `state/directory_tracking.dart`（由 `main.dart` 启动期装配）。
/// 2. **帧直连通路**（:220–259）：`live.channel.created|deleted` /
///    `voice.channel.created|deleted` / `boardgame.room.created|deleted` ⇒ 登记
///    `createdIds`（创建提示，60s）/ 从缓存摘除条目 + 校正 `mutationRevision` /
///    `total` / `totalMemberCount`。Flutter 侧 = **本桥**。
///
/// ⇒ **本桥不再把帧「广播给页面」**（那是改造前的错误架构：页面漏订阅就没有热更新）；
/// 它只做「落域 store + 落目录缓存提示」两件事 —— 与消息域的
/// `core/ws/chat_ws.dart:620` 的 `_message.upsertMessage(convId, msg)` 同型。
///
/// ## 逐条对应（web 事实源）
/// | 帧 | web | 本桥 |
/// |---|---|---|
/// | `voice.channel.created` | `chat.ts:667–678`（**REST 详情才权威**，避免泄露受限频道） | `GET /voice/channels/<id>/` → [AylaVoiceState.upsertChannel] + [AylaDirectoryStore.noteCreated] |
/// | `voice.channel.deleted` | `chat.ts:679–683`（删除不回退排序） | [AylaVoiceState.removeChannel] + [AylaDirectoryStore.noteDeleted] |
/// | `voice.channel.member_count_changed` | `chat.ts:685–719`（帧带排序投影则直接 patch，否则拉详情对账） | [AylaVoiceState.patchChannel] + 缺失排序投影时 REST 对账 |
/// | `voice.channel.updated` | `chat.ts:720–727`（改名/可见性/转让 → REST 对账） | 同 |
/// | `live.channel.created` / `.updated` | `chat.ts:728–731 / 751–755`（`reconcileLiveChannel`） | `GET /live/channels/<id>/` → [AylaLiveState.upsertChannel] + [AylaDirectoryStore.noteCreated] |
/// | `live.channel.status.changed` | `chat.ts:732–750` | 同上；SRS 判定重拉归会话运行时 |
/// | `live.channel.deleted` | `chat.ts:745–750` | [AylaLiveState.removeChannel] + [AylaDirectoryStore.noteDeleted] |
/// | `live.viewers.changed` | `chat.ts:756–768`（**瞬态投影**：不拉 REST、不标失效、不改排序 —— 帧不属于 `live.channel.*` 命名空间） | [AylaLiveState.patchViewerCount]（目录侧由 store 订阅通路随同 patch） |
/// | `boardgame.room.created` / `.updated` | `chat.ts:845–851 / 857–865`（**REST 详情才权威**） | `GET /boardgame/rooms/<id>/` → [AylaBoardgameStore.upsertRoom] + [AylaDirectoryStore.noteCreated] |
/// | `boardgame.room.deleted` | `chat.ts:853–855`（删除不回退排序） | [AylaBoardgameStore.removeRoom] + [AylaDirectoryStore.noteDeleted] |
///
/// ## 与 web 的一处**必要差异**（登记）
/// `live.viewers.changed` / `voice.channel.member_count_changed` 在 web 里只改域 store
/// （目录缓存随后由 store 订阅通路更新）；Flutter 侧的域 store 写路径与 web 同，
/// 但由于本桥是**同步**调用而订阅通路可能尚未装配（未登录 / 测试），本桥在写完域 store
/// 后**同步补一次** [AylaDirectoryStore.updateCachedItems] 的等价效应 —— 即复用订阅
/// 通路的同一个方法（幂等：与随后的 store 通知产生的 diff 结果一致）。
///
/// ## 纪律
/// - **403/404 一律静默**（web 原话：当前用户不可见或已删除，忽略提示）—— 不把
///   「看不到」写成「不存在」；
/// - **账号守卫**：REST 往返期间账号变了就丢弃结果（web 用 `currentOwner.current` 同法）；
/// - 帧结构非法（缺 `channel_id`）⇒ 直接忽略，不猜测。
library;

import 'dart:async';

import '../../state/boardgame_store.dart';
import '../../state/chat_state.dart' show AylaChatState;
import '../../state/directory_events.dart' show AylaDirectoryEvents, AylaDirectoryKind;
import '../../state/directory_store.dart' show AylaDirectoryStore;
import '../../state/live_state.dart';
import '../../state/voice_state.dart';
import '../../widgets/live/live_channel_snapshot.dart';
import '../../widgets/live/live_hall.dart' show AylaLiveStatus;
import '../api/boardgame_api.dart';
import '../api/live_api.dart';
import '../api/voice_api.dart';
import '../models/game_room.dart' show AylaGameRoom;
import '../../state/realtime_state.dart' show AylaRealtimeState;
import 'group_presence.dart' show AylaGroupPresenceReconciler;
import '../net/dio_client.dart' show ApiException;
import 'chat_ws.dart';

/// 本桥**转正**的 12 条域外帧（第四批登记 23 条 → 本批承接口见 [AylaRoomDirectoryBridge]）。
///
/// 消费点：`room_voice_test` / `room_live_test` / `chat_ws_test`（后者断言 chat 客户端
/// 对它们仍是 no-op **但照样透传** —— 桥正是靠 `onFrame` 接帧）。
const List<String> kAylaRoomFramesTurnedOn = <String>[
  'voice.channel.created',
  'voice.channel.deleted',
  'voice.channel.member_count_changed',
  'voice.channel.updated',
  'live.channel.created',
  'live.channel.status.changed',
  'live.channel.deleted',
  'live.channel.updated',
  'live.viewers.changed',
  'boardgame.room.created',
  'boardgame.room.deleted',
  'boardgame.room.updated',
];

/// 目录帧桥（挂在 chat WS 的 `onFrame` 上；单例由 provider 持有）。
class AylaRoomDirectoryBridge {
  AylaRoomDirectoryBridge({
    required AylaVoiceState voiceState,
    required AylaLiveState liveState,
    required AylaBoardgameStore boardgameStore,
    required String? Function() currentUserId,
    AylaDirectoryEvents? directory,
    AylaDirectoryStore? directoryStore,
    AylaChatState? chatState,
    AylaRealtimeState? realtime,
    AylaGroupPresenceReconciler? groupPresence,
    Future<AylaVoiceChannelSnapshot> Function(String channelId)?
        voiceChannelLoader,
  })  : _voice = voiceState,
        _live = liveState,
        _directory = directory,
        _directoryStore = directoryStore,
        _boardgame = boardgameStore,
        _currentUserId = currentUserId,
        _chat = chatState,
        _realtime = realtime,
        _presence = groupPresence,
        _voiceChannelLoader = voiceChannelLoader;

  final AylaVoiceState _voice;
  final AylaLiveState _live;

  /// 语音房详情取数（`GET /voice/channels/<id>/`）—— 生产恒 null ⇒ 走真实 API；
  /// **测试注入点**（回归锁要验证「REST 对账真的被调用」而不打网络）。
  final Future<AylaVoiceChannelSnapshot> Function(String channelId)?
      _voiceChannelLoader;

  /// 会话全局状态（web 的 `useChatStore`）—— **只用于「新内容 → 群往前排」的 bump**
  /// （web `ws/chat.ts:115–118` 的 `bumpGroups`；三处调用 `:674 / :715–717 / :737–741`）。
  ///
  /// ⚠️ 可空：历史测试与「只关心域 store」的调用点不注入 ⇒ 退化为不 bump
  /// （web 侧那三条 `bumpGroups` 在 chat store 未就绪时同样是空转）。
  final AylaChatState? _chat;

  /// 连接状态表（web `useRealtimeStore`）—— 群 presence 对账失败时写 failed 档
  /// （web `chat.ts:373`）；可空 = 不报连接状态（旧测试/纯 store 调用点）。
  final AylaRealtimeState? _realtime;

  /// 群 presence 对账器（web `chat.ts:335–378` 的 `queueGroupPresence` /
  /// `refreshGroupPresence`；实现见 `core/ws/group_presence.dart`）。
  ///
  /// 注入优先（测试可传假后端）；未注入且注入了 [AylaChatState] ⇒ 懒建一个默认实现
  /// （与生产同参：chatState + realtime + 当前用户 + 退订回调）。
  /// **两者都没有** ⇒ 不接（历史测试的「只关心域 store」档）。
  AylaGroupPresenceReconciler? _presence;

  /// 目录 store（web `stores/directory.ts` 的模块级 `useDirectoryStore`）——
  /// `*.created` / `*.deleted` 帧的 `createdIds` / 删除摘除落点。
  ///
  /// ⚠️ 可空只为**测试与旧调用点**兼容：生产由 `room_providers.dart` 注入全局单例。
  /// 为 null 时本桥退化为「只落域 store」（与 web 在 `ensureDirectoryTracking` 尚未
  /// 装配时的行为一致 —— 帧照样不丢，只是没有目录缓存可 patch）。
  final AylaDirectoryStore? _directoryStore;

  /// 旧的事件总线（**已退役**）：只为历史调用点/测试保留，生产恒为 null。
  ///
  /// 退役理由见文件头「架构」段：web 里帧不广播给页面，页面只读目录缓存；
  /// 总线的「广播 + 页面各自 patch」正是漏订阅页面没有热更新的根因。
  @Deprecated('目录热更新已改为「帧 → store」；请用 directoryStore，不要再订阅事件总线')
  final AylaDirectoryEvents? _directory;

  /// 桌游房全局表（web `useBoardgameStore`）—— `boardgame.room.*` 三条帧的落地目标。
  final AylaBoardgameStore _boardgame;
  final String? Function() _currentUserId;

  /// `*.created` 帧的**目录创建提示**（web `stores/directory.ts:228–234`）。
  void _noteCreated(AylaDirectoryKind kind, String id) {
    final AylaDirectoryStore? store = _directoryStore;
    if (store != null) {
      store.noteCreated(kind, id);
      return;
    }
    // 未注入 store（旧测试/未装配）：仍走总线，保持既有可观测性。
    _emitInvalidatedCompat(kind);
  }

  /// `*.deleted` 帧的**目录缓存摘除**（web `stores/directory.ts:237–258`）。
  void _noteDeleted(AylaDirectoryKind kind, String id) {
    final AylaDirectoryStore? store = _directoryStore;
    if (store != null) {
      store.noteDeleted(kind, id);
      return;
    }
    _emitDeletedCompat(kind, id);
  }

  /// 兼容档（无 store 注入时）—— 保留事件总线的最少用途，不静默丢语义。
  void _emitInvalidatedCompat(AylaDirectoryKind kind) {
    // ignore: deprecated_member_use_from_same_package
    _directory?.emitInvalidated(kind);
  }

  void _emitDeletedCompat(AylaDirectoryKind kind, String id) {
    // ignore: deprecated_member_use_from_same_package
    _directory?.emitDeleted(kind, id);
  }

  void Function()? _off;

  /// 挂上的 chat WS（群 presence 对账要调它的 [AylaChatWsClient.unsubscribe]）。
  AylaChatWsClient? _chatWs;

  /// 挂到 chat WS 上（幂等）。
  void attach(AylaChatWsClient chat) {
    _off?.call();
    _chatWs = chat;
    _off = chat.onFrame(handleFrame);
  }

  /// 解绑（登出/测试收尾）。
  ///
  /// 同时 [AylaGroupPresenceReconciler.reset]：清掉合并窗口与在飞标记
  /// （web `chat.ts:968–976` 的 `disconnect()` 同口径），避免登出后仍有
  /// 定时器在跑、又把结果写进已清空的会话列表。
  void detach() {
    _off?.call();
    _off = null;
    _chatWs = null;
    _presence?.reset();
  }

  /// 群 presence 对账器（懒建；见 [AylaGroupPresenceReconciler]）。
  ///
  /// 注入优先；否则**只有**在注入了 [AylaChatState] 时才建默认实现
  /// （否则没有任何会话可对账，建出来也只是空转）。
  AylaGroupPresenceReconciler? get _groupPresence {
    AylaGroupPresenceReconciler? existing = _presence;
    if (existing != null) return existing;
    final AylaChatState? chat = _chat;
    if (chat == null) return null;
    existing = AylaGroupPresenceReconciler(
      chatState: chat,
      realtime: _realtime,
      currentUserId: _currentUserId,
      unsubscribe: (String convId) => _chatWs?.unsubscribe(convId),
    );
    _presence = existing;
    return existing;
  }

  /// 帧到达后的群 presence 失效信号（web `chat.ts:946–948`）。
  ///
  /// web 判据逐字：`voice.channel.` / `live.channel.` / `boardgame.room.`
  /// 三个**命名空间前缀**（因此 `live.viewers.changed` 不触发 —— 它是瞬态投影，
  /// 不属于 `live.channel.*`）；合并与对账交给对账器（250ms 窗口 + 分批 100）。
  void _queueGroupPresenceFor(String type) {
    if (type.startsWith('voice.channel.') ||
        type.startsWith('live.channel.') ||
        type.startsWith('boardgame.room.')) {
      _groupPresence?.queueGroupPresence();
    }
  }

  /// 处理一帧（测试可直接投喂）。
  ///
  /// 每条分支的两件事（与 web 逐条对应）：
  /// ① **落域 store**（`chat.ts` 的对应分支；帧只是提示、REST 详情才权威）；
  /// ② **落目录缓存提示**（`stores/directory.ts:220–259` 的 `createdIds` / 删除摘除）。
  /// 两条都做完 ⇒ 目录缓存由 store 订阅通路 patch、页面只读缓存 ⇒ 天然热更新。
  void handleFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    _handleFrameBody(frame, rawType);
    // web `chat.ts:946–948`：三条房间帧族**之后**登记群 presence 失效信号
    // —— 位置在 switch 之后、`handlers` 广播之前，且**不因分支内提前 return 而跳过**
    // （web 的 switch 分支里没有 return，故这里包一层保证同语义）。
    _queueGroupPresenceFor(rawType);
  }

  /// [handleFrame] 的分支主体（原实现，逐条不动）。
  void _handleFrameBody(Map<String, dynamic> frame, String rawType) {
    switch (rawType) {
      case 'voice.channel.created':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        // web `stores/directory.ts:228–234`：登记创建提示（60s），
        // 供随后的 `updateCachedItems` 判定「这条新增属于哪些查询」。
        _noteCreated(AylaDirectoryKind.voice, id);
        // web `chat.ts:674`：新语音房创建 ⇒ 可见群卡片往前排（详情确认后 bump）。
        unawaited(_reconcileVoiceChannel(id, bumpActivity: true));
      case 'voice.channel.updated':
        // 改名/可见性/转让 ⇒ 以权限 REST 详情为权威对账（web `chat.ts:720–727`）。
        // ⚠️ 不登记创建提示：`updated` 不是新增（web 的帧跟踪只认 `.created`/`.deleted`）。
        unawaited(_reconcileVoiceChannel(_channelId(frame)));
      case 'voice.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        // web `chat.ts:679–683`：`removeChannel` —— 删除不回退排序。
        _voice.removeChannel(id);
        // web `stores/directory.ts:237–258`：从全部同 kind 的 record 摘除 + 校正统计。
        _noteDeleted(AylaDirectoryKind.voice, id);
      case 'voice.channel.member_count_changed':
        unawaited(_applyVoiceMemberCount(frame));
      case 'live.channel.created':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _noteCreated(AylaDirectoryKind.live, id);
        unawaited(_reconcileLiveChannel(id));
      case 'live.channel.updated':
        // web `chat.ts:751–755`：资料编辑 ⇒ 只 reconcile，**不 bump**。
        unawaited(_reconcileLiveChannel(_channelId(frame)));
      case 'live.channel.status.changed':
        // web `chat.ts:732–744`：状态变化 ⇒ reconcile；**开播**时（帧 status==live）
        // 详情确认后再 bump 可见群（下播/结束不回退）。
        unawaited(
          _reconcileLiveChannel(
            _channelId(frame),
            bumpOnLive: _liveFrameStatusIsLive(frame),
          ),
        );
      case 'live.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _live.removeChannel(id);
        _noteDeleted(AylaDirectoryKind.live, id);
      case 'live.viewers.changed':
        _applyViewerCount(frame);
      case 'boardgame.room.created':
        final String roomId = _roomId(frame);
        if (roomId.isEmpty) return;
        // web `stores/directory.ts:229` 读的是 `frame.room.id` —— 是否合法数字由 ① 判；
        // ② 的登记只看 id 是否为空（保持 web 的宽松口径，不猜语义）。
        _noteCreated(AylaDirectoryKind.game, roomId);
        unawaited(_reconcileGameRoom(roomId));
      case 'boardgame.room.updated':
        // 桌游房变更（有人加入/离开/踢出/转让/编辑）⇒ 拉完整房间对账（web `chat.ts:857–865`）。
        final String roomId = _roomId(frame);
        if (roomId.isEmpty) return;
        unawaited(_reconcileGameRoom(roomId));
      case 'boardgame.room.deleted':
        final String id = _roomId(frame);
        if (id.isEmpty) return;
        // web `chat.ts:853–855`：`removeRoom(Number(frame.room_id))` ——
        // 删除不回退排序（全局表与目录缓存两处都摘）。
        final int? roomId = int.tryParse(id);
        if (roomId == null) return;
        _boardgame.removeRoom(roomId);
        _noteDeleted(AylaDirectoryKind.game, id);
      default:
        return;
    }
  }

  /// 「新内容 → 可见群往前排」的 bump（web `ws/chat.ts:115–118` 的 `bumpGroups`）。
  ///
  /// `visibleGroupIds`（web `:102–112`）= **归属群 ∪ 白名单群**；chatState 未注入时不动作。
  void _bumpGroups({
    String? group,
    Iterable<String> allowedGroupIds = const <String>[],
  }) {
    final AylaChatState? chat = _chat;
    if (chat == null) return;
    aylaBumpGroups(
      chat,
      aylaVisibleGroupIds(group: group, allowedGroupIds: allowedGroupIds),
    );
  }

  /// `voice.channel.created/updated`：**帧只是提示，REST 详情才是权威**
  /// （权限过滤由后端做，避免把受限频道插进列表；web `chat.ts:667–678` 原话）。
  ///
  /// ⚠️ `bumpGroups` **只在 `.created` 分支**（web `:674` 在 `voice.channel.created` 里，
  /// `.updated` 分支 `:720–727` 没有）⇒ 由调用方用 [bumpActivity] 显式控制。
  Future<void> _reconcileVoiceChannel(
    String channelId, {
    bool bumpActivity = false,
  }) async {
    if (channelId.isEmpty) return;
    final String? actor = _currentUserId();
    try {
      // 注入优先（测试验证「对账确实被调用」）；生产恒 null ⇒ 真实 REST。
      final Future<AylaVoiceChannelSnapshot> Function(String)? loader =
          _voiceChannelLoader;
      final AylaVoiceChannelSnapshot channel = loader != null
          ? await loader(channelId)
          : await AylaVoiceApi.getVoiceChannel(channelId);
      if (actor != _currentUserId()) return;
      // ① 落域 store —— 目录缓存由 store 订阅通路（`directory_tracking.dart`）patch，
      // 这正是 web 的机制（`chat.ts:672` → `stores/directory.ts:211–213`）。
      _voice.upsertChannel(channel);
      // ② web `chat.ts:674`：新语音房创建 ⇒ 其可见群卡片往前排（单调）。
      //    只在「REST 详情确认可见」之后 bump —— 权限过滤前的帧可能指向不可见频道。
      if (bumpActivity) {
        _bumpGroups(
          group: channel.group,
          allowedGroupIds: channel.allowedGroupIds,
        );
      }
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或频道已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// `voice.channel.member_count_changed`（web `chat.ts:685–719`）。
  ///
  /// 排序投影（`last_occupied_at` / `last_vacant_at`）帧携带时直接 patch；
  /// **缺失或为 null 时拉一次 REST 详情对账**（旧版后端不带这两个字段 ⇒ 由 serializer
  /// 返回的持久字段恢复「有人区/无人区」排序，多端一致、不依赖帧内容）。
  Future<void> _applyVoiceMemberCount(Map<String, dynamic> frame) async {
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final String channelId = data['channel_id']?.toString() ?? '';
    if (channelId.isEmpty) return;
    final int? count = (data['member_count'] as num?)?.toInt();
    if (count == null) return;
    // web `chat.ts:691–694`：先取**帧到达前**的本地条目与人数，用于「人数增加才 bump」判据。
    final AylaVoiceChannelSnapshot? prev = _voice.channelOf(channelId);
    final int prevCount = prev?.memberCount ?? 0;
    final Object? occupied = data['last_occupied_at'];
    final Object? vacant = data['last_vacant_at'];
    final bool frameHasSort = occupied != null || vacant != null;
    // ⚠️ **必须区分「patch 生效」与「本就没有这条」**（2026-10-20 全量普查修复）。
    //
    // `patchChannel` 的语义是「只改已加载的条目」——`prev == null` 时直接 return
    // （`voice_state.dart:180–181`）。而 `frameHasSort == true` 时旧实现**不做 REST 对账**
    // ⇒ 该频道若从未被目录页灌进域 store（用户没打开过它的列表），
    // **整帧被静默丢弃**：人数不更新、目录缓存无 diff、「有人」选项卡永远看不到它。
    //
    // 这正是用户实报「进了一个语音房，语音页面的『有人』选项卡依然没有实时刷出这个房间」
    // 的根因。**web 侧存在同样的缺陷**（`ws/chat.ts:685–719` 的 `patchChannel` 同样是
    // 「只在已存在时改」+ `frameHasSort` 时不对账），按要求一并在此补上（比 web 更正确）。
    //
    // 判据：帧到达前本地**没有**这个频道 ⇒ 必须 REST 对账把权威描述符拉进来
    // （`upsertChannel` 走的是「不存在则追加」，与 patch 的「只改已有」互补）。
    final bool needsReconcile = prev == null || !frameHasSort;
    _voice.patchChannel(
      channelId,
      memberCount: count,
      lastOccupiedAt: occupied?.toString(),
      lastVacantAt: vacant?.toString(),
    );
    if (needsReconcile) {
      unawaited(_reconcileVoiceChannel(channelId));
    }
    // web `chat.ts:714–717`：**有人进入（人数增加）⇒ 群卡片往前排**；
    // 离开/被踢（人数减少）**不回退**。判据用「帧里的新人数 > 帧前的本地人数」。
    if (count > prevCount && prev != null) {
      _bumpGroups(
        group: prev.group,
        allowedGroupIds: prev.allowedGroupIds,
      );
    }
  }

  /// `live.channel.created/status.changed/updated`：拉完整详情对账
  /// （web `reconcileLiveChannel`；列表卡/侧栏实时刷新）。
  ///
  /// [bumpOnLive]：详情 `status == live` 时才 bump 可见群 —— 对应 web：
  /// - `live.channel.status.changed` 分支 `chat.ts:732–744`：帧 `status == "live"` 才继续拉详情，
  ///   且**详情确认** `channel.status == "live"` 后 `bumpGroups`（下播/结束不回退）；
  /// - `live.channel.created` / `.updated` 分支（`chat.ts:728–731 / :751–755`）**不做 bump**。
  Future<void> _reconcileLiveChannel(
    String channelId, {
    bool bumpOnLive = false,
  }) async {
    if (channelId.isEmpty) return;
    final String? actor = _currentUserId();
    try {
      final AylaLiveChannelSnapshot channel =
          await AylaLiveApi.getLiveChannel(channelId);
      if (actor != _currentUserId()) return;
      // ① 落域 store（目录缓存由 store 订阅通路 patch；web `chat.ts:730` + :209）。
      _live.upsertChannel(channel);
      // ② web `chat.ts:737–741`：开播 ⇒ 拉详情确认可见群后 bump（单调往前排）；
      //    下播/结束**不回退**（非 live 时什么都不做）。
      if (bumpOnLive && channel.status == AylaLiveStatus.live) {
        _bumpGroups(
          group: channel.group,
          allowedGroupIds: channel.allowedGroupIds,
        );
      }
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或已删除 —— 静默
    } catch (_) {
      // 同上
    }
  }

  /// `live.viewers.changed`：**只 patch 已加载条目**的人数（不拉 REST、不标失效、
  /// 不改排序 —— 帧不含元数据、也不属于 `live.channel.*` 命名空间）。
  void _applyViewerCount(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final String channelId = data['channel_id']?.toString() ?? '';
    final int? count = (data['viewer_count'] as num?)?.toInt();
    if (channelId.isEmpty || count == null) return;
    _live.patchViewerCount(channelId, count);
  }

  /// `boardgame.room.created/updated`：拉完整房间对账（web `chat.ts:848–850 / 861–863`）。
  ///
  /// ⚠️ 与调用点 ② 的 `emitInvalidated` **互不替代**：本方法只负责「全局房间表」，
  /// 目录缓存的失效由 web `stores/directory.ts:220–236` 的帧跟踪承担（Flutter 侧
  /// 仍是既有的目录事件总线）。两条效应都保留 —— 房内页批次建立目录事件时还没有全局表，
  /// 本轮**补上**全局表，属于「加一条」而不是「换一条」。
  ///
  /// 静默档（web `.catch(() => {})` 原话）：当前用户不可见或房间已删除。
  Future<void> _reconcileGameRoom(String roomId) async {
    if (roomId.isEmpty) return;
    final int? id = int.tryParse(roomId);
    if (id == null) return;
    final String? actor = _currentUserId();
    try {
      final AylaGameRoom room = await AylaBoardgameApi.getGameRoom(id);
      if (actor != _currentUserId()) return;
      _boardgame.upsertRoom(room);
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或房间已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// `live.channel.status.changed` 帧里的 `data.status` 是否为 `live`
  /// —— web `chat.ts:734` 的 `if (frame.data.status === "live")`。
  ///
  /// 缺字段/非字符串 ⇒ false（不猜语义；web 对 `undefined === "live"` 同样为假）。
  static bool _liveFrameStatusIsLive(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return false;
    return Map<String, dynamic>.from(raw)['status'] == 'live';
  }

  /// `data.channel_id`（voice / live 两类帧同一位置；`api/types.ts:663–727`）。
  static String _channelId(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return '';
    return Map<String, dynamic>.from(raw)['channel_id']?.toString() ?? '';
  }

  /// 桌游帧的 room id —— **三种真实形状**都要认（web `chat.ts:845/854/857` 的取值处）：
  ///
  /// 1. `boardgame.room.created/updated`：**顶层** `{type, room_id, room:{id,...}}`
  ///    （后端 `boardgame/services.py:113–127` 的 `_boardgame_event`）⇒ 读 `frame.room.id`；
  /// 2. `boardgame.room.deleted`：**顶层只有 `room_id`**（同源 `_boardgame_event(room_id,
  ///    "boardgame.room.deleted")` 不传 room）⇒ web 读 `frame.room_id`（`chat.ts:854`）；
  /// 3. 兼容 `{type, data:{room_id}}` 包装（历史/测试喂过的形状）。
  ///
  /// ⚠️ **2026-10-20 修复**：原实现只有 1、3 两档，**漏了 2** ⇒ 真实的删除帧
  /// （顶层 `room_id`、无 `room`、无 `data`）取到空串、在调用点被 `if (id.isEmpty) return`
  /// 静默丢弃（`room_frames.dart:312–313`）⇒ 桌游房删除后列表不热更新。
  /// 既有测试 `room_live_test.dart:267–270` 喂的是 `room:{id}` 假帧，掩盖了该缺陷。
  static String _roomId(Map<String, dynamic> frame) {
    final Object? raw = frame['room'];
    if (raw is Map) {
      final String fromRoom =
          Map<String, dynamic>.from(raw)['id']?.toString() ?? '';
      if (fromRoom.isNotEmpty) return fromRoom;
    }
    // 顶层 room_id（删除帧的唯一字段；web `chat.ts:854` 读的正是它）。
    final String top = frame['room_id']?.toString() ?? '';
    if (top.isNotEmpty) return top;
    final Object? data = frame['data'];
    if (data is Map) {
      return Map<String, dynamic>.from(data)['room_id']?.toString() ?? '';
    }
    return '';
  }
}