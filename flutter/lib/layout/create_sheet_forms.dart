/// CreateSheet 的场景表单接线 —— web `layout/CreateFab.tsx`（117 行）**五个 handler 分支**。
///
/// ## 为什么是独立件
/// web 的 `CreateFab` 是「按钮 + 各场景浮层 + 各场景状态 + 各场景跳转」一体
/// （`CreateFab.tsx:24–114`）；Flutter 侧的按钮（`AylaCreateFab`）与浮层容器
/// （`AylaCreateSheet`）已各自独立，四个表单件又都按「展示型 + 注入」交付
/// （组件只负责校验 / 防重入 / busy / 错误展示，请求与跳转归调用方）⇒ 本件补
/// **各分支的数据、状态与跳转**；分支分派见 [aylaCreateFormFor]，挂载点仍是
/// `layout/app_shell.dart` 的 `_createSheet`。
///
/// ## 五分支对应（web `CreateFab.tsx:75–114`）
/// | handler | web | 本件 |
/// |---|---|---|
/// | `group` | `tsx:75–77`（**不套 CreateSheet**：组件自带弹层） | [AylaCreateGroupForm] |
/// | `voice` | `tsx:78–82`（`CreateSheet title={action.label}` + `VoiceChannelCreate group onCreated`） | [AylaCreateVoiceForm] |
/// | `live` | `tsx:83–92`（标题是固定串「开始直播」） | [AylaCreateLiveForm] |
/// | `post` | `tsx:93–103`（`PostEditor group onCreated={post => …}`） | [AylaCreatePostForm] |
/// | `game` | `tsx:104–114`（`GameRoomCreate group onCreated={() => …}`） | [AylaCreateGameForm] |
///
/// ## 新增四分支的逐条对应
/// | 本件 | web |
/// |---|---|
/// | [AylaCreateGroupForm] 的成员搜索（游标分页；300ms 防抖在组件内） | `GroupCreateDialog.tsx:29–37`（`useSocialPage("users", {q})`） |
/// | 建群 / 发起私聊 | `GroupCreateDialog.tsx:46–64 / 66–80`（`chatApi.createGroupConversation` / `openPrivateConversation`） |
/// | 建群 → `/group/:id`、私聊 → `/chat/:id`（先关浮层） | 同上 `tsx:57–58 / 73–74` |
/// | [AylaCreateVoiceForm] 成功后只关浮层 | `CreateFab.tsx:80`（`onCreated={() => setOpen(false)}`） |
/// | 新频道写进 voice 状态 | `VoiceChannelCreate.tsx:44–45`（`store.setChannels([{...ch, mine:false}, …])`） |
/// | [AylaCreatePostForm] 成功后关浮层 + 跳转 | `CreateFab.tsx:97–100`（有 groupId → 群帖子页；否则 `/posts/:post.id`） |
/// | [AylaCreateGameForm] 成功后关浮层 + 跳转 | `CreateFab.tsx:107–111`（有 groupId → 群桌游页；否则 `/games`） |
/// | 三件共用的可见性群列表 | `VisibilitySelector.tsx:34`（`useSocialPage("conversations", {type:"group"})`） |
///
/// ## live 分支逐条对应
/// | 本件 | web |
/// |---|---|
/// | [AylaCreateLiveForm.onClose] 在导航前调用 | `CreateFab.tsx:36–39 handleLiveStarted`（`setOpen(false)` → `navigate`） |
/// | [AylaCreateLiveForm] 的建播（固定标题「新直播间」+ `group`） | `CreateFab.tsx:41–54 handleCreateNewLive` |
/// | 创建失败文案（不导航、浮层保留） | `CreateFab.tsx:49–51`（`e.message`，否则「创建直播间失败」） |
/// | 本人直播间目录（`?owner=<me>`，limit 20，游标分页） | `hooks/useOwnedLiveDirectory.ts:14–20` |
/// | 目录热更新（`live.channel.*` → 标记失效 + 删除条目） | 同上 `33–40` |
/// | 选择器外观（intro / 三态 / 列表 / 新建键） | `widgets/live/live_rail.dart` 的 `AylaLiveStartSheet`（`LiveStartSheet.tsx` 86 行） |
///
/// ## 登记（有意偏离，均有依据）
/// - web 的 `usePagedMediaList.fetchPage` 带 revision 守卫（列表被并发更新时旧游标续读
///   直接抛「直播列表已更新，请刷新后继续」）；`AylaPagedList` 无该钩子 ⇒ 本件只保留
///   `invalidated` 置位 + 刷新后清位（页脚据此自动刷新恢复，与 web `DirectoryLoadMore` 同）。
/// - web `useLiveStore.channels` 的合并重排（hook `25–31`）由 `live.channel.*` 帧触发的
///   重取首页表达（Flutter 侧目录投影即 `AylaDirectoryLiveEntry`，本件不另持 store 表）。
/// - `live.viewers.changed`（人数）**不监听**：web hook `34` 只认 `live.channel.` 前缀
///   （人数是瞬态投影，属目录页热更新，不属于本入口）。
///
/// ## 公开面
/// `AylaCreateLiveForm`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/boardgame_api.dart' show AylaBoardgameApi;
import '../core/api/chat_api.dart' show AylaChatApi;
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/live_api.dart' show AylaDirectoryLiveEntry, AylaLiveApi;
import '../core/api/posts_api.dart' show AylaPostsApi;
import '../core/api/users_api.dart' show AylaUsersApi;
import '../core/api/voice_api.dart' show AylaVoiceApi, AylaVoiceChannelSnapshot;
import '../core/models/conversation.dart' show AylaConversationSummary;
import '../core/models/post.dart' show AylaPost, AylaPostDraft;
import '../core/models/subgroup.dart' show AylaSubGroup;
import '../core/models/user_public.dart' show AylaUserPublic;
import '../core/models/visibility.dart' show AylaPostVisibility;
import '../core/net/dio_client.dart' show ApiException;
import '../pages/hub_support.dart' show aylaHubSortLive;
import '../router/shell_config.dart' show AylaFabAction;
import '../state/auth_state.dart';
import '../state/directory_events.dart';
import '../state/paged_list.dart';
import '../state/room_providers.dart'
    show directoryEventsProvider, voiceStateProvider; // 事件总线已退役（见 state/directory_events.dart 文件头）
