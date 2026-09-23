/// ShareSheet / ShareButton —— 分享弹窗与分享入口（B5 分享族）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
///
/// - `components/share/ShareSheet.tsx`：结构、状态机、关闭语义、发送契约；
/// - `styles/share.css` 1–275：全部盒模型/材质/状态；
///   **auroraqua.css 无 `.share-sheet-*` 覆写**（已 grep 全量确认，只有注释里的
///   英文单词 share，无选择器命中）；
/// - `components/share/ShareButton.tsx`：入口按钮 = `icon-btn-40` + IconShare 18，
///   语义 = `aria-label=label` + `title=label`；
/// - `styles/home.css` 121–134 + `auroraqua.css` 125–139：`.icon-btn-40` 本体
///   （40×40 / pill / glass 底 / 1px 边框 / button 阴影 / blur(8) 无 saturate）；
/// - `core/models/share_payload.dart` + `utils/sharePayload.ts`：负载契约。
///
/// ## 展示型组件（注入契约）
///
/// 群/私信列表分页、子群加载、发送全部由调用方注入（对齐 B5 既有模式：
/// `AylaPostCard.onShare` / `AylaFavoriteButton.state+onToggle`）——本批不接线
/// 聊天域 API，页面批次落地时把 `useSocialPage` / `listSubgroups` / `sendMessage`
/// 接到这些回调上。
///
/// 弹层挂载：本组件返回**全屏遮罩 + 卡片**（与 `AylaModalOverlay` 同族），
/// 调用方需把 [AylaShareSheet] 放在页面最外层的 `Stack` 之上（web 用 createPortal
/// 挂 document.body 规避父级 backdrop-filter 的 stacking context 裁剪）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/share_payload.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'dialogs.dart';
import 'directory_controls.dart';
import 'loading.dart';
import 'primitives.dart';
import 'tab_badge.dart';

/// 分享目标类型选项卡（web `tab: `group` | `private``）。
enum AylaShareTab {
  /// 群聊（我加入的群，含未读数；子群 > 1 时展开选择）。
  group,

  /// 私信（私聊会话，含自己）。
  private,
}

/// 子群（web `SubGroup` 在分享弹窗用到的字段：id/name/is_default）。
class AylaShareSubGroup {
  const AylaShareSubGroup({
    required this.id,
    required this.name,
    this.isDefault = false,
  });

  /// 子群 id（web 是字符串；发送时 `Number(sg.id)` → [AylaShareSendRequest.subgroupId]）。
  final String id;

  /// 子群名。
  final String name;

  /// 是否默认组（渲染「默认」胶囊；仅 1 个子群时该群直接发送，不展开）。
  final bool isDefault;
}

/// 分享目标会话（web `ConversationSummary` 在分享弹窗用到的字段）。
class AylaShareTarget {
  const AylaShareTarget({
    required this.id,
    required this.title,
    this.avatarUrl,
    this.unreadCount = 0,
    this.peerId,
    this.peerNickname,
    this.peerUsername,
    this.peerAvatarUrl,
  });

  /// 会话 id。
  final String id;

  /// 会话标题；私聊的展示名优先取 peer 昵称/用户名（见 [displayName]）。
  final String title;

  /// 群头像（web 群行 `conv.avatar`）。
  final String? avatarUrl;

  /// 本人视角未读数（> 0 显示徽标，> 99 显示 99+）。
  final int unreadCount;

  /// 私聊对端用户 id（与 [currentUserId] 相同 → 展示「我」）。
  final String? peerId;

  /// 私聊对端昵称。
  final String? peerNickname;

  /// 私聊对端用户名（昵称为空时的回退）。
  final String? peerUsername;

  /// 私聊对端头像（web 私聊行 `conv.peer?.avatar`）。
  final String? peerAvatarUrl;

  /// 私聊展示名（web `privateTitle`）：`peer.nickname || peer.username ||
  /// conv.title || 私聊`；对端是自己时显示「我」。
  String privateDisplayName(String? currentUserId) {
    if (peerId != null && currentUserId != null && peerId == currentUserId) {
      return '我';
    }
    final String nickname = (peerNickname ?? '').trim();
    if (nickname.isNotEmpty) return nickname;
    final String username = (peerUsername ?? '').trim();
    if (username.isNotEmpty) return username;
    final String convTitle = title.trim();
    if (convTitle.isNotEmpty) return convTitle;
    return '私聊';
  }
}

