/// 群信息界面 —— web `pages/group/GroupInfo.tsx`（1018 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 资料卡（头像 / 群名 / 简介 / 创建时间 / 三格统计 + 分享 + 编辑） | 415–519 |
/// | 编辑态（群名 + 简介 + 保存/取消 + 错误） | 460–518（`patchConversation`） |
/// | 群头像：选择 → 校验 → 预览 → 保存（三步上传 + PATCH） | 145–176 |
/// | 管理卡：加入方式（群主可改，自绘下拉）/ 入群申请审批 / 转让 / 解散 / 退出 | 522–645 |
/// | 右列：子群卡（预览 3 条 + 展开 + 编辑态） / 成员卡（搜索 + 角色 + 操作） | 648–794 |
/// | 两栏/单列布局与骨架 | 1422–1466（`AylaGroupInfoLayout`） |
/// | 三个弹窗（转让群主 / 子群编辑 / 危险操作确认） | 797–889 |
///
/// ## 机制差异（登记）
/// 1. **「成员可上传表情包」开关未接**：web 读 `api/emoji.ts` 的群表情包摘要
///    （`getGroupEmojiPackSummary` / `setGroupEmojiUploadPolicy`，tsx 222–263）；
///    Flutter 侧尚无 emoji 域 api（表情包面板已交付，但那是 `emoji` 数据源）⇒
///    该行**不渲染**（web 在没有摘要时同样不渲染：`emojiPolicyLoaded` 为 false 才隐藏）。
/// 2. **在线态已接 presence**（2026-09-29）：成员数统计 / 成员列表 / 转让弹窗三处
///    与 web `GroupInfo.tsx:210 / 764 / 971` 用**同一条规则**
///    `presenceOnline(users, withLiveStatus(statuses, m.user))` ——
///    WS 增量优先、无记录回退 REST 快照 `user.online`、**隐身强制离线**；
///    后端 `display_status` 是快照口径，实时事件到达后按该规则覆盖（与 web 一致）。
/// 3. **「已载入成员在线 N」统计口径不变**：只数**当前已加载页**里判为在线的成员
///    （web `GroupInfo.tsx:207–213` 同样是 `members.filter(...)` 于已加载页）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/models/conversation.dart';
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../core/models/social_requests.dart' as api;
import '../core/models/subgroup.dart'
    show AylaGroupJoinPolicy, AylaSubGroup, AylaSubgroupPage;
import '../widgets/base/share.dart' show AylaShareButton;
import '../widgets/group/group_scene.dart' show AylaGroupScenePlaceholder;
import '../core/media/media_actions.dart' show AylaMediaActions;
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../state/auth_state.dart' show AuthState, authNotifierProvider;
import '../state/subgroup_state.dart' show AylaSubGroupState;
import '../state/chat_providers.dart';
import '../state/display_status.dart';
import '../state/group_providers.dart';
import '../state/presence_providers.dart';
import '../state/paged_list.dart';
import '../theme/tokens.dart' show AylaSpacing;
import '../widgets/base/dialogs.dart' show AylaConfirmDialog;
import '../widgets/base/resource_image.dart' show mediaContentUrl;
import '../widgets/group/group_info_lists.dart';
import '../widgets/group/group_info_manage.dart';
import '../widgets/group/group_info_profile.dart';
import '../widgets/group/group_info_settings.dart';
import '../widgets/group/group_role_chip.dart' show AylaGroupRole;
import '../widgets/group/subgroup_dialog.dart';
import '../widgets/group/transfer_owner_dialog.dart';
import 'share_support.dart' show AylaShareController, aylaOpenShareSheet;

/// 子群卡默认展示条数（web tsx 59：超出由「查看更多」展开）。
const int kAylaSubgroupPreviewCount = 3;