import '../theme/app_theme.dart' show AylaTextStyles;
import '../theme/tokens.dart' show AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/game/game_room_create.dart'
    show
        AylaGameRoomCreate,
        AylaGameRoomCreateException,
        AylaGameRoomCreateRequest;
import '../widgets/group/group_create_dialog.dart'
    show AylaGroupCreateDialog, AylaGroupCreateException;
import '../widgets/live/live_channel_snapshot.dart'
    show AylaLiveChannelSnapshot;
import '../widgets/live/live_hall.dart' show AylaLiveCardData;
import '../widgets/live/live_rail.dart' show AylaLiveStartSheet;
import '../widgets/posts/post_editor.dart' show AylaPostEditor;
import '../widgets/shell/create_sheet.dart' show AylaCreateSheet;
import '../widgets/voice/voice_channel_create.dart'
    show
        AylaVoiceChannelCreate,
        AylaVoiceChannelCreateException,
        AylaVoiceChannelCreateRequest;

/// 取一页「本人直播间」目录（web `useOwnedLiveDirectory` 的 `fetchPage`）。
///
/// `cursor` = null 取首页；`owner` = 当前用户 id（web 在**分页之前**由后端过滤）。
typedef AylaOwnedLivePageRequest =
    Future<AylaDirectoryPage<AylaDirectoryLiveEntry>> Function(
      String? cursor,
      String? owner,
    );

/// 建子群（web `chatApi.createSubgroup`，`ChannelSidebar.tsx:572`）。
Future<AylaSubGroup> aylaCreateSubgroup(String convId, String name) =>
    AylaChatApi.createSubgroup(convId, name);

/// 改子群（web `chatApi.updateSubgroup`，`ChannelSidebar.tsx:577`）。
Future<AylaSubGroup> aylaUpdateSubgroup(
  String convId,
  String subgroupId, {
  String? name,
  bool? muted,
}) => AylaChatApi.updateSubgroup(convId, subgroupId, name: name, muted: muted);

/// 删子群（web `chatApi.deleteSubgroup`，`ChannelSidebar.tsx:222`）。
Future<void> aylaDeleteSubgroup(String convId, String subgroupId) =>
    AylaChatApi.deleteSubgroup(convId, subgroupId);

/// 建直播间（web `liveApi.createLiveChannel(title, group)`）。
typedef AylaCreateLiveChannelFn =
    Future<AylaLiveChannelSnapshot> Function(String title, {String? group});

Future<AylaDirectoryPage<AylaDirectoryLiveEntry>> _defaultOwnedLivePage(
  String? cursor,
  String? owner,
) => AylaLiveApi.listLiveChannelsPage(cursor: cursor, owner: owner);

Future<AylaLiveChannelSnapshot> _defaultCreateLiveChannel(
  String title, {
  String? group,
}) => AylaLiveApi.createLiveChannel(title, group: group);

/// 「开始直播」浮层内容（web `CreateFab.tsx:83–92` 的 live 分支）。
///
/// 无自有视觉：外观全部来自 [AylaLiveStartSheet]（`LiveStartSheet.tsx`）；
/// 本件只持有**数据与状态**（目录 / 创建中 / 创建失败）。
class AylaCreateLiveForm extends ConsumerStatefulWidget {
  const AylaCreateLiveForm({
    super.key,
    required this.onClose,
    this.groupId,
    this.listPage = _defaultOwnedLivePage,
    this.createChannel = _defaultCreateLiveChannel,
  });

