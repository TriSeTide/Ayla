/// 群聊 @ 成员选择器（`components/chat/MentionPicker.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMentionPicker] | `MentionPicker.tsx:119–148`（浮层内容） |
/// | [AylaMentionPickerHost] | tsx 149 `createPortal(picker, document.body)` + 定位（57–87） |
/// | 容器材质 | app.css 2364–2378（`.mention-picker`：glass-bg-strong + `--glass-filter` + 1px 边 + radius 16 + `--glass-shadow`） |
/// | portal 档 | app.css 2387–2392（`.is-portal { position: fixed; z-index: 75 }`） |
/// | 列表/行/空态 | app.css 2380–2428 |
/// | 过滤 | tsx 47–55（排除自己 + `nickname username` 小写包含） |
/// | 键盘 | tsx 94–110（ESC 关闭并回焦编辑器 / ↑↓ 在 option 间循环） |
/// | 点外部关闭 | tsx 91–93（pointerdown 不在 picker 与 anchor 内） |
/// | 分页 | tsx 44–45 + 145（群成员 query+cursor → `DirectoryLoadMore`） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. **统一走 portal 档**：web 有「anchorRef 存在 → createPortal / 否则内联 absolute」两条路径，
///    但两者 CSS 完全一致（只差 `position: fixed` vs `absolute`）⇒ Flutter 侧统一由
///    [AylaMentionPickerHost] 插 root Overlay（`aylaOverlayEntry`），视觉与 web 相同；
/// 2. **浮层高度来源**：web 用 `picker.scrollHeight + 2` 实测；Flutter 按**行高 × 行数**算
///    （行高固定 = padding 8×2 + 头像 32 = 48），用于 above/below 判定 —— 结果等价；
/// 3. **点外部关闭**：Flutter 无全局 pointerdown 钩子 ⇒ 用 `TapRegion.onTapOutside`
///    + 命中 anchor 矩形时不关闭（等价 web 的 `anchorRef.contains(target)` 判断）。
///
/// ## 公开面
/// `AylaMentionMemberPage` · `AylaMentionPicker` · `AylaMentionPickerState` · `AylaMentionPickerHost` · 样张 `aylaMentionPickerSamples()`

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;

import '../../core/models/conversation.dart';
import '../../core/models/user_public.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/directory_controls.dart' show AylaDirectoryLoadMore;
import '../base/overlays.dart';

/// 群成员分页投影（web `useSocialPage("members", { groupId, q, excludeSelf: true })`）。
class AylaMentionMemberPage {
  const AylaMentionMemberPage({
    required this.items,
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.loadMore,
    this.refresh,
  });

  /// 已加载成员（服务端已排除自己；本地仍再过滤一次，见 [AylaMentionPicker.filtered]）。
  final List<AylaConversationMember> items;

  final bool loading;
  final String? error;
  final bool hasMore;
  final Future<void> Function()? loadMore;
  final Future<void> Function()? refresh;
}

/// @ 成员选择器内容（不含定位；由 [AylaMentionPickerHost] 放进 root Overlay）。
class AylaMentionPicker extends StatefulWidget {
  const AylaMentionPicker({
    super.key,
    required this.members,
    this.groupId,
    required this.query,
    required this.onSelect,
    this.onClose,
    this.currentUserId,
    this.memberPage,
    this.isOnline,
    this.height = 280,
    this.width,
  });

  /// 内联成员（`groupId` 为空时的有限数据兼容，tsx 45）。
  final List<AylaConversationMember> members;

  /// 群 id（非空时用 [memberPage] 分页数据，tsx 44–45）。
  final String? groupId;

  /// `@` 之后的过滤词（不含 `@`；空 = 显示全部成员）。
  final String query;

  /// 选中成员（由 MessageInput 生成不可拆分 @Token）。
  final void Function(AylaConversationMember member) onSelect;

  /// 关闭（ESC / 点外部）。
  final VoidCallback? onClose;

  /// 当前用户 id（排除自己，tsx 49）。
  final String? currentUserId;

  final AylaMentionMemberPage? memberPage;

  /// 实时在线判定（web `presenceOnline(...)`）—— 页面层注入。
  final bool Function(AylaUserPublic user)? isOnline;

  /// 浮层高度上限（`.mention-picker { max-height: 280px }`），由宿主按可用空间收窄。
  final double height;

  /// 浮层宽度（宿主按 anchor 宽给；null = 撑满父级）。
  final double? width;

