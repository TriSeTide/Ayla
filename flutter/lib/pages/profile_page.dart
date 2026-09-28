/// 个人页 —— 资料查看与编辑 + 三分区（我的发帖 / 我的直播间 / 正在玩的桌游）+ 收藏入口 + 账号区。
///
/// ## 事实源（逐条）
/// - `web/src/pages/ProfilePage.tsx`（317 行全文）：DOM 顺序、文案、`dirty` 判据、
///   「保存后只归一化本次提交的草稿、更新的编辑保持本地」（tsx 128–134）、
///   `useEffect([currentUser?.id])` 的重置语义（tsx 52–64）；
/// - `web/src/styles/profile.css`：`.profile-page-split` 两档 ——
///   · ≥769（`:has(.profile-main)`）：页面根 flex column + overflow hidden、padding sp3 sp3 0、
///     `.profile-column` flex row + gap sp3、`.profile-side` 宽 `clamp(280,32%,340)`、
///     `.profile-main` 吃剩余宽且独立滚动；
///   · ≤768：`.profile-side` / `.profile-main` 都是 `display: contents` ⇒ **退回单列自然流**；
///   · `.profile-card { padding: sp4; gap: sp4 }`、`.profile-form { gap: sp3 }`（宽屏档）；
/// - 组件库复用（**不重画**）：[AylaProfileCard]（`.solid-card.profile-card`）·
///   [AylaProfileIdentity]（返回 + 头像 64 + 昵称/用户名 + 分享槽）· [AylaProfileAvatarActions] ·
///   [AylaProfileForm]（状态胶囊 / 昵称 / 签名 / 展示开关 / 保存 / 退出）·
///   [AylaProfileContentSections] · [AylaPrivacySheet] · [AylaShareButton] ·
///   [AylaFullScreenSwipeBack]（`enabled: isNarrow`，tsx 149）。
///
/// ## 未接线（第 1 批登记，见 13 号文档）
/// · **内容三分区的数据源**（我的发帖 / 我的直播间 / 正在玩的桌游）属帖子 / 直播 / 桌游域
///   ⇒ 本页给 [AylaProfileContentSections] 传 `postsError`（显式失败态），**不伪造空列表**
///   （空列表会被读成「真的没有内容」）；数据源接入随后续批次。
/// · `usePresenceOnline`（自身光环跟随 WS 在线增量）属 presence 接线，本页用 `user.online`；
/// · **头像即时预览**（web `imageUrl={avatarPreview ?? currentUser.avatar}`，tsx 168）：
///   ✅ 2026-09-28 用户裁决后落地 —— [AylaProfileIdentity] 新增可选 `avatarOverride`
///   （`ImageProvider?`，**默认 null ⇒ 既有调用点行为不变**），本页传 `MemoryImage(本地字节)`；
///   与 web 的 `hint`（「新头像将在保存后生效」，tsx 202–204）并存，保存成功后换回真实 URL。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/auth_api.dart';
import '../core/app_init.dart';
import '../core/media/media_picker.dart';
import '../core/models/media_kind.dart';
import '../core/media/media_upload.dart';
import '../core/media/media_validation.dart';
import '../core/net/dio_client.dart';
import '../core/ws/ws_manager.dart';
import '../state/auth_state.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/base/privacy_sheet.dart';
import '../widgets/base/reveal.dart';
import '../widgets/base/profile_content_sections.dart';
import '../widgets/base/resource_image.dart' show mediaContentUrl;
import '../widgets/base/share.dart';
import '../widgets/motion/gestures.dart';
import '../widgets/profile/profile_card.dart';
import '../widgets/profile/profile_edit.dart';
import 'profile_support.dart';