  /// 关浮层（web `setOpen(false)`）。**导航前**调用（`CreateFab.tsx:37 / 47`）。
  final VoidCallback onClose;

  /// 群归属（web `action.groupId`；一级 tab `/live` 恒 null）。
  final String? groupId;

  /// 本人直播间目录分页。默认走真实 api；测试可注入替身。
  final AylaOwnedLivePageRequest listPage;

  /// 建直播间。默认走真实 api；测试可注入替身。
  final AylaCreateLiveChannelFn createChannel;

  @override
  ConsumerState<AylaCreateLiveForm> createState() => _AylaCreateLiveFormState();
}

class _AylaCreateLiveFormState extends ConsumerState<AylaCreateLiveForm> {
  AylaPagedList<AylaDirectoryLiveEntry>? _directory;

  /// 目录热更新事件总线（`live.channel.*` 帧；见 `state/directory_events.dart`）。
  AylaDirectoryEvents? _directoryEvents;
  int _directoryEventRevision = 0;

  /// 目录游标失效（web hook 的 `invalidated`）：置位后由页脚自动刷新恢复。
  bool _invalidated = false;

  /// 正在创建（web `creatingLive`：按钮「创建中…」+ 禁用）。
  bool _creating = false;

  /// 创建失败文案（web `liveCreateError`；null = 无错）。
  String? _createError;

  @override
  void initState() {
    super.initState();
    _startDirectory();
    _registerDirectoryEvents();
  }

  @override
  void dispose() {
    _directoryEvents?.removeListener(_onDirectoryEvents);
    _directoryEvents = null;
    _directory?.removeListener(_onDirectoryChanged);
    _directory?.dispose();
    _directory = null;
    super.dispose();
  }

  /// 建目录并首次取页（web `usePagedMediaList(key, fetchPage, Boolean(owner))`：
  /// **owner 为空时不发请求**，浮层保持「无列表 + 新建键」）。
  void _startDirectory() {
    final String? owner = ref.read(authNotifierProvider).user?.id;
    final AylaPagedList<AylaDirectoryLiveEntry> directory =
        AylaPagedList<AylaDirectoryLiveEntry>(
          request: (String? cursor) => widget.listPage(cursor, owner),
          keyOf: (AylaDirectoryLiveEntry entry) => entry.card.id,
        )..addListener(_onDirectoryChanged);
    _directory = directory;
    if (owner != null && owner.isNotEmpty) unawaited(directory.load());
  }

  void _onDirectoryChanged() {
    if (mounted) setState(() {});
  }