  static const double maxHeight = 280;

  /// 单行高度 = padding `sp2`×2 + 头像 32（tsx 139 + app.css 2399）。
  static const double itemHeight = AylaSpacing.sp2 * 2 + 32;

  /// 滚动容器 padding = `sp1`×2（app.css 2383）。
  static const double scrollPadding = AylaSpacing.sp1 * 2;

  /// 按 web 规则过滤（tsx 47–55）：
  /// 排除自己；`q` 非空时匹配 `nickname username`（小写、包含）。
  List<AylaConversationMember> get filtered {
    final String q = query.trim().toLowerCase();
    final Iterable<AylaConversationMember> source =
        (groupId != null && memberPage != null) ? memberPage!.items : members;
    return source.where((AylaConversationMember m) {
      if (currentUserId != null && m.user.id == currentUserId) return false;
      if (q.isEmpty) return true;
      final String haystack =
          '${m.user.nickname ?? ''} ${m.user.username ?? ''}'.toLowerCase();
      return haystack.contains(q);
    }).toList(growable: false);
  }

  @override
  State<AylaMentionPicker> createState() => AylaMentionPickerState();
}

/// 选择器状态（公开以便宿主驱动键盘导航，先例：`AylaNavHighlightState`）。
class AylaMentionPickerState extends State<AylaMentionPicker> {
  final List<FocusNode> _nodes = <FocusNode>[];
  int? _activeIndex;

