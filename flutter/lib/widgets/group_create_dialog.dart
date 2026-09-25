/// B6 第一件：创建群聊对话框（GroupCreateDialog.tsx 184 行）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ── 弹层与卡片**与 CreateSheet 同规格**（private.css 「通用弹层」段 188–280 明写两者共用）：
/// overlay 遮罩 rgba(70,91,146,.25) · padding sp4 · **窄屏贴底 padding 0**；
/// 卡片 min(480px,100%) · max-height 80vh · overflow-y auto · padding sp4 · glass-bg-strong ·
/// radius panel 20 · glass-shadow-modal；窄屏 radius 24 24 0 0 + 去左右下边框 + 上滑 250ms
/// ⇒ 直接复用 [AylaModalOverlay] + [AylaModalCard]（默认档）
/// ── head：.group-create-dialog-head / -title 与 .create-sheet-head / -title **逐字相同**
/// （flex space-between · margin-bottom sp3；title display 18/**w600**）+ .icon-btn-40 + IconClose 18
/// ⇒ 直接复用 [AylaSheetHead]
/// ── tsx 98–105：群名 input.field（**autoFocus** · placeholder/aria「群名（必填）」）
/// ── tsx 108–117 + private.css 89–106：成员搜索 —— 相对定位行 + 左搜索图标（15×15 ·
/// left sp3 · --text-secondary · pointer-events none）+ 输入 padding-left **34px** ·
/// margin-top sp2 · placeholder「搜索成员（可选，可稍后在群内添加）」
/// ── tsx 119 + app.css 272–276：.field-error（13px · w400 · destructive）
/// ── tsx 122–138 + private.css 108–141：已选 chips —— flex-wrap · gap sp2 · margin-top sp2；
/// chip = padding 2/8/2/10 · pill · --ice-100 · 12/600 · 叉 16×16（hover → destructive）
/// ⇒ 复用提升后的 [AylaGroupChip]（aria「移除 name」，tsx 131）
/// ── tsx 141–170 + private.css 143–177：结果列表 —— margin-top sp2 · **max-height 220 自滚**；
/// 行 = flex space-between · gap sp2 · padding sp2 sp3；勾选行整体可点（web 是 label）=
/// 16×16 checkbox + 名称（14/600 · 单行省略）；右侧幽灵键「私聊」（minHeight 32 · padding 0 12 ·
/// 12px · busy 时禁用）；空态「没有匹配的用户」—— ⚠️ 该类声明 padding var(--sp-10) 而
/// **--sp-10 在 tokens 里未定义 ⇒ 整条作废**（照实渲染 = 无 padding，只是居中文本）
/// ── tsx 172–180 + private.css 179–186：建群键 —— primary · **width 100%** · margin-top sp3；
/// 前置 IconPlus 16；文案「建群」+ 选中时「（N 人）」；disabled = busy || 群名空
/// ── tsx 34–37：搜索 **300ms 防抖**（setTimeout）；tsx 30/167：结果仅在
/// query.trim() == searchQuery.trim() 时可见（防抖窗口内不显示旧结果）
/// ── tsx 40–44：勾选/取消；tsx 46–64：建群（成功 → upsert + onClose + 跳 /group/:id，
/// 失败 → 文案兜底「建群失败」）；tsx 66–80：私聊（同上，兜底「发起私聊失败」）
///
/// ## 装配口径
/// web 在组件内直接调 chatApi 并 navigate；Flutter 侧注入：搜索结果与分页由页面层注入
/// （[searchResults] / [onSearchChanged] / [onLoadMoreResults]），建群与私聊分别走
/// [onSubmit] / [onOpenPrivate]（返回 conversation_id），跳转归调用方（[onDone]）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/models/user_public.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'dialogs.dart' show AylaModalCard, AylaModalOverlay, AylaSheetHead;
import 'directory_controls.dart'
    show AylaCheckbox, AylaDirectoryLoadMore, AylaGroupChip;

/// 建群 / 私聊失败时由页面层抛出以展示业务文案（tsx 60/76 的兜底链）。
class AylaGroupCreateException implements Exception {
  const AylaGroupCreateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// .group-create-dialog —— 创建群聊对话框。
class AylaGroupCreateDialog extends StatefulWidget {
  const AylaGroupCreateDialog({
    super.key,
    required this.onClose,
    this.currentUserId,
    this.searchResults = const <AylaUserPublic>[],
    this.searchLoading = false,
    this.searchError,
    this.searchHasMore = false,
    this.searchInvalidated = false,
    this.onSearchChanged,
    this.onLoadMoreResults,
    this.onRefreshResults,
    this.onSubmit,
    this.onOpenPrivate,
    this.onDone,
  });