  /// 订阅目录事件（web hook `33–40` 的 `chatWS.onFrame`）：`live.channel.*` 帧
  /// ⇒ 标记失效（页脚自动刷新）+ 删除帧就地移除条目。
  void _registerDirectoryEvents() {
    final AylaDirectoryEvents events = ref.read(directoryEventsProvider);
    _directoryEvents = events;
    _directoryEventRevision = events.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      events.addListener(_onDirectoryEvents);
    });
  }

  void _onDirectoryEvents() {
    if (!mounted) return;
    final AylaDirectoryEvents? events = _directoryEvents;
    if (events == null || events.revision == _directoryEventRevision) return;
    _directoryEventRevision = events.revision;
    final AylaDirectoryEvent? event = events.last;
    if (event == null || event.kind != AylaDirectoryKind.live) return;
    // 人数帧（`live.viewers.changed`）不属于 `live.channel.` 命名空间 ⇒ web 不置失效。
    if (event.memberCount != null) return;
    if (event.deleted) {
      _directory?.removeWhere(
        (AylaDirectoryLiveEntry entry) => entry.card.id == event.id,
      );
    }
    setState(() => _invalidated = true);
  }

  /// 重取首页；期间无新事件时清失效位（web hook `42–47 refreshPage` 的 revision 守卫）。
  Future<void> _refresh() async {
    final AylaPagedList<AylaDirectoryLiveEntry>? directory = _directory;
    if (directory == null) return;
    final int revision = _directoryEventRevision;
    await directory.refresh();
    if (!mounted) return;
    if (_directoryEventRevision == revision) {
      setState(() => _invalidated = false);
    }
  }

  /// 选已有直播间（web `handleLiveStarted`）：关浮层 → 进开播控制台。
  void _startChannel(AylaLiveCardData channel) {
    widget.onClose();
    context.go('/live/start/${channel.id}');
  }

  /// 新建直播间（web `handleCreateNewLive`）：关浮层 → 进新建频道的开播控制台；
  /// 失败保留浮层、显示「创建直播间失败：…」，**不导航**。
  Future<void> _createNew() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final AylaLiveChannelSnapshot created = await widget.createChannel(
        '新直播间', // CreateFab.tsx:46
        group: widget.groupId,
      );
      if (!mounted) return;
      widget.onClose();
      context.go('/live/start/${created.id}');
    } catch (error) {
      if (!mounted) return;
      // web tsx:50：`e instanceof Error ? e.message : "创建直播间失败"` ⇒ 非 API 异常回退固定串。
      setState(
        () => _createError = error is ApiException ? error.message : '创建直播间失败',
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaPagedList<AylaDirectoryLiveEntry>? directory = _directory;
    return AylaLiveStartSheet(
      // 排序 = web `sortLiveChannels`（在播 > 曾播 > 从未），事实源全是后端持久字段。
      channels: directory == null
          ? const <AylaLiveCardData>[]
          : <AylaLiveCardData>[
              for (final AylaDirectoryLiveEntry entry in aylaHubSortLive(
                directory.items,
              ))
                entry.card,
            ],
      loading: directory?.loading ?? false,
      loaded: directory?.loaded ?? false,
      error: directory?.error,
      invalidated: _invalidated,
      hasMore: directory?.hasMore ?? false,
      onStart: _startChannel,
      onCreateNew: () => unawaited(_createNew()),
      creatingNew: _creating,
      createError: _createError,
      onRetry: () => unawaited(_refresh()),
      // web `<DirectoryLoadMore {...directory} />`（弹层是紧凑列表：retainCompletedSpace 默认 true）。
      directoryFooter: AylaDirectoryLoadMore(
        loading: directory?.loading ?? false,
        error: directory?.error,
        hasMore: directory?.hasMore ?? false,
        invalidated: _invalidated,
        loadMore: () => directory?.loadMore() ?? Future<void>.value(),
        refresh: _refresh,
      ),
    );
  }
}
// ===================== 分支分派（纯函数：组件与测试共用同一事实源） =====================

/// 按 `fabAction.handler` 分派创建浮层内容（web `CreateFab.tsx:56–114`）。
///
/// 返回值**就是浮层本身**：
/// - `group` ⇒ [AylaGroupCreateDialog]（组件自带弹层；web `tsx:75–77` **不套** `CreateSheet`）；
/// - `voice` / `live` / `post` / `game` ⇒ [AylaCreateSheet] 包住的对应场景表单；
/// - 未知 handler（含 `null`）⇒ 占位兜底，**不静默**（文案写明 key / handler /
///   plannedStep，便于把漏接的分支直接定位回 `shellConfig.ts` 的哪一条）。
///
/// 与 `router/shell_config.dart` 同口径：**纯分派**；`app_shell.dart` 的 `_createSheet`
/// 只负责把 `close` 传进来。
Widget aylaCreateFormFor(AylaFabAction fabAction, {required VoidCallback onClose}) {
  switch (fabAction.handler) {
    case 'group':
      // tsx:75–77：`{open && isGroupCreate && <GroupCreateDialog onClose={() => setOpen(false)} />}`
      return AylaCreateGroupForm(onClose: onClose);
    case 'voice':
      // tsx:78–82
      return AylaCreateSheet(
        title: fabAction.label, // tsx:79 `title={action.label}`
        onClose: onClose,
        child: AylaCreateVoiceForm(
          groupId: fabAction.groupId, // tsx:80 `group={action.groupId}`
          onClose: onClose, // tsx:80 `onCreated={() => setOpen(false)}`
        ),
      );
    case 'live':
      // tsx:84 的标题是固定串「开始直播」（不是 action.label）
      return AylaCreateSheet(
        title: '开始直播',
        onClose: onClose,
        child: AylaCreateLiveForm(
          groupId: fabAction.groupId, // tsx:46 的第二个实参
          onClose: onClose,
        ),
      );
    case 'post':
      // tsx:93–103
      return AylaCreateSheet(
        title: fabAction.label, // tsx:94
        onClose: onClose,
        child: AylaCreatePostForm(
          groupId: fabAction.groupId, // tsx:96 `group={action.groupId}`
          onClose: onClose,
        ),
      );
    case 'game':
      // tsx:104–114
      return AylaCreateSheet(
        title: fabAction.label, // tsx:105
        onClose: onClose,
        child: AylaCreateGameForm(
          groupId: fabAction.groupId, // tsx:107 `group={action.groupId}`
          onClose: onClose,
        ),
      );
    default:
      return AylaCreateSheet(
        title: fabAction.label,
        onClose: onClose,
        child: Builder(
          builder: (BuildContext context) => Padding(
            padding: const EdgeInsets.all(AylaSpacing.sp2),
            child: Text(
              '未接线的创建动作（web CreateFab.tsx:75–114 无此分支：'
              '${fabAction.key} / handler=${fabAction.handler ?? '—'} / '
              '${fabAction.plannedStep}）',
              style: AylaTextStyles.of(context).caption,
            ),
          ),
        ),
      );
  }
}