/// 一页分享目标（web `useSocialPage(...)` 投影：items + 分页状态 + 操作）。
class AylaShareTargetPage {
  const AylaShareTargetPage({
    required this.items,
    required this.loading,
    required this.hasMore,
    required this.loadMore,
    required this.refresh,
    this.error,
    this.invalidated = false,
  });

  /// 当前页条目。
  final List<AylaShareTarget> items;

  /// 是否加载中。
  final bool loading;

  /// 是否还有更多。
  final bool hasMore;

  /// 加载更多。
  final Future<void> Function() loadMore;

  /// 重新拉取（错误态「重试」与 invalidated 自动刷新都用它）。
  final Future<void> Function() refresh;

  /// 错误文案（非 null 时列表区显示错误态）。
  final String? error;

  /// 数据在加载过程中被更新（交给 [AylaDirectoryLoadMore] 自动刷新）。
  final bool invalidated;
}

/// 一次分享发送请求（web `sendMessage(convId, { type, content, share_payload, subgroup_id })`）。
class AylaShareSendRequest {
  const AylaShareSendRequest({
    required this.conversationId,
    required this.subgroupId,
    required this.content,
    required this.payload,
  });

  /// 目标会话 id。
  final String conversationId;

  /// 目标子群 id（null = 不传，走默认组；web `Number(sg.id)` 非数字时为 undefined）。
  final int? subgroupId;

  /// 消息正文（web：`[分享]${payload.title || 目标名}`）。
  final String content;

  /// 分享负载（原样写入 `share_payload`）。
  final AylaSharePayload payload;
}

/// 分享弹窗（web `ShareSheet.tsx` + share.css）。
class AylaShareSheet extends StatefulWidget {
  const AylaShareSheet({
    super.key,
    required this.payload,
    required this.groups,
    required this.privates,
    required this.onClose,
    this.currentUserId,
    this.onLoadSubgroups,
    this.onSend,
    this.initialTab = AylaShareTab.group,
  });

  /// 要分享的内容（顶部预览条 + 发送的 share_payload）。
  final AylaSharePayload payload;

  /// 群聊列表页。
  final AylaShareTargetPage groups;

  /// 私信列表页。
  final AylaShareTargetPage privates;

  /// 请求关闭（ESC / 关闭按钮 / 点遮罩 / 发送成功）。
  final VoidCallback onClose;

  /// 当前用户 id（私聊行判定「我」）。
  final String? currentUserId;

  /// 惰性加载某群子群（web `chatApi.listSubgroups`）。
  /// null = 不查子群，点群项按「仅默认组」直接发送。
  final Future<List<AylaShareSubGroup>> Function(String conversationId)? onLoadSubgroups;

  /// 发送分享（web `chatApi.sendMessage`）；抛错 = 展示错误且不关闭。
  /// null = 目标行不可点（禁用态）。
  final Future<void> Function(AylaShareSendRequest request)? onSend;

  /// 初始选项卡（web 固定 group）。
  final AylaShareTab initialTab;

  /// 宽屏卡片最大高度（web `max-height: min(80vh, 720px)`）。
  static const double wideMaxHeight = 720;

  /// 窄屏卡片高度（web `.is-narrow { height: 60dvh }`）。
  static const double narrowHeightFactor = 0.6;

  @override
  State<AylaShareSheet> createState() => _AylaShareSheetState();
}

class _AylaShareSheetState extends State<AylaShareSheet> {
  late AylaShareTab _tab = widget.initialTab;

  /// 展开的群 id（null = 无展开）。
  String? _expandedConvId;

  /// 展开群的子群（null = 加载中，与 web `expanded.subgroups === null` 同义）。
  List<AylaShareSubGroup>? _expandedSubgroups;

  bool _subLoading = false;
  bool _sending = false;
  String? _error;

  /// 已关闭（web `closedRef`：防止重复 onClose）。
  bool _closed = false;

  void _close() {
    if (_closed) return;
    _closed = true;
    widget.onClose();
  }

  /// web `toggleSubgroups(convId, expandedNow)`：已展开 → 收起。
  void _collapse() {
    setState(() {
      _expandedConvId = null;
      _expandedSubgroups = null;
    });
  }