  /// 关闭（遮罩 / 关闭键）。
  final VoidCallback onClose;

  /// 当前用户 id —— 搜索结果里**过滤掉自己**（tsx 30）。
  final String? currentUserId;

  /// 搜索结果（页面层注入）。
  final List<AylaUserPublic> searchResults;
  final bool searchLoading;
  final String? searchError;
  final bool searchHasMore;
  final bool searchInvalidated;

  /// 搜索词变化（**300ms 防抖后**触发；页面层据此拉取）。
  final ValueChanged<String>? onSearchChanged;
  final Future<void> Function()? onLoadMoreResults;
  final Future<void> Function()? onRefreshResults;

  /// 建群（页面层发请求），返回群 conversation_id。
  final Future<String> Function(String title, List<String> memberIds)? onSubmit;

  /// 发起私聊（页面层发请求），返回会话 id。
  final Future<String> Function(String userId)? onOpenPrivate;

  /// 成功后的跳转目标（群 / 私聊 conversation_id）。
  final ValueChanged<String>? onDone;

  /// tsx 60 兜底。
  static const String fallbackCreateError = '建群失败';

  /// tsx 76 兜底。
  static const String fallbackPrivateError = '发起私聊失败';

  /// tsx 35：防抖 300ms。
  static const int debounceMs = 300;

  @override
  State<AylaGroupCreateDialog> createState() => _AylaGroupCreateDialogState();
}

class _AylaGroupCreateDialogState extends State<AylaGroupCreateDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _query = TextEditingController();

  /// 防抖后的搜索词（tsx 28 的 searchQuery）。
  String _searchQuery = '';
  Timer? _debounce;