// ===================== 可见性选择器共用的群列表 =====================

/// 可见性选择器的群选项（web `VisibilitySelector.tsx:83–84` 渲染的 `{id, title}`）。
typedef AylaGroupOption = ({String id, String title});

/// 拉一次群列表（web `VisibilitySelector.tsx:34` 的
/// `useSocialPage("conversations", { type: "group" }, groupChecked)`）。
///
/// 范本 = `pages/post_detail_page.dart:512–529`（同一取数，供帖子可见性选择器）。
Future<List<AylaGroupOption>> aylaLoadCreateFormGroups() async {
  final AylaDirectoryPage<AylaConversationSummary> page =
      await AylaChatApi.listConversationsPage(type: 'group', limit: 100);
  return <AylaGroupOption>[
    for (final AylaConversationSummary c in page.results)
      if (c.isGroup) (id: c.id, title: c.title),
  ];
}

/// 群列表来源（voice / post / game 三件的可见性选择器共用同一份）。
abstract interface class _AylaCreateFormGroupSource {
  Future<List<AylaGroupOption>> Function() get loadGroups;
}

/// 群列表状态（三件共用的 mixin）。
///
/// 取数失败**不阻断**建表单：选择器保持空列表（web 的列表失败同样只落空态）。
/// 与 web 的差异只在**时机**：web 是「勾选群可见后才拉」，本侧在浮层打开时拉一次。
mixin _AylaCreateFormGroupList<T extends StatefulWidget> on State<T> {
  List<AylaGroupOption> _groups = const <AylaGroupOption>[];
  bool _groupsLoading = false;

  /// 可见性选择器的群列表。
  List<AylaGroupOption> get createFormGroups => _groups;

  /// 群列表加载中。
  bool get createFormGroupsLoading => _groupsLoading;

  @override
  void initState() {
    super.initState();
    _groupsLoading = true; // initState 内直接赋值（首帧前不进 setState）。
    unawaited(_loadCreateFormGroups());
  }

  Future<void> _loadCreateFormGroups() async {
    try {
      final List<AylaGroupOption> groups =
          await (widget as _AylaCreateFormGroupSource).loadGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _groupsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _groupsLoading = false);
    }
  }
}

// ===================== voice：建语音频道（web tsx:78–82） =====================

/// 建频道（web `api/voice.ts:57` 的 `createVoiceChannel`）。
typedef AylaCreateVoiceChannelFn = Future<AylaVoiceChannelSnapshot> Function(
  String name, {
  String? group,
  AylaPostVisibility? visibility,
  List<String>? allowedGroupIds,
});

Future<AylaVoiceChannelSnapshot> _defaultCreateVoiceChannel(
  String name, {
  String? group,
  AylaPostVisibility? visibility,
  List<String>? allowedGroupIds,
}) =>
    AylaVoiceApi.createVoiceChannel(
      name,
      group: group,
      visibility: visibility,
      allowedGroupIds: allowedGroupIds,
    );

/// 建语音频道浮层内容（web `CreateFab.tsx:78–82` 的 voice 分支）。
///
/// 无自有视觉：外观全部来自 [AylaVoiceChannelCreate]（`VoiceChannelCreate.tsx`）；
/// 本件只持有**数据与状态**（群列表 / 提交 / 成功后写 voice 状态）。
class AylaCreateVoiceForm extends ConsumerStatefulWidget
    implements _AylaCreateFormGroupSource {
  const AylaCreateVoiceForm({
    super.key,
    required this.onClose,
    this.groupId,
    this.loadGroups = aylaLoadCreateFormGroups,
    this.createChannel = _defaultCreateVoiceChannel,
  });

  /// 关浮层（web `tsx:80` 的 `onCreated`）。**只在创建成功后**由表单件回调。
  final VoidCallback onClose;

  /// 群归属（web `action.groupId`；一级 tab `/voice` 恒 null）。
  final String? groupId;

  /// 可见性选择器的群列表取数（web `VisibilitySelector.tsx:34`）。
  @override
  final Future<List<AylaGroupOption>> Function() loadGroups;

  /// 建频道（默认走真实 api；测试可注入替身）。
  final AylaCreateVoiceChannelFn createChannel;

  @override
  ConsumerState<AylaCreateVoiceForm> createState() =>
      _AylaCreateVoiceFormState();
}