  @override
  void dispose() {
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  int get _itemCount => widget.filtered.length;

  /// ↑↓ 在 option 之间循环（tsx 101–108）。
  ///
  /// 由 [AylaMentionPickerHost] 的**全局键盘监听**驱动（web 监听的是 `document`，
  /// 且不抢编辑器焦点 ⇒ Flutter 侧不能用 `Shortcuts`：那要求焦点在本子树内）。
  void moveFocus(int delta) {
    final int count = _itemCount;
    if (count == 0) return;
    final int current = _activeIndex ?? (delta > 0 ? -1 : 0);
    final int next = (current + delta + count) % count;
    setState(() => _activeIndex = next);
    _nodes[next].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final List<AylaConversationMember> items = widget.filtered;
    final AylaMentionMemberPage? page = widget.memberPage;
    final bool loading = page?.loading ?? false;
    final bool hasError = page?.error != null;
    while (_nodes.length < items.length) {
      _nodes.add(FocusNode());
    }
    for (int i = items.length; i < _nodes.length; i++) {
      _nodes[i].unfocus();
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.height),
      child: SizedBox(
        width: widget.width,
        child: ClipRRect(
          // `.mention-picker { overflow: hidden }`（app.css 2371）
          borderRadius: BorderRadius.circular(AylaRadii.rCard),
          child: AylaGlassSurface(
            // `.mention-picker`：`--glass-bg-strong` + `--glass-filter`(blur24 sat1.4)
            // + 1px `--glass-border` + radius 16 + `--glass-shadow`
            strong: true,
            blur: AylaGlass.blurCard,
            radius: AylaRadii.rCard,
            shadow: AylaShadows.glass,
            padding: EdgeInsets.zero,
            child: Semantics(
              container: true,
              label: '选择要 @ 的成员',
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AylaSpacing.sp1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int i = 0; i < items.length; i++)
                      _MentionRow(
                        member: items[i],
                        focusNode: _nodes[i],
                        onFocused: () => setState(() => _activeIndex = i),
                        onSelect: () => widget.onSelect(items[i]),
                        isOnline: widget.isOnline,
                      ),
                    if (items.isEmpty && !loading && !hasError)
                      const _MentionEmpty(),
                    if (widget.groupId != null && page != null)
                      AylaDirectoryLoadMore(
                        loading: page.loading,
                        error: page.error,
                        hasMore: page.hasMore,
                        invalidated: false,
                        loadMore: page.loadMore ?? () async {},
                        refresh: page.refresh ?? () async {},
                        retainCompletedSpace: false,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.mention-picker-item`（app.css 2394–2412）：flex center / gap 12 / padding 8 12 /
/// radius 8；hover 与 focus 都是 `rgba(157,191,230,.35)`。
class _MentionRow extends StatefulWidget {
  const _MentionRow({
    required this.member,
    required this.focusNode,
    required this.onSelect,
    required this.onFocused,
    this.isOnline,
  });

  final AylaConversationMember member;
  final FocusNode focusNode;
  final VoidCallback onSelect;
  final VoidCallback onFocused;
  final bool Function(AylaUserPublic user)? isOnline;

  @override
  State<_MentionRow> createState() => _MentionRowState();
}

class _MentionRowState extends State<_MentionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaUserPublic user = widget.member.user;
    // 名称回退链：nickname → username（tsx 123）；都没有时不造「未知用户」，用 id。
    final String name = user.displayName ?? user.id;
    final bool online = widget.isOnline?.call(user) ?? user.online;
    return Semantics(
      button: true,
      label: '@$name',
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (bool v) {
          if (v) widget.onFocused();
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onSelect,
            child: AnimatedContainer(
              duration: AylaDurations.fast,
              curve: AylaCurves.easeOut,
              height: AylaMentionPicker.itemHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3,
                vertical: AylaSpacing.sp2,
              ),
              decoration: BoxDecoration(
                color: _hovered || widget.focusNode.hasFocus
                    ? const Color(0x599DBFE6) // rgba(157,191,230,.35)
                    : null,
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
              ),
              child: Row(
                children: <Widget>[
                  AylaAvatarHalo(
                    label: name,
                    size: 32,
                    online: online,
                    resourceUrl: user.avatar,
                    core: AylaAvatarCore.user,
                  ),
                  const SizedBox(width: AylaSpacing.sp3),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // `.mention-picker-name`：14/600/textPrimary（app.css 2414–2421）
                      style: const TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.mention-picker-empty`（app.css 2423–2428）。
class _MentionEmpty extends StatelessWidget {
  const _MentionEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AylaSpacing.sp4),
      child: Text(
        '无匹配成员',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// 浮层宿主：把选择器插进 **root Overlay** 并按 anchor 实测矩形定位
/// （web `createPortal` + 57–87 的定位算法）。
///
/// 用法（MessageInput 接线）：
/// ```dart
/// _host.open(context, anchorKey: _composerKey, query: '@后面的词',
///     members: ..., onSelect: (m) => insertMention(m.user));
/// ```
class AylaMentionPickerHost {
  OverlayEntry? _entry;

  /// 打开（重复打开先关旧的）。
  void open(
    BuildContext context, {
    required GlobalKey anchorKey,
    required List<AylaConversationMember> members,
    required String query,
    required void Function(AylaConversationMember member) onSelect,
    String? groupId,
    String? currentUserId,
    AylaMentionMemberPage? memberPage,
    bool Function(AylaUserPublic user)? isOnline,
  }) {
    close();
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => _MentionOverlay(
        anchorKey: anchorKey,
        members: members,
        query: query,
        onSelect: (AylaConversationMember m) {
          onSelect(m);
        },
        groupId: groupId,
        currentUserId: currentUserId,
        memberPage: memberPage,
        isOnline: isOnline,
        onClose: close,
      ),
    );
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  /// 关闭（幂等）。
  void close() {
    _entry?.remove();
    _entry = null;
  }

  bool get isOpen => _entry != null;
}

/// 浮层定位（web tsx 57–87）：贴 anchor（`.composer`）的 above/below，
/// edge 8 / gap 8 / 高度上限 280 / 宽度 = anchor 宽（clamp 视口）。
class _MentionOverlay extends StatefulWidget {
  const _MentionOverlay({
    required this.anchorKey,
    required this.members,
    required this.query,
    required this.onSelect,
    required this.onClose,
    this.groupId,
    this.currentUserId,
    this.memberPage,
    this.isOnline,
  });

  final GlobalKey anchorKey;
  final List<AylaConversationMember> members;
  final String query;
  final void Function(AylaConversationMember member) onSelect;
  final VoidCallback onClose;
  final String? groupId;
  final String? currentUserId;
  final AylaMentionMemberPage? memberPage;
  final bool Function(AylaUserPublic user)? isOnline;

  @override
  State<_MentionOverlay> createState() => _MentionOverlayState();
}

class _MentionOverlayState extends State<_MentionOverlay> {
  final GlobalKey<AylaMentionPickerState> _pickerKey =
      GlobalKey<AylaMentionPickerState>();

  @override
  void initState() {
    super.initState();
    // **全局键盘监听**（等价 web `document.addEventListener("keydown", onKey)`，
    // tsx 94–110）：ESC 关闭、↑↓ 在成员间循环。
    // ⚠️ 不能用 `Shortcuts`：那只在焦点位于本子树内时生效，而 web 刻意**不抢编辑器焦点**
    // （tsx 130 `onMouseDown preventDefault`）⇒ 打开选择器时焦点仍在输入框里。
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _pickerKey.currentState?.moveFocus(1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _pickerKey.currentState?.moveFocus(-1);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final RenderObject? anchor =
        widget.anchorKey.currentContext?.findRenderObject();
    Rect rect = Rect.zero;
    if (anchor is RenderBox && anchor.hasSize) {
      rect = anchor.localToGlobal(Offset.zero) & anchor.size;
    }
    const double edge = 8;
    const double gap = 8;
    // 行数 → 内容高（行高固定 48 + 滚动 padding 8；等价 web 的 `scrollHeight + 2`）
    final int rowCount = widget.members.length;
    final double contentHeight =
        rowCount * AylaMentionPicker.itemHeight + AylaMentionPicker.scrollPadding;
    final double height =
        math.min(AylaMentionPicker.maxHeight, contentHeight + 2);
    final double above = rect.top - gap - edge;
    final double below = screen.height - rect.bottom - gap - edge;
    final bool placeAbove = above >= height || above >= below;
    final double maxHeight = math.max(
      40,
      math.min(AylaMentionPicker.maxHeight, placeAbove ? above : below),
    );
    final double width =
        math.max(0, math.min(rect.width, screen.width - edge * 2));
    final double left =
        math.max(edge, math.min(rect.left, screen.width - width - edge));
    final double top = math.max(
      edge,
      placeAbove
          ? rect.top - gap - math.min(height, maxHeight)
          : rect.bottom + gap,
    );

    return Positioned(
      left: left,
      top: top,
      width: width,
      child: TapRegion(
        onTapOutside: (PointerDownEvent event) {
          // web：`!picker.contains(target) && !anchor.contains(target)` → 关闭（tsx 92）
          final Offset p = event.position;
          if (rect.contains(p)) return;
          widget.onClose();
        },
        child: AylaMentionPicker(
          key: _pickerKey,
          members: widget.members,
          query: widget.query,
          onSelect: widget.onSelect,
          onClose: widget.onClose,
          groupId: widget.groupId,
          currentUserId: widget.currentUserId,
          memberPage: widget.memberPage,
          isOnline: widget.isOnline,
          height: maxHeight,
        ),
      ),
    );
  }
}

// ======================= 样张 =======================

AylaConversationMember _previewMember(
  String id,
  String name, {
  bool online = false,
  String? avatar,
}) =>
    AylaConversationMember(
      id: 'm-$id',
      user: AylaUserPublic(
        id: id,
        nickname: name,
        username: 'user_$id',
        avatar: avatar,
        online: online,
      ),
    );

/// @ 选择器样张：
/// 全量成员 / 过滤命中 / 无匹配空态 / 分页加载中。
Widget aylaMentionPickerSamples() {
  aylaEnableSampleMedia();
  Widget cell(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          // ⚠️ `Align(widthFactor: 1)` 松横向紧约束并收缩到 child 尺寸：
          // 画布/预览的宿主常给**紧宽**，否则 `SizedBox(width:)` 会被 `constraints.enforce`
          // 夹回宿主宽（第一批已踩：见 13 号 §6.36 真 bug 3）。
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(width: 320, child: child),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  final List<AylaConversationMember> members = <AylaConversationMember>[
    _previewMember('u1', '小樱', online: true, avatar: '/api/v1/media/u1/thumbnail'),
    _previewMember('u2', '阿澈', online: true),
    _previewMember('u3', '汐汐'),
    _previewMember('u4', '林深', online: true),
  ];

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      cell(
        '全量成员（↑↓ 循环 / ESC 关闭 / hover 与 focus 同款底）',
        AylaMentionPicker(
          members: members,
          query: '',
          currentUserId: 'me',
          onSelect: (_) {},
        ),
      ),
      cell(
        '过滤命中「樱」',
        AylaMentionPicker(members: members, query: '樱', onSelect: (_) {}),
      ),
      cell(
        '无匹配（空态）',
        AylaMentionPicker(members: members, query: 'zzz', onSelect: (_) {}),
      ),
      cell(
        '分页加载中（groupId 路径）',
        AylaMentionPicker(
          members: const <AylaConversationMember>[],
          groupId: 'g1',
          query: '',
          onSelect: (_) {},
          memberPage: const AylaMentionMemberPage(
            items: <AylaConversationMember>[],
            loading: true,
            hasMore: true,
          ),
        ),
      ),
    ],
  );
}