class GroupInfoPage extends ConsumerStatefulWidget {
  const GroupInfoPage({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends ConsumerState<GroupInfoPage> {
  AylaPagedList<AylaConversationMember>? _members;
  AylaPagedList<AylaSubGroup>? _subgroups;
  AylaPagedList<api.AylaGroupJoinRequest>? _joinRequests;
  final AylaShareController _share = AylaShareController();
  final TextEditingController _memberQuery = TextEditingController();

  AylaConversationSummary? _detail;
  String? _loadError;
  bool _editing = false;
  bool _saving = false;
  String? _error;
  String? _managementError;
  String? _busyAction;
  bool _subgroupEditing = false;
  bool _showAllSubgroups = false;
  bool _subgroupBusy = false;
  String? _subgroupError;
  AylaSubGroupDialogState? _subgroupDialog;
  AylaSubGroup? _subgroupDelete;
  bool _transferOpen = false;
  bool _confirmDissolve = false;
  bool _confirmLeave = false;
  AylaConversationMember? _confirmTransfer;
  bool _avatarPreview = false;
  bool _avatarSaving = false;
  String? _avatarError;
  String? _avatarMediaId;

  String get groupId => widget.groupId;

  @override
  void initState() {
    super.initState();
    _members = AylaPagedList<AylaConversationMember>(
      request: (String? cursor) => AylaChatApi.listConversationMembersPage(
        groupId,
        cursor: cursor,
        q: _memberQuery.text,
      ),
      keyOf: (AylaConversationMember m) => m.id,
    )..addListener(_onChanged);
    _subgroups = AylaPagedList<AylaSubGroup>(
      // `listSubgroupsPage` 的响应多带 `default` 字段 ⇒ 投影成通用游标页（同 GroupPage）。
      request: (String? cursor) async {
        final AylaSubgroupPage page = await AylaChatApi.listSubgroupsPage(
          groupId,
          cursor: cursor,
        );
        return AylaDirectoryPage<AylaSubGroup>(
          results: page.results,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          total: page.total,
        );
      },
      keyOf: (AylaSubGroup sg) => sg.id,
    )..addListener(_onChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _members?.removeListener(_onChanged);
    _members?.dispose();
    _subgroups?.removeListener(_onChanged);
    _subgroups?.dispose();
    _joinRequests?.removeListener(_onChanged);
    _joinRequests?.dispose();
    _memberQuery.dispose();
    _share.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  AylaConversationSummary? get _conv =>
      ref.read(chatStateProvider).byId(groupId) ?? _detail;

  bool get _isOwner => _conv?.myRole == AylaConversationMemberRole.owner;

  bool get _canManage => _isOwner ||
      _conv?.myRole == AylaConversationMemberRole.admin;

  Future<void> _bootstrap() async {
    await _subgroups!.load();
    if (!mounted) return;
    // 子群列表落库（默认组兜底；与 GroupPage 同一投影）。
    final AylaSubGroupState state = ref.read(subgroupStateProvider);
    if (state.subgroupsOf(groupId).isEmpty) {
      state.setSubgroups(groupId, _subgroups!.items);
    }
    await _members!.load();
    if (!mounted) return;
    if (_canManage) await _loadJoinRequests();
    if (_conv == null) {
      try {
        final AylaConversationSummary fresh =
            await AylaChatApi.getConversationMetadata(groupId);
        if (!mounted) return;
        ref.read(chatStateProvider).upsertConversation(fresh);
        setState(() => _detail = fresh);
      } catch (error) {
        if (mounted) setState(() => _loadError = error.toString());
      }
    }
  }

  Future<void> _loadJoinRequests() async {
    _joinRequests?.removeListener(_onChanged);
    _joinRequests?.dispose();
    final AylaPagedList<api.AylaGroupJoinRequest> pager =
        AylaPagedList<api.AylaGroupJoinRequest>(
      request: (String? cursor) => AylaChatApi.listJoinRequestsPage(
        groupId,
        cursor: cursor,
      ),
      keyOf: (api.AylaGroupJoinRequest r) => r.id,
    )..addListener(_onChanged);
    _joinRequests = pager;
    await pager.load();
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final AylaConversationSummary fresh =
        await AylaChatApi.getConversationMetadata(groupId);
    if (!mounted) return;
    ref.read(chatStateProvider).upsertConversation(fresh);
    setState(() => _detail = fresh);
  }

  Future<void> _runManagement(
    String key,
    Future<void> Function() action,
  ) async {
    setState(() {
      _busyAction = key;
      _managementError = null;
    });
    try {
      await action();
      await _reload();
      await _members?.refresh();
    } catch (error) {
      if (mounted) setState(() => _managementError = error.toString());
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _saveEdit(String title, String about) async {
    if (title.trim().isEmpty) {
      setState(() => _error = '群名不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AylaChatApi.patchConversation(
        groupId,
        title: title.trim(),
        announcement: about,
      );
      await _reload();
      if (mounted) setState(() => _editing = false);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 群头像三步：选图 → 本地校验 + 预览 → 保存（上传 + PATCH）。
  Future<void> _pickAvatar() async {
    final AylaPickedFile? file = await AylaMediaActions.pickImage();
    if (file == null || !mounted) return;
    // 校验在上传层（`AylaMediaActions` 只提供选择/上传两个入口；web 的
    // `validateImageFile` 在 Flutter 侧收在上传实现的错误反馈里）。
    setState(() {
      _avatarError = null;
      _avatarSaving = true;
    });
    try {
      final String mediaId = await AylaMediaActions.uploadImage(file);
      if (!mounted) return;
      setState(() {
        _avatarMediaId = mediaId;
        _avatarPreview = true;
      });
    } catch (error) {
      if (mounted) setState(() => _avatarError = error.toString());
    } finally {
      if (mounted) setState(() => _avatarSaving = false);
    }
  }

  Future<void> _saveAvatar() async {
    final String? mediaId = _avatarMediaId;
    if (mediaId == null) return;
    setState(() {
      _avatarSaving = true;
      _avatarError = null;
    });
    try {
      final AylaConversationSummary conv =
          await AylaChatApi.patchConversation(
        groupId,
        avatar: mediaContentUrl(mediaId),
      );
      if (!mounted) return;
      ref.read(chatStateProvider).upsertConversation(conv);
      setState(() {
        _detail = conv;
        _avatarMediaId = null;
        _avatarPreview = false;
      });
    } catch (error) {
      if (mounted) setState(() => _avatarError = error.toString());
    } finally {
      if (mounted) setState(() => _avatarSaving = false);
    }
  }

  Future<void> _dissolve() async {
    setState(() {
      _busyAction = 'dissolve';
      _managementError = null;
      _confirmDissolve = false;
    });
    try {
      await AylaChatApi.dissolveGroup(groupId);
      if (!mounted) return;
      ref.read(chatStateProvider).removeConversation(groupId);
      context.go('/group');
    } catch (error) {
      if (mounted) setState(() => _managementError = error.toString());
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _leave() async {
    setState(() {
      _busyAction = 'leave';
      _managementError = null;
      _confirmLeave = false;
    });
    try {
      await AylaChatApi.leaveGroup(groupId);
      if (!mounted) return;
      ref.read(chatStateProvider).removeConversation(groupId);
      final List<AylaConversationSummary> remaining = <AylaConversationSummary>[
        for (final AylaConversationSummary c
            in ref.read(chatStateProvider).conversations)
          if (c.isGroup && c.id != groupId) c,
      ];
      if (remaining.isNotEmpty) {
        context.go('/group/${Uri.encodeComponent(remaining.first.id)}');
      } else {
        context.go('/group');
      }
    } catch (error) {
      if (mounted) setState(() => _managementError = error.toString());
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  AylaGroupRole _roleOf(AylaConversationMemberRole? role) => switch (role) {
        AylaConversationMemberRole.owner => AylaGroupRole.owner,
        AylaConversationMemberRole.admin => AylaGroupRole.admin,
        _ => AylaGroupRole.member,
      };

  @override
  Widget build(BuildContext context) {
    ref.watch(subgroupStateProvider);
    final AylaConversationSummary? conv = _conv;
    if (conv == null) {
      // tsx 392–408：加载骨架 / 错误态。
      return AylaGroupInfoLayout(
        loading: _loadError == null,
        side: <Widget>[
          if (_loadError != null)
            AylaGroupScenePlaceholder(
              title: '群信息加载失败',
              description: _loadError,
            ),
        ],
        main: const <Widget>[],
      );
    }
    return _buildInfo(context, conv);
  }

  // ======================= 页面装配（tsx 410–890）=======================

  Widget _buildInfo(BuildContext context, AylaConversationSummary conv) {
    final AylaPagedList<AylaConversationMember>? members = _members;
    final AylaPagedList<AylaSubGroup>? subgroups = _subgroups;
    final AylaPagedList<api.AylaGroupJoinRequest>? joinRequests = _joinRequests;
    final String? currentUserId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );
    final List<AylaSubGroup> subgroupItems = subgroups?.items ?? const <AylaSubGroup>[];
    final List<AylaSubGroup> visibleSubgroups = _showAllSubgroups
        ? subgroupItems
        : subgroupItems.take(kAylaSubgroupPreviewCount).toList(growable: false);
    // presence 在线态（web `GroupInfo.tsx:74–75` 在**页面级**读 users/statuses，
    // 全页随 presence 事件重渲染）。
    final Map<String, String> onlineUsers =
        ref.watch(presenceStateProvider).users;
    final Map<String, String> onlineStatuses =
        ref.watch(presenceStateProvider).statuses;
    // 页面内成员在线判定（web `GroupInfo.tsx:210 / 764 / 971` 的同一条规则）。
    bool memberOnline(AylaConversationMember m) =>
        presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user));
    final int onlineCount = <AylaConversationMember>[
      for (final AylaConversationMember m in members?.items ?? const <AylaConversationMember>[])
        if (memberOnline(m)) m,
    ].length;
    final String memberCountLabel =
        '${conv.memberCount == 0 ? (members?.total ?? 0) : conv.memberCount}';

    final Widget profile = AylaGroupInfoProfile(
      title: conv.title,
      about: conv.announcement.isEmpty ? null : conv.announcement,
      createdAt: DateTime.tryParse(conv.createdAt ?? ''),
      stats: <AylaGroupInfoStat>[
        AylaGroupInfoStat(value: memberCountLabel, label: '成员'),
        AylaGroupInfoStat(value: '$onlineCount', label: '已载入在线'),
        AylaGroupInfoStat(value: '${subgroups?.total ?? 0}', label: '子群'),
      ],
      avatarUrl: _avatarPreview && _avatarMediaId != null
          ? mediaContentUrl(_avatarMediaId!)
          : (conv.avatar.isEmpty ? null : conv.avatar),
      avatarNarrowSize: 76,
      avatarWideSize: 92,
      canManage: _canManage,
      onBack: () => context.go('/group/${Uri.encodeComponent(groupId)}'),
      onChangeAvatar: _canManage ? () => unawaited(_pickAvatar()) : null,
      avatarPreview: _avatarPreview,
      avatarSaving: _avatarSaving,
      onSaveAvatar: _avatarPreview ? () => unawaited(_saveAvatar()) : null,
      avatarError: _avatarError,
      editing: _editing,
      initialTitle: conv.title,
      initialAbout: conv.announcement,
      onSaveEdit: (String title, String about) =>
          unawaited(_saveEdit(title, about)),
      onCancelEdit: () => setState(() => _editing = false),
      saving: _saving,
      error: _error,
      onEdit: _canManage ? () => setState(() => _editing = true) : null,
      share: AylaShareButton(
        label: '分享群聊',
        onPressed: () => unawaited(aylaOpenShareSheet(
          context,
          payload: AylaSharePayload.group(
            id: conv.id,
            title: conv.title,
            avatar: conv.avatar.isEmpty ? null : conv.avatar,
            memberCount: conv.memberCount,
            joinPolicy: conv.joinPolicy,
          ),
          controller: _share,
          currentUserId: currentUserId,
        )),
      ),
    );

    final Widget manageCard = _buildManageCard(conv, joinRequests);
    final Widget subgroupCard = _buildSubgroupCard(subgroupItems, visibleSubgroups);
    final Widget memberCard =
        _buildMemberCard(members, currentUserId, memberOnline);

    return Stack(
      children: <Widget>[
        AylaGroupInfoLayout(
          side: <Widget>[profile, manageCard],
          main: <Widget>[subgroupCard, memberCard],
        ),
        if (_transferOpen)
          AylaTransferOwnerDialog(
            members: <AylaTransferMember>[
              for (final AylaConversationMember m
                  in members?.items ?? const <AylaConversationMember>[])
                if (m.role != AylaConversationMemberRole.owner &&
                    m.user.id != currentUserId)
                  AylaTransferMember(
                    id: m.user.id,
                            displayName: m.user.displayName ?? m.user.username ?? '',
                    role: _roleOf(m.role),
                    avatarUrl: (m.user.avatar ?? '').isEmpty ? null : m.user.avatar,
                    online: memberOnline(m), // tsx 971
                  ),
            ],
            selectedId: null,
            query: '',
            onQueryChanged: (String _) {},
            onClose: () => setState(() => _transferOpen = false),
            onConfirm: (AylaTransferMember m) {
              AylaConversationMember? target;
              for (final AylaConversationMember item
                  in members?.items ?? const <AylaConversationMember>[]) {
                if (item.user.id == m.id) target = item;
              }
              setState(() {
                _transferOpen = false;
                _confirmTransfer = target;
              });
            },
          ),
        if (_confirmTransfer != null)
          AylaConfirmDialog(
            title: '转让群主',
            message:
                '确定将群主转让给 ${_confirmTransfer!.user.displayName ?? _confirmTransfer!.user.username ?? ''}？转让后你将成为普通成员',
            confirmLabel: '转让',
            busy: _busyAction == 'transfer',
            onConfirm: () {
              final AylaConversationMember target = _confirmTransfer!;
              setState(() => _confirmTransfer = null);
              unawaited(_runManagement(
                'transfer',
                () => AylaChatApi.transferGroupOwner(groupId, target.user.id),
              ));
            },
            onClose: () => setState(() => _confirmTransfer = null),
          ),
        if (_confirmDissolve)
          AylaConfirmDialog(
            title: '解散群聊',
            message: '确定解散群聊「${conv.title}」？此操作不可撤销，所有成员都会被移出。',
            confirmLabel: '解散',
            onConfirm: () => unawaited(_dissolve()),
            onClose: () => setState(() => _confirmDissolve = false),
          ),
        if (_confirmLeave)
          AylaConfirmDialog(
            title: '退出群聊',
            message: '确定退出群聊「${conv.title}」？',
            confirmLabel: '退出',
            onConfirm: () => unawaited(_leave()),
            onClose: () => setState(() => _confirmLeave = false),
          ),
        if (_subgroupDialog != null)
          AylaSubGroupDialog(
            state: _subgroupDialog!,
            busy: _subgroupBusy,
            error: _subgroupError,
            onClose: () {
              if (_subgroupBusy) return;
              setState(() {
                _subgroupDialog = null;
                _subgroupError = null;
              });
            },
            onConfirm: (String name, bool? muted) => unawaited(
              _confirmSubgroup(name, muted),
            ),
            onDelete: () {
              final AylaSubGroupDialogState state = _subgroupDialog!;
              if (state.subgroup != null) {
                setState(() => _subgroupDelete = state.subgroup);
              }
            },
          ),
        if (_subgroupDelete != null)
          AylaConfirmDialog(
            title: '删除子群',
            message: '确定删除子群「${_subgroupDelete!.name}」？该子群的所有聊天记录将永久删除，无法恢复。',
            confirmLabel: '删除',
            busy: _subgroupBusy,
            onConfirm: () => unawaited(_deleteSubgroup()),
            onClose: () {
              if (_subgroupBusy) return;
              setState(() {
                _subgroupDelete = null;
                _subgroupError = null;
              });
            },
          ),
      ],
    );
  }

  /// 管理卡（tsx 522–645）。
  Widget _buildManageCard(
    AylaConversationSummary conv,
    AylaPagedList<api.AylaGroupJoinRequest>? joinRequests,
  ) {
    final bool publicJoin = conv.joinPolicy == 'public';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const AylaGroupInfoSectionTitle(title: '管理', icon: null),
        if (_managementError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(_managementError!),
          ),
        if (_canManage) ...<Widget>[
          AylaGroupInfoSettingsBox(
            children: <Widget>[
              AylaGroupInfoSettingRow(
                label: '加入方式',
                value: _isOwner ? null : (publicJoin ? '公开加入' : '申请加入'),
                trailing: _isOwner
                    ? AylaGroupInfoSelect(
                        value: publicJoin ? 'public' : 'application',
                        enabled: _busyAction == null,
                        semanticLabel: '加入方式',
                        options: const <AylaGroupJoinPolicyOption>[
                          AylaGroupJoinPolicyOption(
                            value: 'public',
                            label: '公开加入',
                          ),
                          AylaGroupJoinPolicyOption(
                            value: 'application',
                            label: '申请加入',
                          ),
                        ],
                        onChanged: (String next) => unawaited(
                          _runManagement(
                            'join-policy',
                            () => AylaChatApi.patchConversation(
                              groupId,
                              joinPolicy: next == 'public'
                                  ? AylaGroupJoinPolicy.public
                                  : AylaGroupJoinPolicy.application,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
          AylaGroupJoinRequests(
            total: joinRequests?.total ?? 0,
            requests: <AylaGroupJoinRequest>[
              for (final api.AylaGroupJoinRequest r
                  in joinRequests?.items ?? const <api.AylaGroupJoinRequest>[])
                AylaGroupJoinRequest(
                  id: r.id,
                  name: (r.applicant.nickname ?? '').isEmpty
                      ? (r.applicant.username ?? '')
                      : r.applicant.nickname ?? '',
                  message: r.message,
                ),
            ],
            loading: joinRequests?.loading ?? false,
            error: joinRequests?.error != null,
            busy: _busyAction != null,
            onAccept: (AylaGroupJoinRequest request) => unawaited(
              _runManagement(
                'join-${request.id}',
                () async {
                  await AylaChatApi.actionJoinRequest(request.id, true);
                  joinRequests?.removeWhere(
                    (api.AylaGroupJoinRequest r) => r.id == request.id,
                  );
                },
              ),
            ),
            onReject: (AylaGroupJoinRequest request) => unawaited(
              _runManagement(
                'join-${request.id}',
                () async {
                  await AylaChatApi.actionJoinRequest(request.id, false);
                  joinRequests?.removeWhere(
                    (api.AylaGroupJoinRequest r) => r.id == request.id,
                  );
                },
              ),
            ),
          ),
        ],
        AylaGroupInfoDangerActions(
          onTransfer: _isOwner ? () => setState(() => _transferOpen = true) : null,
          onDissolve: _isOwner ? () => setState(() => _confirmDissolve = true) : null,
          dissolveBusy: _busyAction == 'dissolve',
          onLeave: !_isOwner ? () => setState(() => _confirmLeave = true) : null,
          leaveBusy: _busyAction == 'leave',
          anyActionBusy: _busyAction != null,
        ),
      ],
    );
  }

  /// 子群卡（tsx 650–745）。
  Widget _buildSubgroupCard(
    List<AylaSubGroup> items,
    List<AylaSubGroup> visible,
  ) {
    final AylaSubGroupState state = ref.read(subgroupStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AylaGroupInfoCardHead(
          title: '子群',
          count: _subgroups?.total ?? items.length,
          actionLabel: _canManage && !_subgroupEditing ? '编辑子群' : null,
          actionSemanticLabel: '编辑子群',
          onAction: _canManage && !_subgroupEditing
              ? () => setState(() {
                    _subgroupError = null;
                    _subgroupEditing = true;
                  })
              : null,
        ),
        if (_subgroupError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(_subgroupError!),
          ),
        AylaGroupSubgroupList(
          subgroups: <AylaGroupSubgroupItem>[
            for (final AylaSubGroup sg in visible)
              AylaGroupSubgroupItem(
                id: sg.id,
                name: sg.name,
                isDefault: sg.isDefault,
                muted: sg.muted == true,
                unread: state.unreadOf(groupId, sg.id),
              ),
          ],
          loading: _subgroups?.loading ?? false,
          error: _subgroups?.error != null,
          canManage: _canManage,
          editing: _subgroupEditing,
          onEdit: (AylaGroupSubgroupItem item) {
            AylaSubGroup? target;
            for (final AylaSubGroup sg in items) {
              if (sg.id == item.id) target = sg;
            }
            if (target == null) return;
            setState(() {
              _subgroupError = null;
              _subgroupDialog = AylaSubGroupDialogState.edit(target!);
            });
          },
          onAdd: _canManage
              ? () => setState(() {
                    _subgroupError = null;
                    _subgroupDialog = const AylaSubGroupDialogState.add();
                  })
              : null,
          onDone: () => setState(() => _subgroupEditing = false),
        ),
        if (items.length > kAylaSubgroupPreviewCount)
          AylaGroupSubgroupExpandButton(
            hiddenCount: items.length - kAylaSubgroupPreviewCount,
            expanded: _showAllSubgroups,
            onPressed: () =>
                setState(() => _showAllSubgroups = !_showAllSubgroups),
          ),
      ],
    );
  }

  /// 成员卡（tsx 747–793）。
  ///
  /// [memberOnline] = presence 实时在线判定（web `GroupInfo.tsx:764`；
  /// 无记录回退 REST 快照 `user.online`、隐身强制离线）。
  Widget _buildMemberCard(
    AylaPagedList<AylaConversationMember>? members,
    String? currentUserId,
    bool Function(AylaConversationMember) memberOnline,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AylaGroupInfoCardHead(
          title: '成员',
          count: members?.total ?? 0,
          onlineCount: <AylaConversationMember>[
            for (final AylaConversationMember m
                in members?.items ?? const <AylaConversationMember>[])
              if (memberOnline(m)) m, // tsx 207–213 + 752
          ].length,
        ),
        AylaGroupMemberSearchField(
          controller: _memberQuery,
          onChanged: (String value) {
            unawaited(members?.refresh());
          },
        ),
        AylaGroupMemberList(
          members: <AylaGroupMemberItem>[
            for (final AylaConversationMember m
                in members?.items ?? const <AylaConversationMember>[])
              AylaGroupMemberItem(
                id: m.user.id,
                name: m.user.displayName ?? m.user.username ?? '',
                avatarUrl: (m.user.avatar ?? '').isEmpty ? null : m.user.avatar,
                online: memberOnline(m), // tsx 764
                role: _roleOf(m.role),
                isSelf: m.user.id == currentUserId,
              ),
          ],
          loading: members?.loading ?? false,
          error: members?.error != null,
          canManage: _canManage,
          isOwner: _isOwner,
          busyAction: _busyAction,
          onSetRole: (AylaGroupMemberItem item) => unawaited(
            _runManagement(
              'role-${item.id}',
              () => AylaChatApi.setMemberRole(
                groupId,
                item.id,
                item.role == AylaGroupRole.admin
                    ? AylaConversationMemberRole.member
                    : AylaConversationMemberRole.admin,
              ),
            ),
          ),
          onRemove: (AylaGroupMemberItem item) => unawaited(
            _runManagement(
              'remove-${item.id}',
              () => AylaChatApi.removeMember(groupId, item.id),
            ),
          ),
          onOpenProfile: (AylaGroupMemberItem item) =>
              context.go('/user/${Uri.encodeComponent(item.id)}'),
        ),
      ],
    );
  }

  /// 子群编辑提交（tsx 817–829）。
  Future<void> _confirmSubgroup(String name, bool? muted) async {
    final AylaSubGroupDialogState? state = _subgroupDialog;
    if (state == null) return;
    setState(() {
      _subgroupBusy = true;
      _subgroupError = null;
    });
    try {
      final AylaSubGroup sg = state.subgroup == null
          ? await AylaChatApi.createSubgroup(groupId, name)
          : await AylaChatApi.updateSubgroup(
              groupId,
              state.subgroup!.id,
              name: name,
              muted: muted,
            );
      if (!mounted) return;
      ref.read(subgroupStateProvider).upsertSubgroup(sg.conversationId.isEmpty ? groupId : sg.conversationId, sg);
      await _subgroups?.refresh();
      if (mounted) setState(() => _subgroupDialog = null);
    } catch (error) {
      if (mounted) setState(() => _subgroupError = error.toString());
    } finally {
      if (mounted) setState(() => _subgroupBusy = false);
    }
  }

  /// 删除子群（tsx 338–354）：失败保留编辑框与错误。
  Future<void> _deleteSubgroup() async {
    final AylaSubGroup? target = _subgroupDelete;
    if (target == null) return;
    setState(() {
      _subgroupBusy = true;
      _subgroupError = null;
    });
    try {
      await AylaChatApi.deleteSubgroup(groupId, target.id);
      if (!mounted) return;
      final AylaSubGroupState state = ref.read(subgroupStateProvider);
      state.removeSubgroup(groupId, target.id);
      if (state.activeSubgroupOf(groupId) == target.id) {
        String? fallback;
        for (final AylaSubGroup sg in state.subgroupsOf(groupId)) {
          if (sg.isDefault) fallback = sg.id;
        }
        state.setActiveSubgroup(groupId, fallback);
      }
      await _subgroups?.refresh();
      if (mounted) {
        setState(() {
          _subgroupDelete = null;
          _subgroupDialog = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _subgroupDelete = null;
          _subgroupError = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _subgroupBusy = false);
    }
  }
}