class _AylaCreateVoiceFormState extends ConsumerState<AylaCreateVoiceForm>
    with _AylaCreateFormGroupList {
  Future<void> _submit(AylaVoiceChannelCreateRequest request) async {
    final AylaVoiceChannelSnapshot channel;
    try {
      channel = await widget.createChannel(
        request.name,
        group: widget.groupId,
        visibility: request.visibility,
        allowedGroupIds: request.allowedGroupIds,
      );
    } on ApiException catch (error) {
      // web `VoiceChannelCreate.tsx:49`：`e instanceof Error ? e.message : "创建失败"`
      // —— 后端文案透传；其余异常由表单件回退固定串。
      throw AylaVoiceChannelCreateException(error.message);
    }
    if (!mounted) return;
    // web `tsx:44–45`：`store.setChannels([{ ...ch, mine: false }, ...store.channels])`
    // —— 刚建好、本人尚未加入 ⇒ `mine` 强制 false（与 web 同）。
    ref.read(voiceStateProvider).upsertChannel(channel.patch(mine: false));
  }

  @override
  Widget build(BuildContext context) => AylaVoiceChannelCreate(
        groupId: widget.groupId,
        groups: createFormGroups,
        groupsLoading: createFormGroupsLoading,
        onSubmit: _submit,
        onCreated: widget.onClose, // tsx:80
      );
}

// ===================== post：发帖（web tsx:93–103） =====================

/// 发帖（web `api/posts.ts` 的 `createPost`；返回 null = 响应结构非法）。
typedef AylaCreatePostFn = Future<AylaPost?> Function(AylaPostDraft draft);

Future<AylaPost?> _defaultCreatePost(AylaPostDraft draft) =>
    AylaPostsApi.createPost(
      title: draft.title.isEmpty ? null : draft.title,
      body: draft.body,
      group: draft.groupId,
      visibility: draft.visibility.wire,
      images: draft.mediaIds,
      allowedGroupIds: draft.allowedGroupIds,
    );

/// 发帖浮层内容（web `CreateFab.tsx:93–103` 的 post 分支）。
///
/// ⚠️ [AylaPostEditor] 没有 web 的 `onCreated` 钩子（只有 `onSubmit`）⇒ 导航在
/// **调用侧**于提交成功后完成（web `tsx:97–100` 的语义**逐字保留**：先关浮层再分流）。
class AylaCreatePostForm extends ConsumerStatefulWidget
    implements _AylaCreateFormGroupSource {
  const AylaCreatePostForm({
    super.key,
    required this.onClose,
    this.groupId,
    this.loadGroups = aylaLoadCreateFormGroups,
    this.createPost = _defaultCreatePost,
  });

  /// 关浮层（web `tsx:98` 的 `setOpen(false)`；**导航前**调用）。
  final VoidCallback onClose;

  /// 群归属（web `action.groupId`；null = 一级 tab 的公开帖）。
  final String? groupId;

  /// 可见性选择器的群列表取数（web `VisibilitySelector.tsx:34`）。
  @override
  final Future<List<AylaGroupOption>> Function() loadGroups;

  /// 发帖（默认走真实 api；测试可注入替身）。
  final AylaCreatePostFn createPost;

  @override
  ConsumerState<AylaCreatePostForm> createState() => _AylaCreatePostFormState();
}

class _AylaCreatePostFormState extends ConsumerState<AylaCreatePostForm>
    with _AylaCreateFormGroupList {
  Future<void> _submit(AylaPostDraft draft) async {
    final AylaPost? created = await widget.createPost(draft);
    if (!mounted) return;
    if (created == null) {
      // 响应结构非法 ⇒ 显式失败（不静默：点了发布必须有反馈）。
      throw const ApiException(0, '发帖响应结构非法');
    }
    // web `tsx:97–100`：先 `setOpen(false)`，再按 groupId 有无分流导航。
    widget.onClose();
    context.go(
      widget.groupId != null
          ? '/group/${Uri.encodeComponent(widget.groupId!)}/posts'
          : '/posts/${Uri.encodeComponent('${created.id}')}',
    );
  }

  @override
  Widget build(BuildContext context) => AylaPostEditor(
        group: widget.groupId, // tsx:96 `group={action.groupId}`
        groups: createFormGroups,
        groupsLoading: createFormGroupsLoading,
        onSubmit: _submit,
      );
}

// ===================== game：建桌游室（web tsx:104–114） =====================

/// 建桌游室（web `api/boardgame.ts:52` 的 `createGameRoom`）。
typedef AylaCreateGameRoomFn = Future<void> Function(
  AylaGameRoomCreateRequest request, {
  String? group,
});

Future<void> _defaultCreateGameRoom(
  AylaGameRoomCreateRequest request, {
  String? group,
}) async {
  await AylaBoardgameApi.createGameRoom(
    name: request.name,
    group: group,
    visibility: request.visibility,
    allowedGroupIds: request.allowedGroupIds,
  );
}