  /// 已选成员（tsx 31）。
  final List<AylaUserPublic> _selected = <AylaUserPublic>[];

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _query.dispose();
    super.dispose();
  }

  /// tsx 34–37：300ms 防抖。
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: AylaGroupCreateDialog.debounceMs),
      () {
        if (!mounted) return;
        setState(() => _searchQuery = value.trim());
        widget.onSearchChanged?.call(value.trim());
      },
    );
  }

  /// tsx 30：防抖窗口内（q != searchQuery）不显示结果；并过滤掉自己。
  List<AylaUserPublic> get _visibleResults {
    if (_query.text.trim() != _searchQuery) return const <AylaUserPublic>[];
    return <AylaUserPublic>[
      for (final AylaUserPublic u in widget.searchResults)
        if (u.id != widget.currentUserId) u,
    ];
  }

  /// tsx 40–44：勾选/取消。
  void _toggleMember(AylaUserPublic u) {
    setState(() {
      final int i = _selected.indexWhere((AylaUserPublic m) => m.id == u.id);
      if (i >= 0) {
        _selected.removeAt(i);
      } else {
        _selected.add(u);
      }
    });
  }

  /// tsx 46–64：建群。
  Future<void> _createGroup() async {
    final String trimmed = _title.text.trim();
    if (trimmed.isEmpty) return; // tsx 47
    final Future<String> Function(String, List<String>)? submit = widget.onSubmit;
    if (submit == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final String convId = await submit(
        trimmed,
        _selected.map((AylaUserPublic m) => m.id).toList(),
      );
      if (!mounted) return;
      widget.onDone?.call(convId);
      widget.onClose();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AylaGroupCreateException
            ? e.message
            : AylaGroupCreateDialog.fallbackCreateError;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// tsx 66–80：发起私聊。
  Future<void> _openPrivate(AylaUserPublic u) async {
    final Future<String> Function(String)? open = widget.onOpenPrivate;
    if (open == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final String convId = await open(u.id);
      if (!mounted) return;
      widget.onDone?.call(convId);
      widget.onClose();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AylaGroupCreateException
            ? e.message
            : AylaGroupCreateDialog.fallbackPrivateError;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    return AylaModalOverlay(
      // tsx 83：点遮罩关闭（busy 时不关，避免请求途中丢状态）
      onDismiss: _busy ? null : widget.onClose,
      padding: AylaSpacing.sp4, // .group-create-overlay { padding: var(--sp-4) }
      child: AylaModalCard(
        // 卡片规格与 CreateSheet 完全一致 ⇒ 默认档（480 / 80vh / padding sp4 / 窄屏贴底上滑）
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AylaSheetHead(
              title: '创建群聊', // tsx 91
              onClose: widget.onClose,
              closeIconSize: 18, // tsx 93
              disabled: _busy,
            ),
            // tsx 98–105：群名（必填）
            GlassInput(
              controller: _title,
              hintText: '群名（必填）',
              semanticLabel: '群名',
              autofocus: true,
              onChanged: (_) => setState(() {}), // 提交键可用性随文本刷新
            ),
            _searchRow(),
            if ((_error ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2),
                child: Text(
                  _error!,
                  // .field-error { font-size: 13px; font-weight: 400; color: var(--destructive) }
                  style: t.body.copyWith(
                    fontSize: 13,
                    color: AylaColors.destructive,
                  ),
                ),
              ),
            if (_selected.isNotEmpty) _chips(t),
            if (_query.text.trim().isNotEmpty) _results(t),
            _submit(),
          ],
        ),
      ),
    );
  }

  /// .group-create-search：左搜索图标 + 输入（padding-left 34）。
  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin-top: var(--sp-2)
      child: Stack(
        children: <Widget>[
          GlassInput(
            controller: _query,
            hintText: '搜索成员（可选，可稍后在群内添加）', // tsx 114
            semanticLabel: '搜索成员',
            padding: const EdgeInsets.fromLTRB(34, 12, 16, 12), // padding-left: 34px
            onChanged: (String v) {
              setState(() {}); // 结果可见性与空态随输入刷新
              _onQueryChanged(v);
            },
          ),
          Positioned(
            left: AylaSpacing.sp3, // left: var(--sp-3)
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              // pointer-events: none
              child: Center(
                child: AylaIcon(
                  aylaIconByName('iconSearch')!,
                  size: 15, // width/height 15
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// .group-create-chips：已选成员胶囊（flex-wrap · gap sp2 · margin-top sp2）。
  Widget _chips(AylaTextStyles t) {
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp2),
      child: Wrap(
        spacing: AylaSpacing.sp2,
        runSpacing: AylaSpacing.sp2,
        children: <Widget>[
          for (final AylaUserPublic u in _selected)
            AylaGroupChip(
              label: u.displayName ?? '', // tsx 126：nickname || username
              style: t,
              // tsx 131：aria-label「移除 name」
              removeSemanticLabel: '移除 ${u.displayName ?? ''}',
              onRemove: () => _toggleMember(u),
            ),
        ],
      ),
    );
  }

  /// .group-create-results：结果列表（max-height 220 自滚）。
  Widget _results(AylaTextStyles t) {
    final List<AylaUserPublic> rows = _visibleResults;
    final bool empty = _query.text.trim() == _searchQuery &&
        !widget.searchLoading &&
        widget.searchError == null &&
        rows.isEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin: sp2 0 0
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220), // max-height: 220px
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final AylaUserPublic u in rows) _resultRow(t, u),
              if (empty)
                Text(
                  '没有匹配的用户', // tsx 167
                  textAlign: TextAlign.center,
                  // ⚠️ .search-empty 声明 padding var(--sp-10) 而 --sp-10 在 tokens 里未定义
                  //    ⇒ 该声明整条作废（照实渲染 = 无 padding，只有居中文本）
                  style: t.body.copyWith(color: AylaColors.textSecondary),
                ),
              AylaDirectoryLoadMore(
                loading: widget.searchLoading,
                error: widget.searchError,
                hasMore: widget.searchHasMore,
                invalidated: widget.searchInvalidated,
                loadMore: widget.onLoadMoreResults ?? _noop,
                refresh: widget.onRefreshResults ?? _noop,
                retainCompletedSpace: false, // tsx 168
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// .group-create-result：勾选行（整行可点）+「私聊」键。
  Widget _resultRow(AylaTextStyles t, AylaUserPublic u) {
    final bool checked = _selected.any((AylaUserPublic m) => m.id == u.id);
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AylaSpacing.sp2,
        horizontal: AylaSpacing.sp3,
      ),
      child: Row(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              // web 是 label：点整行切换
              onTap: () => _toggleMember(u),
              child: Row(
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  AylaCheckbox(checked: checked), // 16×16（web native checkbox）
                  Expanded(
                    child: Text(
                      u.displayName ?? '', // tsx 153
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.body.copyWith(
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
          GlassButton(
            label: '私聊', // tsx 162
            variant: GlassButtonVariant.ghost,
            minHeight: 32, // style={{ minHeight: 32, padding: '0 12px', fontSize: 12 }}
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            onPressed: _busy ? null : () => unawaited(_openPrivate(u)),
          ),
        ],
      ),
    );
  }

  /// .group-create-submit：建群键（primary · 全宽 · margin-top sp3 · IconPlus 16）。
  Widget _submit() {
    final int n = _selected.length;
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp3),
      child: GlassButton(
        label: n > 0 ? '建群（$n 人）' : '建群', // tsx 179
        icon: AylaIcon(aylaIconByName('iconPlus')!, size: 16), // tsx 178
        variant: GlassButtonVariant.primary,
        onPressed: (_busy || _title.text.trim().isEmpty || widget.onSubmit == null)
            ? null
            : () => unawaited(_createGroup()),
      ),
    );
  }
}

Future<void> _noop() async {}

// ======================= 预览 =======================

/// 建群对话框样张（画布与 @Preview 共用；**可交互**）。
///
/// - 空态：只有群名输入（提交键禁用）；
/// - 搜索态：输入搜索词（300ms 防抖后出结果）→ 勾选进 chips → 「建群（N 人）」可点；
/// - 失败态：顶部开关切「下一次建群失败」看 .field-error 行（13px destructive）。
Widget aylaGroupCreateDialogSamples() => const _GroupCreateDialogDemo();

class _GroupCreateDialogDemo extends StatefulWidget {
  const _GroupCreateDialogDemo();

  @override
  State<_GroupCreateDialogDemo> createState() => _GroupCreateDialogDemoState();
}

class _GroupCreateDialogDemoState extends State<_GroupCreateDialogDemo> {
  String _log = '—';
  String _query = '';
  bool _failNext = false;

  static const List<AylaUserPublic> _users = <AylaUserPublic>[
    AylaUserPublic(id: 'u1', nickname: '爱莉', username: 'elysia'),
    AylaUserPublic(id: 'u2', username: 'bob_the_builder'),
    AylaUserPublic(id: 'u3', nickname: '卡罗尔'),
  ];

  List<AylaUserPublic> get _results => _query.isEmpty
      ? const <AylaUserPublic>[]
      : _users
          .where((AylaUserPublic u) => (u.displayName ?? '').contains(_query))
          .toList();

  Future<String> _create(String title, List<String> ids) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_failNext) {
      throw const AylaGroupCreateException('群名已被占用');
    }
    setState(() => _log = '建群 $title（${ids.length} 人）');
    return 'conv-new';
  }

  Future<String> _openPrivate(String userId) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    setState(() => _log = '发起私聊 $userId');
    return 'conv-$userId';
  }

  Widget _stage(String label, double width, double height, Widget child) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 11)),
          SizedBox(
            width: width,
            height: height,
            // ⚠️ 不裁圆角：弹层的遮罩要铺满舞台（裁圆角会在四角露背景）
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: Size(width, height)),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        Text('最近操作：$_log', style: const TextStyle(fontSize: 12)),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp3,
          children: <Widget>[
            GlassButton(
              label: _failNext ? '下一次建群：失败' : '下一次建群：成功',
              variant: GlassButtonVariant.ghost,
              minHeight: 32,
              fontSize: 12,
              onPressed: () => setState(() => _failNext = !_failNext),
            ),
          ],
        ),
        Wrap(
          spacing: AylaSpacing.sp6,
          runSpacing: AylaSpacing.sp6,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _stage(
              // ⚠️ 舞台宽必须 ≥ 769 才走宽屏档（居中 480 卡 + overlay padding sp4）；
              //    560 会被判定为窄屏 ⇒ 渲染成贴底上滑（用户 2026-09-25 实报）。
              '空态（宽屏 900：居中 480 卡 · 群名空 ⇒ 建群禁用）',
              900,
              620,
              AylaGroupCreateDialog(
                currentUserId: 'me',
                searchResults: _results,
                onSearchChanged: (String q) => setState(() => _query = q),
                onClose: () => setState(() => _log = '关闭'),
                onSubmit: _create,
                onOpenPrivate: _openPrivate,
                onDone: (String id) => setState(() => _log = '跳转 $id'),
              ),
            ),
            _stage(
              '窄屏 375（≤768）：贴底上滑 + radius 24 24 0 0 + padding 0',
              375,
              620,
              AylaGroupCreateDialog(
                currentUserId: 'me',
                searchResults: _results,
                onSearchChanged: (String q) => setState(() => _query = q),
                onClose: () => setState(() => _log = '关闭'),
                onSubmit: _create,
                onOpenPrivate: _openPrivate,
                onDone: (String id) => setState(() => _log = '跳转 $id'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 建群对话框（空态 / 搜索 + chips / 失败态）—— 可交互（在输入框里打字试搜索防抖）。
@Preview(
  group: 'Widgets',
  name: '建群对话框（GroupCreateDialog：群名 / 成员搜索 / 建群）',
  size: Size(1400, 1100),
  wrapper: previewTheme,
)
Widget aylaGroupCreateDialogPreview() => aylaGroupCreateDialogSamples();