/// 在线状态四档（web `STATUS_OPTIONS`，`ProfilePage.tsx:22–27`）。
const List<({String value, String label})> kAylaProfileStatusOptions =
    <({String value, String label})>[
  (value: 'auto', label: '自动'),
  (value: 'away', label: '离开'),
  (value: 'dnd', label: '勿扰'),
  (value: 'invisible', label: '隐身'),
];

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final TextEditingController _nickname = TextEditingController();
  final TextEditingController _signature = TextEditingController();

  String _status = 'auto';
  bool _showContent = false;
  bool _saving = false;
  bool _saved = false;
  String? _error;
  bool _privacyOpen = false;

  /// 已选新头像的字节（null = 未选）。web 用 File + objectURL 预览，Flutter 直接持字节。
  Uint8List? _avatarBytes;
  String? _avatarMime;
  String? _avatarError;

  /// 上一次同步的 userId（`useEffect([currentUser?.id])` 的等价物）。
  String? _syncedUserId;

  @override
  void initState() {
    super.initState();
    // 草稿文本一变就复位「已保存」（web 在 onChange 里 `setSaved(false)`）。
    // ⚠️ 必须挂在 controller 上：[AylaProfileForm] 内部的 TextField 不向外部
    // 暴露 onChanged，而 `dirty` 由本页按 controller 内容算 ⇒ 没有这层监听时
    // 改完文本不会 rebuild，「已保存」会错误地停在屏幕上（`saved && !dirty` 才显示）。
    _nickname.addListener(_onDraftChanged);
    _signature.addListener(_onDraftChanged);
  }

  void _onDraftChanged() {
    if (!mounted) return;
    // 无条件重建：`dirty` 是按 controller 内容在 build 里算的，文本一变就要重算
    // （web 的 onChange 同样是 setNickname + setSaved(false) 两次状态更新 ⇒ 必重建）。
    // 曾加过 `if (!_saved) return` 的守卫，结果首次编辑不触发重建、保存键一直禁用（实测）。
    setState(() => _saved = false);
  }

  @override
  void dispose() {
    _nickname.removeListener(_onDraftChanged);
    _signature.removeListener(_onDraftChanged);
    _nickname.dispose();
    _signature.dispose();
    super.dispose();
  }

  /// 账号切换时重置全部草稿（tsx 52–64）。
  void _syncFrom(AuthUser? user) {
    if (user == null || user.id == _syncedUserId) return;
    _syncedUserId = user.id;
    _nickname.text = user.nickname;
    _signature.text = user.signature;
    _status = user.status.isEmpty ? 'auto' : user.status;
    _showContent = user.showContent;
    _avatarBytes = null;
    _avatarMime = null;
    _avatarError = null;
    _error = null;
    _saved = false;
    _saving = false;
  }

  /// `dirty`（tsx 99–104）：任一草稿偏离账号值或选了新头像。
  bool _dirty(AuthUser user) {
    return _nickname.text != user.nickname ||
        _signature.text != user.signature ||
        _status != (user.status.isEmpty ? 'auto' : user.status) ||
        _showContent != user.showContent ||
        _avatarBytes != null;
  }

  /// `pickAvatar`（tsx 73–85）：本地校验失败**保留旧预览之外的一切**、只报错。
  Future<void> _pickAvatar() async {
    final AylaPickResult result =
        await AylaMediaPicker.pickImages(multiple: false);
    if (result.files.isEmpty) return;
    final AylaPickedFile file = result.files.first;
    final String? invalid = aylaValidateImageFile(
      mime: file.mimeType,
      size: file.size,
    );
    if (invalid != null) {
      setState(() => _avatarError = invalid);
      return;
    }
    final Uint8List bytes = await file.readBytes();
    if (!mounted) return;
    setState(() {
      _avatarError = null;
      _avatarBytes = bytes;
      _avatarMime = file.mimeType;
      _saved = false;
    });
  }

  void _logout() {
    wsManager?.disconnectAll();
    AppInit.instance.reset();
    ref.read(authNotifierProvider.notifier).clear();
  }

  /// `onSave`（tsx 106–144）：有本地新头像则**先三步上传**再 PATCH；
  /// 保存成功后**只归一化本次提交的草稿**（期间更新的编辑保持本地）。
  Future<void> _save(AuthUser user) async {
    if (_saving) return;
    final String submittedNickname = _nickname.text;
    final String submittedSignature = _signature.text;
    final String submittedStatus = _status;
    final bool submittedShowContent = _showContent;
    final Uint8List? submittedAvatar = _avatarBytes;
    setState(() {
      _saving = true;
      _error = null;
      _saved = false;
    });
    try {
      String? avatarUrl;
      if (submittedAvatar != null) {
        final AylaUploadResult uploaded =
            await AylaMediaUploader.instance.uploadBytes(
          bytes: submittedAvatar,
          kind: AylaMediaKind.image,
          mimeType: _avatarMime ?? 'image/png',
        );
        avatarUrl = mediaContentUrl(uploaded.mediaId);
      }
      final AuthUser updated = await AuthApi.updateProfile(
        nickname: submittedNickname.trim().isEmpty
            ? null
            : submittedNickname.trim(),
        signature: submittedSignature.trim(),
        status: submittedStatus,
        showContent: submittedShowContent,
        avatar: avatarUrl,
      );
      if (!mounted) return;
      ref.read(authNotifierProvider.notifier).setUser(updated);
      setState(() {
        // 只有「未被用户改动过」的字段才回填后端值（tsx 129–134）。
        if (_nickname.text == submittedNickname) {
          _nickname.text = updated.nickname;
        }
        if (_signature.text == submittedSignature) {
          _signature.text = updated.signature;
        }
        if (_status == submittedStatus) {
          _status = updated.status.isEmpty ? 'auto' : updated.status;
        }
        if (_showContent == submittedShowContent) {
          _showContent = updated.showContent;
        }
        if (identical(_avatarBytes, submittedAvatar)) {
          _avatarBytes = null;
          _avatarMime = null;
        }
        _avatarError = null;
        _saved = true;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err is ApiException ? err.message : '保存失败，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthUser? user = ref.watch(authNotifierProvider).user;
    final bool isNarrow =
        AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    _syncFrom(user);

    // tsx 87–97：没有用户在手上时只出「正在加载个人资料…」卡。
    if (user == null) {
      return AylaFullScreenSwipeBack(
        enabled: isNarrow,
        onBack: _back,
        child: Center(
          child: Text(
            '正在加载个人资料…',
            style: TextStyle(color: AylaColors.textSecondary),
          ),
        ),
      );
    }

    final String displayName = user.nickname.isEmpty ? user.username : user.nickname;
    // 两档装配（web：窄屏 `.profile-side` 是 `display: contents` ⇒ 单列自然流；
    // ≥769 是侧栏模式：卡片 `flex: 1 0 auto` 铺满 + `gap: sp6`，留白落在上半区与表单之间）。
    final List<Widget> upper = <Widget>[
        AylaProfileIdentity(
          displayName: displayName,
          username: user.username,
          avatarUrl: user.avatar.isEmpty ? null : user.avatar,
          // `avatarPreview ?? currentUser.avatar`（tsx 168）：选了新头像就先用本地字节
          // 即时预览（web 用 objectURL；Flutter 用 MemoryImage），保存成功后换回真实 URL。
          avatarOverride:
              _avatarBytes == null ? null : MemoryImage(_avatarBytes!),
          online: user.online,
          onBack: _back,
          share: AylaShareButton(
            label: '分享我的主页', // tsx 176
            size: 40, // `.icon-btn-40 profile-card-share`
            onPressed: () {}, // 分享面板接线属分享域批次（见文件头登记）
          ),
        ),
        AylaProfileAvatarActions(
          actions: <Widget>[
            AylaGlassButton(
              label: '更换头像', // tsx 180
              variant: AylaGlassButtonVariant.ghost,
              fontSize: 12, // `.profile-avatar-btn { font-size: 12px }`（profile.css 157）
              minHeight: 28,
              // `.profile-avatar-btn { padding: var(--sp-1) var(--sp-2) }`（profile.css 158）——
              // web 的「三按钮收窄」就靠这个 + gap sp1，保证文案不折行不省略。
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp2,
                vertical: AylaSpacing.sp1,
              ),
              // ⚠️ **不要** `expand: true`：`AylaProfileAvatarActions` 现在是 web 的
              // `flex-wrap` 语义（内容宽 + 可折行），expand 会让按钮在 Wrap 里撑满整行。
              onPressed: () => _pickAvatar(),
            ),
            AylaGlassButton(
              label: '隐私设置', // tsx 196
              variant: AylaGlassButtonVariant.ghost,
              fontSize: 12,
              minHeight: 28,
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp2,
                vertical: AylaSpacing.sp1,
              ),
              onPressed: () => setState(() => _privacyOpen = true),
            ),
            AylaGlassButton(
              label: '我的收藏', // tsx 200
              icon: AylaIcon(aylaIconByName('iconHeart')!, size: 15), // tsx 199
              variant: AylaGlassButtonVariant.ghost,
              fontSize: 12,
              minHeight: 28,
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp2,
                vertical: AylaSpacing.sp1,
              ),
              onPressed: () => context.go('/favorites'),
            ),
          ],
          // tsx 202–204：选了新头像才出现该提示。
          hint: _avatarBytes != null ? '新头像将在保存后生效' : null,
          error: _avatarError, // tsx 205–209 `role="alert"`
        ),
    ];
    final Widget form = AylaProfileForm(
          nicknameController: _nickname,
          signatureController: _signature,
          status: _status,
          onStatusChanged: (String v) => setState(() {
            _status = v;
            _saved = false;
          }),
          showContent: _showContent,
          onShowContentChanged: (bool v) => setState(() {
            _showContent = v;
            _saved = false;
          }),
          onSave: () => _save(user),
          onLogout: _logout,
          nicknamePlaceholder: user.username, // tsx 243
          saving: _saving,
          saved: _saved,
          dirty: _dirty(user),
          error: _error,
        );
    final Widget card = isNarrow
        ? AylaProfileCard(children: <Widget>[...upper, form])
        : AylaProfileCard(
            compact: true, // padding: sp4
            gap: AylaSpacing.sp6, // .profile-side .profile-card { gap: sp6 }
            fillHeight: true, // flex: 1 0 auto ⇒ 铺满 + 间隙自适应
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp6,
                children: upper,
              ),
              form,
            ],
          );
    final Widget sections = AylaProfileContentSections(
      displayName: displayName,
      mine: true,
      // ⚠️ 显式失败态而不是空列表：数据源属后续批次（见文件头登记），
      // 传空列表会被读成「真的没有内容」。
      postsError: '内容分区（我的发帖 / 直播间 / 桌游）的数据源属后续批次',
    );

    return AylaFullScreenSwipeBack(
      enabled: isNarrow,
      onBack: _back,
      child: Stack(
        children: <Widget>[
          isNarrow
              // ≤768：`.profile-side` / `.profile-main` 均 `display: contents` ⇒ 单列自然流
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(AylaSpacing.sp3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: AylaSpacing.sp4,
                    children: <Widget>[card, sections],
                  ),
                )
              // ≥769：`.profile-page-split:has(.profile-main)` 的**侧栏模式**
              // （profile.css:57–113）—— 页面根 height 100% + flex column + overflow hidden；
              // 中间层 flex row + align-items stretch；侧栏 align-self stretch + 自滚动 +
              // 底部呼吸，内容区 flex:1 独立滚动。**两列各自滚动，页面根不滚**。
              : Padding(
                  // padding: var(--sp-3) var(--sp-3) 0
                  padding: const EdgeInsets.only(
                    top: AylaSpacing.sp3,
                    left: AylaSpacing.sp3,
                    right: AylaSpacing.sp3,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints c) {
                            // 侧栏宽 `clamp(280px, 32%, 340px)`（flex: 0 0 同值）
                            final double sideWidth =
                                (c.maxWidth * 0.32).clamp(280.0, 340.0);
                            return Row(
                              // align-items: stretch ⇒ 两列等高
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: AylaSpacing.sp3, // gap: var(--sp-3)
                              children: <Widget>[
                                // 两列各有面板入场动画（web `auroraqua.css:323–332`，位于
                                // `@media (min-width: 769px)` 内）：
                                //   `.… > .profile-side` → `auroraqua-sidebar-in`（**左入 −20**）
                                //   `.… > .profile-main` → `auroraqua-panel-from-right`（**右入 +20**）
                                // 正是 `/profile` 在 web 上的真实观感：整页 panelOwned（不位移），
                                // 但两列各自沿方向滑入。
                                AylaRevealItem(
                                  offset: const Offset(-20, 0),
                                  duration: AylaDurations.auroraqua,
                                  curve: AylaCurves.auroraquaEaseOut,
                                  child: SizedBox(
                                    width: sideWidth,
                                    // 侧栏：铺满可用高度 + 自滚动 + 底部呼吸（flex: 1 0 auto）
                                    child: aylaProfileSidebarScroll(
                                      availableHeight: c.maxHeight,
                                      child: card,
                                    ),
                                  ),
                                ),
                                // ⚠️ `Expanded` 必须在**外层**：它是 Flex 的 parent-data widget，
                                // 只能直接挂在 Row 下；包进 `AylaRevealItem` 内部会断言失败
                                // （`RenderBox was not laid out` / Expanded 找不到 Flex 祖先）。
                                Expanded(
                                  child: AylaRevealItem(
                                    offset: const Offset(20, 0),
                                    duration: AylaDurations.auroraqua,
                                    curve: AylaCurves.auroraquaEaseOut,
                                    // 内容区：flex:1 独立滚动 + 阴影绘制带
                                    child: aylaProfileMainScroll(sections),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
          // `createPortal(document.body)` 的等价物：弹层挂在页面最外层 Stack
          if (_privacyOpen)
            AylaPrivacySheet(
              onClose: () => setState(() => _privacyOpen = false),
              boundEmail: user.email,
            ),
        ],
      ),
    );
  }

  /// `navigate(-1)`（tsx 149/158）：栈底时回主页，避免 pop 断言。
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }
}