/// 建桌游室浮层内容（web `CreateFab.tsx:104–114` 的 game 分支）。
class AylaCreateGameForm extends ConsumerStatefulWidget
    implements _AylaCreateFormGroupSource {
  const AylaCreateGameForm({
    super.key,
    required this.onClose,
    this.groupId,
    this.loadGroups = aylaLoadCreateFormGroups,
    this.createRoom = _defaultCreateGameRoom,
  });

  /// 关浮层（web `tsx:108` 的 `setOpen(false)`；**导航前**调用）。
  final VoidCallback onClose;

  /// 群归属（web `action.groupId`；null = 一级 tab `/games`）。
  final String? groupId;

  /// 可见性选择器的群列表取数（web `VisibilitySelector.tsx:34`）。
  @override
  final Future<List<AylaGroupOption>> Function() loadGroups;

  /// 建房间（默认走真实 api；测试可注入替身）。
  final AylaCreateGameRoomFn createRoom;

  @override
  ConsumerState<AylaCreateGameForm> createState() => _AylaCreateGameFormState();
}

class _AylaCreateGameFormState extends ConsumerState<AylaCreateGameForm>
    with _AylaCreateFormGroupList {
  Future<void> _submit(AylaGameRoomCreateRequest request) async {
    try {
      await widget.createRoom(request, group: widget.groupId);
    } on ApiException catch (error) {
      // web `GameRoomCreate.tsx:47`：`e instanceof Error ? e.message : "创建失败"`。
      throw AylaGameRoomCreateException(error.message);
    }
  }

  /// 成功：关浮层 + 跳转（web `tsx:107–111`）。
  ///
  /// 目标是**群桌游页 / 一级桌游页**（不带新建房间 id —— 与 web 逐字一致）。
  void _onCreated() {
    widget.onClose(); // tsx:108
    context.go(
      widget.groupId != null
          ? '/group/${Uri.encodeComponent(widget.groupId!)}/games'
          : '/games',
    );
  }

  @override
  Widget build(BuildContext context) => AylaGameRoomCreate(
        groupId: widget.groupId,
        groups: createFormGroups,
        groupsLoading: createFormGroupsLoading,
        onSubmit: _submit,
        onCreated: _onCreated,
      );
}

// ===================== group：建群（web tsx:75–77） =====================

/// 建群（web `api/chat.ts:67–75`），返回新会话 id。
typedef AylaCreateGroupFn = Future<String> Function({
  required String title,
  required List<String> memberIds,
});

/// 发起（或打开）与某用户的私聊（web `api/chat.ts:59–64`），返回会话 id。
typedef AylaOpenPrivateFn = Future<String> Function(String userId);

/// 成员搜索一页（web `api/users.ts:14–16` 的 `searchUsersPage`）。
typedef AylaSearchUsersFn = Future<AylaDirectoryPage<AylaUserPublic>> Function(
  String q, {
  int limit,
  String? cursor,
});

Future<String> _defaultCreateGroup({
  required String title,
  required List<String> memberIds,
}) =>
    AylaChatApi.createGroupConversation(title: title, memberIds: memberIds);

Future<String> _defaultOpenPrivate(String userId) =>
    AylaUsersApi.openPrivateConversation(userId);

Future<AylaDirectoryPage<AylaUserPublic>> _defaultSearchUsers(
  String q, {
  int limit = 30,
  String? cursor,
}) =>
    AylaUsersApi.searchUsersPage(q, limit: limit, cursor: cursor);

/// 建群对话框接线（web `CreateFab.tsx:75–77` 的 group 分支）。
///
/// ⚠️ **不套** [AylaCreateSheet]：web 这一行的 `GroupCreateDialog` 自带弹层
/// （`.group-create-overlay`），Flutter 的 [AylaGroupCreateDialog] 同
/// （复用 [AylaModalOverlay] / [AylaModalCard]）。
class AylaCreateGroupForm extends ConsumerStatefulWidget {
  const AylaCreateGroupForm({
    super.key,
    required this.onClose,
    this.searchUsers = _defaultSearchUsers,
    this.createGroup = _defaultCreateGroup,
    this.openPrivate = _defaultOpenPrivate,
  });

  /// 关浮层（web `tsx:76` 的 `onClose`）。
  final VoidCallback onClose;

  /// 成员搜索分页（默认走真实 api；测试可注入替身）。
  final AylaSearchUsersFn searchUsers;

  /// 建群（默认走真实 api；测试可注入替身）。
  final AylaCreateGroupFn createGroup;

  /// 发起私聊（默认走真实 api；测试可注入替身）。
  final AylaOpenPrivateFn openPrivate;

  @override
  ConsumerState<AylaCreateGroupForm> createState() =>
      _AylaCreateGroupFormState();
}