  /// 点群项（web `onGroupClick`）：子群 > 1 → 展开；否则直接发送。
  Future<void> _onGroupTap(AylaShareTarget conv) async {
    if (_expandedConvId == conv.id) {
      _collapse();
      return;
    }
    setState(() {
      _expandedConvId = null;
      _expandedSubgroups = null;
      _error = null;
      _subLoading = true;
    });
    try {
      final Future<List<AylaShareSubGroup>> Function(String)? loader =
          widget.onLoadSubgroups;
      final List<AylaShareSubGroup> subs = loader == null
          ? const <AylaShareSubGroup>[]
          : await loader(conv.id);
      if (!mounted || _closed) return;
      if (subs.length > 1) {
        setState(() {
          _expandedConvId = conv.id;
          _expandedSubgroups = subs;
        });
      } else {
        await _send(conv.id, null, conv.title);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error, fallback: '发送失败'));
    } finally {
      if (mounted) setState(() => _subLoading = false);
    }
  }

  /// 发送（web `pickSubgroup`）：成功即关闭，失败留在弹窗并展示错误。
  Future<void> _send(String convId, int? subgroupId, String title) async {
    final Future<void> Function(AylaShareSendRequest)? sender = widget.onSend;
    if (_sending || _closed || sender == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final String head = widget.payload.title.isNotEmpty
          ? widget.payload.title
          : title;
      await sender(AylaShareSendRequest(
        conversationId: convId,
        subgroupId: subgroupId,
        content: '[分享]$head',
        payload: widget.payload,
      ));
      _close();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error, fallback: '发送失败'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool get _busy => _sending || _subLoading;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final Size viewport = MediaQuery.of(context).size;
    final bool narrow = viewport.width <= 768; // 与 AylaModalCard 同一断点
    final AylaShareTargetPage page =
        _tab == AylaShareTab.group ? widget.groups : widget.privates;

    return Shortcuts(
      // web `keydown` ESC → close()
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (DismissIntent intent) {
              _close();
              return null;
            },
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: AylaModalOverlay(
            // web `onClick={close}`（遮罩点击总是关闭，sending 不阻断）
            onDismiss: _close,
            padding: 24, // web `.share-sheet-overlay { padding: 24px }`
            child: AylaModalCard(
              // web `max-height: min(80vh, 720px)`
              maxHeight: math.min(viewport.height * 0.8, AylaShareSheet.wideMaxHeight),
              // 窄屏 `.is-narrow`：height 60dvh、radius-panel 上下、去左右下边框
              narrowHeightFactor: AylaShareSheet.narrowHeightFactor,
              narrowRadius: AylaRadii.rPanel,
              scrollable: false, // `.share-sheet-card { overflow: hidden }`
              wideEntrance: true, // framer-motion initial→animate（250ms ease-out）
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _head(t),
                  _preview(t),
                  _tabs(),
                  // web `.share-sheet-body { flex: 1; min-height: 0 }`：
                  // · 窄屏卡片是**固定 60dvh**（`.is-narrow { height: 60dvh }`）→
                  //   剩余空间必须由 body 拿走（tight）：空列表时的留白归属 body
                  //   （可滚动区），与 web 一致，而不是掉在卡片尾部；
                  // · 宽屏卡片高度由内容决定（只受 max-height 约束）→ 必须 loose，
                  //   否则内容少时也会被撑到 max-height（720）。
                  if (narrow)
                    Expanded(child: _body(t, page))
                  else
                    Flexible(fit: FlexFit.loose, child: _body(t, page)),
                  if (_error != null) _errorBar(t),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.share-sheet-head`：padding sp4、底部 1px glass-border、两端对齐。
  Widget _head(AylaTextStyles t) {
    return Container(
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AylaColors.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          // `.share-sheet-title`：inline-flex / gap 8 / font-display 20/500 / text-primary
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AylaIcon(aylaIconByName('iconShare')!, size: 18),
              const SizedBox(width: 8),
              Text('分享', style: t.cardTitle),
            ],
          ),
          // `<button className=`icon-btn-40` aria-label=`关闭`>`（pill 玻璃圆钮）
          AylaIconButton(
            icon: AylaIcon(aylaIconByName('iconClose')!, size: 18),
            onPressed: _close,
            semanticLabel: '关闭',
          ),
        ],
      ),
    );
  }

  /// `.share-sheet-preview`：本次分享内容摘要（封面/类型/标题）。
  Widget _preview(AylaTextStyles t) {
    final String title =
        widget.payload.title.isNotEmpty ? widget.payload.title : '分享';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: GlassConfig.resolveBackground(strong: false), // --glass-bg
            borderRadius: BorderRadius.circular(AylaRadii.rInput),
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // `.share-sheet-preview-icon`：28 圆 + 135deg ice-300→sakura-300
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: cssLinearGradient(
                    angleDeg: 135,
                    colors: const <Color>[AylaColors.ice300, AylaColors.sakura300],
                  ), // 正圆 → 归一化端点与 CSS 等价（无需 aspectRatio）
                ),
                child: Center(
                  child: AylaIcon(aylaIconByName('iconShare')!, size: 16),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis, // white-space: nowrap + ellipsis
                  style: t.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选项卡 —— **复用组件库** [AylaSegmentedTabs]。
  ///
  /// **2026-09-20 用户指定**：分享弹窗与消息中心统一使用**默认档**（共享滑动胶囊 +
  /// 容器 radius-card + 仅内高光）——即画布「Batch 2 基元」里那一件。
  ///
  /// `AylaSegmentedTabsVariant.shareSheet` 保留为 web `.share-sheet-tabs` 原版规格
  /// （share.css 63–91：静态选中底 / 项 radius 10 / 容器 radius-input + `--glass-bg`），
  /// 需要严格贴 web 时改传该档即可（一行切换）。
  Widget _tabs() {
    return AylaSegmentedTabs(
      labels: const <String>['群聊', '私信'],
      index: _tab == AylaShareTab.group ? 0 : 1,
      semanticLabel: '分享目标类型', // web `role="tablist" aria-label="分享目标类型"`
      onChanged: (int i) => setState(() {
        _tab = i == 0 ? AylaShareTab.group : AylaShareTab.private;
      }),
    );
  }

  /// `.share-sheet-body { flex:1; min-height:0; overflow-y:auto; padding:4px 12px 12px }`。
  Widget _body(AylaTextStyles t, AylaShareTargetPage page) {
    final List<Widget> rows = <Widget>[];
    if (page.loading) {
      // web: `share-sheet-state` + `loading-spinner loading-spinner--md`（18px）
      rows.add(_ShareStateBox(t, spinner: true, text: '加载中…'));
    } else if (page.error != null) {
      rows.add(_ShareStateBox(
        t,
        errorText: '加载失败：${page.error}',
        onRetry: page.refresh,
      ));
    } else if (page.items.isEmpty) {
      rows.add(_ShareStateBox(
        t,
        text: '暂无${_tab == AylaShareTab.group ? '群聊' : '私信'}',
      ));
    } else {
      for (final AylaShareTarget conv in page.items) {
        rows.add(_tab == AylaShareTab.group
            ? _groupItem(t, conv)
            : _privateItem(t, conv));
      }
    }
    rows.add(
      AylaDirectoryLoadMore(
        loading: page.loading,
        error: page.error,
        hasMore: page.hasMore,
        invalidated: page.invalidated,
        loadMore: page.loadMore,
        refresh: page.refresh,
        retainCompletedSpace: false, // `<DirectoryLoadMore ... retainCompletedSpace={false}>`
      ),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  /// 群项（web `renderGroupItem`）：头像 32 + 标题 + 未读 + 展开箭头/子群列表。
  Widget _groupItem(AylaTextStyles t, AylaShareTarget conv) {
    final bool isOpen = _expandedConvId == conv.id;
    final List<AylaShareSubGroup>? subs = isOpen ? _expandedSubgroups : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ShareRow(
          enabled: !_busy && widget.onSend != null,
          onTap: () => _onGroupTap(conv),
          semanticLabel: '分享到群聊 ${conv.title}',
          child: Row(
            children: <Widget>[
              _rowAvatar(conv.avatarUrl, conv.title),
              const SizedBox(width: 12), // gap 12
              Expanded(
                child: _rowMain(t, conv.title, conv.unreadCount),
              ),
              // isOpen ? IconChevronDown : IconChevronRight（16px）
              AylaIcon(
                isOpen
                    ? aylaIconByName('iconChevronDown')!
                    : aylaIconByName('iconChevronRight')!,
                size: 16,
              ),
            ],
          ),
        ),
        if (isOpen)
          Padding(
            // `.share-sheet-subgroups { padding: 0 0 0 52px; margin: 0 0 4px }`
            padding: const EdgeInsets.only(left: 52, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (subs != null)
                  for (final AylaShareSubGroup sg in subs)
                    _ShareRow(
                      enabled: !_sending && widget.onSend != null,
                      minHeight: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      onTap: () => _send(
                        conv.id,
                        int.tryParse(sg.id), // web `Number(sg.id)`
                        '${conv.title} · ${sg.name}',
                      ),
                      semanticLabel: '分享到 ${conv.title} 的 ${sg.name}',
                      child: Row(
                        children: <Widget>[
                          // `.share-sheet-subgroup-dot`：8px ice-500 圆
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AylaColors.ice500,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10), // gap 10
                          Flexible(child: _rowTitle(t, sg.name)),
                          if (sg.isDefault) ...<Widget>[
                            const SizedBox(width: 10),
                            // `.share-sheet-subgroup-tag`：sakura-300 底 + grape-700 字 + display 11/500
                            AylaCapsuleTag(
                              '默认',
                              tone: CapsuleTone.sakura,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              fontSize: 11,
                              letterSpacing: 0, // web 未声明 → normal
                              textHeight: 1.55, // 继承 body line-height
                            ),
                          ],
                        ],
                      ),
                    ),
                if (subs != null && subs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '该群暂无子群',
                      style: t.body.copyWith(
                        fontSize: 13,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 私聊项（web `renderPrivateItem`）：显示名 = 对端昵称/用户名/标题/私聊，自己显示「我」。
  Widget _privateItem(AylaTextStyles t, AylaShareTarget conv) {
    final String name = conv.privateDisplayName(widget.currentUserId);
    return _ShareRow(
      enabled: !_sending && widget.onSend != null,
      onTap: () => _send(conv.id, null, name),
      semanticLabel: '分享给 $name',
      child: Row(
        children: <Widget>[
          _rowAvatar(conv.peerAvatarUrl, name),
          const SizedBox(width: 12),
          Expanded(child: _rowMain(t, name, conv.unreadCount)),
        ],
      ),
    );
  }

  /// 行头像（web `<Avatar size={32}>`；分享列表不传 online → 离线灰环）。
  Widget _rowAvatar(String? url, String label) {
    return AvatarHalo(label: label, size: 32, resourceUrl: url);
  }

  /// `.share-sheet-row-main`：flex1 + min-width0 + gap 8（标题可省略，未读紧随）。
  Widget _rowMain(AylaTextStyles t, String title, int unread) {
    return Row(
      children: <Widget>[
        Flexible(child: _rowTitle(t, title)),
        if (unread > 0) ...<Widget>[
          const SizedBox(width: 8),
          // `.share-sheet-unread`：18 高 / pink-500 底 / #fff 字 / 99+ 封顶
          TabBadge(
            count: unread,
            max: 99,
            metrics: TabBadgeMetrics.shareUnread,
            placement: TabBadgePlacement.inline,
            foregroundColor: Colors.white,
          ),
        ],
      ],
    );
  }

  /// `.share-sheet-row-title`：15/600 + text-primary + 单行省略。
  Widget _rowTitle(AylaTextStyles t, String title) {
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.body.copyWith(fontWeight: FontWeight.w600),
    );
  }

  /// `.share-sheet-error`：底部错误条（margin 0 12 12 / 10×12 / radius 12 / destructive）。
  Widget _errorBar(AylaTextStyles t) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AylaColors.destructive.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AylaColors.destructive.withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        _error!,
        style: t.body.copyWith(
          fontSize: 13,
          color: AylaColors.destructive,
        ),
      ),
    );
  }
}

/// 错误文案（web：`e instanceof Error ? e.message : fallback`）。
String _message(Object error, {required String fallback}) {
  if (error is Exception) {
    final String text = error.toString();
    // Dart 的 `Exception: xxx` 前缀不是 web 的 message，剥掉后再判空。
    final String stripped = text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
    return stripped.isNotEmpty ? stripped : fallback;
  }
  final String text = error.toString();
  return text.isNotEmpty ? text : fallback;
}

/// 分享目标行（`.share-sheet-row` / `.share-sheet-subgroup` 共用壳）。
///
/// 交互事实源：`transition: background 200ms ease, transform 200ms ease`；
/// `:hover` → `rgba(157,191,230,.18)`；`:active` → `scale(.98)`；
/// `:disabled` → `opacity .6` + `cursor: default`。
/// 注意：**不在 auroraqua 按钮组列表**里 → 无 hover 放大、无扫光。
class _ShareRow extends StatefulWidget {
  const _ShareRow({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.enabled = true,
    this.minHeight = 48,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
  });

  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  final bool enabled;
  final double minHeight;
  final EdgeInsets padding;

  @override
  State<_ShareRow> createState() => _ShareRowState();
}

class _ShareRowState extends State<_ShareRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 零透明必须用**同色相**（ice500 alpha 0）：`Colors.transparent` 是透明黑，
    // Color.lerp 逐通道插值时中途会变成中性灰（本项目 2026-09-19 事故）。
    final Color background = _hovered && widget.enabled
        ? AylaColors.ice500.withValues(alpha: 0.18)
        : AylaColors.ice500.withValues(alpha: 0);
    return AylaPressScale(
      onTap: widget.enabled ? widget.onTap : null,
      enabled: widget.enabled,
      semanticLabel: widget.semanticLabel,
      hoverScale: false, // 非按钮组：只有 :active scale(.98)
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.6, // :disabled { opacity: .6 }
          child: AnimatedContainer(
            duration: AylaDurations.button, // 200ms
            curve: AylaCurves.auroraqua, // CSS `ease`
            constraints: BoxConstraints(minHeight: widget.minHeight),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12), // border-radius: 12px
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// `.share-sheet-state`：加载/错误/空三态（min-height 120 / 居中 / gap 10 / 14 次要色）。
class _ShareStateBox extends StatelessWidget {
  const _ShareStateBox(
    this.t, {
    this.spinner = false,
    this.text,
    this.errorText,
    this.onRetry,
  });

  final AylaTextStyles t;
  final bool spinner;
  final String? text;
  final String? errorText;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 120),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (spinner) ...<Widget>[
            const LoadingSpinner(), // `loading-spinner loading-spinner--md` = 18px
            const SizedBox(height: 10), // gap 10
          ],
          if (text != null)
            Text(
              text!,
              style: t.body.copyWith(
                fontSize: 14,
                color: AylaColors.textSecondary,
              ),
            ),
          if (errorText != null)
            Text(
              errorText!,
              textAlign: TextAlign.center,
              style: t.body.copyWith(
                fontSize: 14,
                color: AylaColors.destructive, // `.share-sheet-error-text`
              ),
            ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 10),
            GlassButton(
              label: '重试',
              variant: GlassButtonVariant.ghost, // `.btn.btn-ghost`
              onPressed: () => onRetry!(),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分享入口按钮（web `ShareButton.tsx`：`icon-btn-40` + IconShare 18）。
///
/// web 版本内部持有 open 状态并 portal 出 [AylaShareSheet]；Flutter 侧按 B5
/// 「展示型 + 注入」模式只提供入口按钮（[onPressed] 由页面打开弹窗，与
/// `AylaPostCard.onShare` 同一模式）——弹层需要分页数据与发送回调注入，
/// 不适合由按钮自持。
class AylaShareButton extends StatelessWidget {
  const AylaShareButton({
    super.key,
    this.label = '分享',
    this.onPressed,
    this.size = 32,
  });

  /// 可访问性文案（web `aria-label={label} title={label}`）。
  final String label;

  /// 点击回调（页面打开 [AylaShareSheet]）；null = 禁用。
  final VoidCallback? onPressed;

  /// 边长。**默认 32 = 与收藏键 compact 同尺寸**。
  ///
  /// 用户 2026-09-22 裁决：web 把收藏键做成 `.favorite-toggle.is-compact`（**32×32**）、
  /// 转发键做成 `.icon-btn-40`（**40×40**），两者在帖子卡底排与各房头部**同排却不等大**
  /// —— 判为错误 ⇒ Flutter 侧统一取收藏键的 32（图标随之降到 16，与收藏键 compact 的
  /// 16px 图标一致）；确实需要复刻 web 40 档的地方显式传 `size: 40`。
  final double size;

  @override
  Widget build(BuildContext context) {
    return AylaIconButton(
      // web `IconShare 18`（40 档）；32 档取 16 与收藏键 compact 对齐
      icon: AylaIcon(aylaIconByName('iconShare')!, size: size >= 40 ? 18 : 16),
      onPressed: onPressed,
      size: size,
      semanticLabel: label,
    );
  }
}

// ======================= 预览 =======================

/// 宽屏（1440×900）：中央 480 卡 + 群聊 tab（含未读数）。
@Preview(
  group: 'Widgets',
  name: 'ShareSheet 宽屏 / 群聊',
  size: Size(1440, 900),
  wrapper: previewTheme,
)
Widget shareSheetWidePreview() {
  return AylaShareSheet(
    payload: const AylaSharePayload(
      shareType: AylaShareType.live,
      targetId: 'lc9',
      title: '爱莉的直播间',
    ),
    groups: _demoGroups(),
    privates: _demoPrivates(),
    currentUserId: 'u-me',
    onClose: () {},
  );
}

/// 宽屏 + 私信 tab（验证对端名回退链与「我」）。
@Preview(
  group: 'Widgets',
  name: 'ShareSheet 宽屏 / 私信',
  size: Size(1440, 900),
  wrapper: previewTheme,
)
Widget shareSheetPrivatePreview() {
  return AylaShareSheet(
    payload: const AylaSharePayload(
      shareType: AylaShareType.post,
      targetId: '42',
      title: '周末的雪山行记',
    ),
    groups: _demoGroups(),
    privates: _demoPrivates(),
    currentUserId: 'u-me',
    initialTab: AylaShareTab.private,
    onClose: () {},
  );
}

/// 窄屏（375×812）：60dvh 下半屏弹窗。
@Preview(
  group: 'Widgets',
  name: 'ShareSheet 窄屏 375',
  size: Size(375, 812),
  wrapper: previewTheme,
)
Widget shareSheetNarrowPreview() {
  return AylaShareSheet(
    payload: const AylaSharePayload(
      shareType: AylaShareType.group,
      targetId: 'g1',
      title: '技术群',
    ),
    groups: _demoGroups(),
    privates: _demoPrivates(),
    currentUserId: 'u-me',
    onClose: () {},
  );
}

/// 加载失败态（列表区错误 + 重试按钮）。
@Preview(
  group: 'Widgets',
  name: 'ShareSheet 错误态',
  size: Size(1440, 900),
  wrapper: previewTheme,
)
Widget shareSheetErrorPreview() {
  return AylaShareSheet(
    payload: const AylaSharePayload(
      shareType: AylaShareType.user,
      targetId: 'u-1',
      title: '爱莉',
    ),
    groups: _demoGroups(error: '网络不可用'),
    privates: _demoPrivates(),
    currentUserId: 'u-me',
    onClose: () {},
  );
}

/// 分享入口按钮（40px pill 玻璃圆钮；web `.icon-btn-40`）。
@Preview(
  group: 'Widgets',
  name: 'ShareButton',
  size: Size(200, 120),
  wrapper: previewTheme,
)
Widget shareButtonPreview() {
  return const Padding(
    padding: EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        AylaShareButton(),
        AylaShareButton(onPressed: null),
      ],
    ),
  );
}

/// 预览/画布演示：群聊列表（含未读、超长标题）。
AylaShareTargetPage _demoGroups({String? error}) {
  return AylaShareTargetPage(
    items: const <AylaShareTarget>[
      AylaShareTarget(id: 'g1', title: '技术群', unreadCount: 3),
      AylaShareTarget(id: 'g2', title: '爱莉之家'),
      AylaShareTarget(
        id: 'g3',
        title: '一个非常长的群聊名称用于验证标题省略号行为',
        unreadCount: 128,
      ),
    ],
    loading: false,
    hasMore: false,
    error: error,
    loadMore: _noop,
    refresh: _noop,
  );
}

/// 预览/画布演示：私信列表（昵称 / 用户名回退 / 自己）。
AylaShareTargetPage _demoPrivates() {
  return AylaShareTargetPage(
    items: const <AylaShareTarget>[
      AylaShareTarget(
        id: 'p1',
        title: '私聊',
        peerId: 'u-2',
        peerNickname: '小汐',
        peerUsername: 'xiaoxi',
      ),
      AylaShareTarget(
        id: 'p2',
        title: '私聊',
        peerId: 'u-3',
        peerUsername: 'no-nickname',
        unreadCount: 2,
      ),
      AylaShareTarget(id: 'p3', title: '我自己', peerId: 'u-me'),
    ],
    loading: false,
    hasMore: false,
    loadMore: _noop,
    refresh: _noop,
  );
}

Future<void> _noop() async {}

// ======================= 组件画布样张 =======================

/// 组件画布样张（`lib/preview/component_gallery.dart` 调用）。
///
/// 排布纪律（对齐既有 samples）：真实尺寸、不缩放；弹窗类组件用固定舞台
/// 限定遮罩范围（否则 [AylaModalOverlay] 会盖住整张画布）。
Widget aylaShareSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Wrap(
        spacing: AylaSpacing.sp6,
        runSpacing: AylaSpacing.sp6,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: <Widget>[
          _shareStage(
            size: const Size(1100, 560),
            label: '宽屏 1440 形态（中央 min(480,100%) 卡）· 群聊 tab · 点击群项可展开子群（交互）',
            child: _shareSheetDemo(),
          ),
          _shareStage(
            size: const Size(375, 812),
            label: '窄屏 375 形态（60dvh 下半屏 + 上滑 250ms）· 私信 tab',
            child: _shareSheetDemo(initialTab: AylaShareTab.private, currentUserId: 'u-me'),
          ),
        ],
      ),
      const SizedBox(height: AylaSpacing.sp6),
      Wrap(
        spacing: AylaSpacing.sp6,
        runSpacing: AylaSpacing.sp6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _shareSlot('ShareButton（icon-btn-40 pill + IconShare 18）', AylaShareButton(onPressed: () {})),
          _shareSlot('ShareButton 禁用（onPressed: null → opacity .55）', const AylaShareButton(onPressed: null)),
        ],
      ),
    ],
  );
}

/// 弹窗舞台：固定视口尺寸（MediaQuery 覆写）限定遮罩与断点形态。
Widget _shareStage({
  required Size size,
  required String label,
  required Widget child,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(
        label,
        style: AylaTextStyles.light.timestamp.copyWith(
          color: AylaColors.textSecondary,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp2),
      SizedBox(
        width: size.width,
        height: size.height,
        child: Builder(
          builder: (BuildContext context) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
              // ⚠️ 必须 `copyWith`：凭空 `MediaQueryData(size:)` 会丢掉真实环境的
              // textScaler / padding / gestureSettings 等字段，web 的滚动条与手势
              // 路径会读到它们（本项在 web 预览里出现过运行期报错，2026-09-20）。
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(size: size),
                child: child,
              ),
            );
          },
        ),
      ),
    ],
  );
}

/// 按钮样张槽（标签 + 组件）。
Widget _shareSlot(String label, Widget child) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(
        label,
        style: AylaTextStyles.light.timestamp.copyWith(
          color: AylaColors.textSecondary,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp2),
      child,
    ],
  );
}

/// 画布/预览用弹窗实例（提供可点的 demo 回调）。
Widget _shareSheetDemo({
  AylaShareTab initialTab = AylaShareTab.group,
  String? currentUserId,
}) {
  return AylaShareSheet(
    payload: const AylaSharePayload(
      shareType: AylaShareType.live,
      targetId: 'lc9',
      title: '爱莉的直播间',
    ),
    groups: _demoGroups(),
    privates: _demoPrivates(),
    currentUserId: currentUserId,
    initialTab: initialTab,
    onLoadSubgroups: _demoLoadSubgroups,
    onSend: _demoSend,
    onClose: () {},
  );
}

Future<List<AylaShareSubGroup>> _demoLoadSubgroups(String conversationId) async {
  return const <AylaShareSubGroup>[
    AylaShareSubGroup(id: '11', name: '默认组', isDefault: true),
    AylaShareSubGroup(id: '12', name: '闲聊'),
  ];
}

Future<void> _demoSend(AylaShareSendRequest request) async {}