class _AylaCreateGroupFormState extends ConsumerState<AylaCreateGroupForm> {
  /// 搜索结果（web `useSocialPage("users", {q})`；**300ms 防抖在对话框组件内**）。
  List<AylaUserPublic> _members = const <AylaUserPublic>[];
  bool _membersLoading = false;
  String? _membersError;
  String? _membersCursor;
  bool _membersHasMore = false;

  /// 已防抖的搜索词（与 home_page 的建群弹窗同口径）。
  String _membersQuery = '';

  /// 结果代际守卫（旧请求返回时丢弃，不覆盖新词的结果）。
  int _membersRevision = 0;

  /// 私聊路径的会话 id（[AylaGroupCreateDialog.onDone] 不区分两条路径，见 [_onDone]）。
  String? _privateConversationId;

  /// 搜索词变化（组件已防抖 300ms）。
  void _onSearchChanged(String query) {
    if (query == _membersQuery) return;
    _membersQuery = query;
    _membersCursor = null;
    _membersHasMore = false;
    if (query.trim().isEmpty) {
      setState(() {
        _members = const <AylaUserPublic>[];
        _membersLoading = false;
        _membersError = null;
      });
      return;
    }
    unawaited(_loadMembers(refresh: true));
  }

  /// 取一页搜索结果（范本 = `pages/home_page.dart:633–670`）。
  Future<void> _loadMembers({bool refresh = false}) async {
    final String query = _membersQuery.trim();
    if (query.isEmpty) return;
    final int revision = ++_membersRevision;
    setState(() {
      _membersLoading = true;
      if (refresh) _membersError = null;
    });
    try {
      final AylaDirectoryPage<AylaUserPublic> page = await widget.searchUsers(
        query,
        cursor: refresh ? null : _membersCursor,
      );
      if (!mounted || revision != _membersRevision) return;
      final Map<String, AylaUserPublic> merged = <String, AylaUserPublic>{};
      if (!refresh) {
        for (final AylaUserPublic u in _members) {
          merged[u.id] = u;
        }
      }
      for (final AylaUserPublic u in page.results) {
        merged[u.id] = u;
      }
      setState(() {
        _members = merged.values.toList(growable: false);
        _membersCursor = page.nextCursor;
        _membersHasMore = page.hasMore;
        _membersLoading = false;
        _membersError = null;
      });
    } catch (_) {
      if (!mounted || revision != _membersRevision) return;
      setState(() {
        _membersLoading = false;
        _membersError = '搜索失败';
      });
    }
  }

  /// 建群（web `tsx:46–64`）。
  Future<String> _createGroup(String title, List<String> memberIds) async {
    try {
      return await widget.createGroup(title: title, memberIds: memberIds);
    } on ApiException catch (error) {
      throw AylaGroupCreateException(error.message); // tsx:60 `e.message`
    }
  }

  /// 发起私聊（web `tsx:66–80`）。
  Future<String> _openPrivate(String userId) async {
    try {
      final String conversationId = await widget.openPrivate(userId);
      _privateConversationId = conversationId;
      return conversationId;
    } on ApiException catch (error) {
      throw AylaGroupCreateException(error.message); // tsx:76
    }
  }

  /// 成功后的跳转（web 两条路径各自 navigate：`tsx:58` 群页 / `tsx:74` 私聊页）。
  ///
  /// ⚠️ **调用侧适配**：web 的 `GroupCreateDialog` 在两条路径里分别 `navigate(...)`，
  /// 而 Flutter 的 [AylaGroupCreateDialog.onDone] 只回传会话 id、**不区分路径**
  /// （`group_create_dialog.dart:196 / 221` 是同一回调）⇒ 本件用「最近一次私聊的
  /// 会话 id」判定私聊路径，其余按 web 的建群路径处理（**不改组件契约**）。
  void _onDone(String conversationId) {
    final bool isPrivate = conversationId == _privateConversationId;
    _privateConversationId = null;
    widget.onClose(); // tsx:57 / 73
    context.go(
      isPrivate
          ? '/chat/${Uri.encodeComponent(conversationId)}'
          : '/group/${Uri.encodeComponent(conversationId)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AylaGroupCreateDialog(
      onClose: widget.onClose, // tsx:76
      // tsx:30：结果里过滤掉自己。
      currentUserId: ref.read(authNotifierProvider).user?.id,
      searchResults: _members,
      searchLoading: _membersLoading,
      searchError: _membersError,
      searchHasMore: _membersHasMore,
      onSearchChanged: _onSearchChanged,
      onLoadMoreResults: () => _loadMembers(),
      onRefreshResults: () => _loadMembers(refresh: true),
      onSubmit: _createGroup,
      onOpenPrivate: _openPrivate,
      onDone: _onDone,
    );
  }
}
