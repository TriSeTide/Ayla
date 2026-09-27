/// 创建桌游室表单。
///
/// ## 事实源
/// ```
/// GameRoomCreate.tsx 9–78     可见性选择器 + 名称输入 + 错误行 + 「创建」按钮
/// boardgame.css 123–128       .game-room-create：flex · flex-direction column · gap sp2 ·
///                             padding var(--sp-3) = 12
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/game/game_room_create.dart` 一节）
/// ```
///
/// ## 机制差异
/// web 在组件内直接 `boardgameApi.createGameRoom(...)`，Flutter 侧按既有
/// 「展示型 + 注入」模式（同 `AylaVoiceChannelCreate`）：组件只负责
/// 校验 / 防重入 / busy / 错误展示 / 成功后清空，请求由页面层在 [onSubmit] 完成。
///
/// ## 两处实现口径（与 web 等价，已在测试里锁住）
/// 1. **64 字符上限用 `inputFormatters`**（`LengthLimitingTextInputFormatter`）而不是
///    `maxLength`：后者会让 Flutter 在字段下方多渲染「0/64」计数器，web 没有该元素；
/// 2. **提交键可用性随文本变化 setState**（chat 域 `MessageInput` 的真实事故：
///    漏 setState ⇒ 按钮永远停在初始禁用态，输入文字后点发送无反应）。
///
/// ## 公开面
/// `AylaGameRoomCreateRequest` · `AylaGameRoomCreateException` · `AylaGameRoomCreate` · 样张 `aylaGameRoomCreateSamples()`

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;

import '../../core/models/visibility.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/directory_controls.dart';

/// 建桌游室请求 —— web `createGameRoom({ name, group, visibility, allowed_group_ids })`
/// （tsx 38–43）。
class AylaGameRoomCreateRequest {
  const AylaGameRoomCreateRequest({
    required this.name,
    required this.visibility,
    required this.allowedGroupIds,
  });

  /// 已 `trim()` 的名称（tsx 27）。
  final String name;

  /// 后端单值可见性：`public` / `friends` / `group`（tsx 37 的多选→单值映射）。
  final AylaPostVisibility visibility;

  /// 白名单群 id（tsx 42）。
  final List<String> allowedGroupIds;
}

/// 建桌游室失败时由页面层抛出，[AylaGameRoomCreate] 直接展示其 [message]
/// （等价 web 的 `e instanceof Error ? e.message : "创建失败"`，tsx 47）。
class AylaGameRoomCreateException implements Exception {
  const AylaGameRoomCreateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `.game-room-create` —— 创建桌游室表单（`GameRoomCreate.tsx`）。
class AylaGameRoomCreate extends StatefulWidget {
  const AylaGameRoomCreate({
    super.key,
    this.groupId,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.onSubmit,
    this.onCreated,
  });

  /// 群内创建时归属的群 id（`group?: string | null`）；一级创建为 null。
  final String? groupId;

  /// 可见性选择器的可搜索群列表（页面层注入）。
  final List<({String id, String title})> groups;

  /// 群列表加载中。
  final bool groupsLoading;

  /// 提交（页面层发请求）；抛 [AylaGameRoomCreateException] 显示其文案，
  /// 其他异常显示「创建失败」。**成功返回后**组件会清空名称并回调 [onCreated]。
  final Future<void> Function(AylaGameRoomCreateRequest request)? onSubmit;

  /// 创建成功（tsx 45：外层关闭创建浮层）。
  final VoidCallback? onCreated;

  /// tsx 29：空名错误文案。
  static const String emptyNameError = '房间名不能为空';

  /// 兜底错误文案（tsx 47）。
  static const String fallbackError = '创建失败';

  /// tsx 61：`maxLength={64}`。
  static const int nameMaxLength = 64;

  @override
  State<AylaGameRoomCreate> createState() => _AylaGameRoomCreateState();
}

class _AylaGameRoomCreateState extends State<AylaGameRoomCreate> {
  final TextEditingController _name = TextEditingController();
  late AylaVisibilitySelection _visibility;
  late List<String> _selectedGroupIds;
  bool _busy = false;
  String? _error;

  /// tsx 22：`submitting` ref（busy 期间重复提交直接 return）。
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // tsx 17–20：群内创建默认「群可见 + 本群」；一级创建默认「公开」。
    final String? group = widget.groupId;
    _visibility = group != null
        ? const AylaVisibilitySelection(group: true)
        : const AylaVisibilitySelection(isPublic: true);
    _selectedGroupIds = group != null ? <String>[group] : <String>[];
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// tsx 37：多选 → 单值（公开优先、其次好友、否则群）。
  AylaPostVisibility get _backendVisibility => _visibility.isPublic
      ? AylaPostVisibility.public
      : (_visibility.friends
          ? AylaPostVisibility.friends
          : AylaPostVisibility.group);

  /// Web 的 `disabled={busy || !name.trim()}`（tsx 71）——空名时按钮禁用。
  bool get _submitDisabled => _busy || _name.text.trim().isEmpty;

  Future<void> _submit() async {
    if (_submitting) return; // tsx 26
    final String trimmed = _name.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = AylaGameRoomCreate.emptyNameError);
      return;
    }
    _submitting = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit?.call(
        AylaGameRoomCreateRequest(
          name: trimmed,
          visibility: _backendVisibility,
          allowedGroupIds: List<String>.of(_selectedGroupIds),
        ),
      );
      // tsx 44–45：成功才清空名称并通知外层
      _name.clear();
      widget.onCreated?.call();
    } catch (e) {
      // tsx 46–47：保留表单，展示错误
      setState(() {
        _error = e is AylaGameRoomCreateException
            ? e.message
            : AylaGameRoomCreate.fallbackError;
      });
    } finally {
      _submitting = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    return Padding(
      // `.game-room-create { padding: var(--sp-3) }`
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      child: Column(
        // `.game-room-create { display:flex; flex-direction: column; gap: var(--sp-2) }`
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp2,
        children: <Widget>[
          AylaVisibilitySelector(
            value: _visibility,
            onChange: (AylaVisibilitySelection v) => setState(() => _visibility = v),
            selectedGroupIds: _selectedGroupIds,
            onSelectedGroupIdsChange: (List<String> ids) =>
                setState(() => _selectedGroupIds = ids),
            groups: widget.groups,
            groupsLoading: widget.groupsLoading,
            initialGroupId: widget.groupId,
            lockGroup: widget.groupId != null, // tsx 56：`lockGroup={!!group}`
          ),
          SizedBox(
            // `.create-sheet-card .game-room-create .field { width: 100% }`
            width: double.infinity,
            child: Padding(
              // 同规则的 `margin-bottom: var(--sp-3)`（与容器 gap 8 叠加）
              padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
              child: AylaGlassInput(
                controller: _name,
                hintText: '桌游室名称', // tsx 59
                semanticLabel: '桌游室名称',
                // tsx 61：`maxLength={64}` —— 用 formatter 表达（`maxLength` 会带计数器）
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(
                    AylaGameRoomCreate.nameMaxLength,
                  ),
                ],
                // tsx 71 的 `!name.trim()`：输入变化要重算提交键可用性
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => unawaited(_submit()), // tsx 63–65：Enter 提交
              ),
            ),
          ),
          // tsx 67：错误行在按钮**之前**（与语音频道表单的顺序相反）
          if (_error != null)
            Text(
              _error!,
              // `.post-editor-error { font-size: 13px; color: var(--destructive) }`
              style: t.body.copyWith(
                fontSize: 13,
                color: AylaColors.destructive,
              ),
            ),
          AylaGlassButton(
            label: _busy ? '创建中…' : '创建', // tsx 74
            variant: AylaGlassButtonVariant.primary,
            // `.create-sheet-card .btn-primary:not(.post-editor-submit) { width: 100% }`
            expand: true,
            onPressed: _submitDisabled ? null : () => unawaited(_submit()),
          ),
        ],
      ),
    );
  }
}

// ======================= 样张 =======================

/// 建桌游室表单样张。
///
/// - 左：一级创建（默认公开）；不填名字 → 按钮禁用；填了 → 假提交 → 清空 + 计数；
/// - 中：群内创建（群可见锁定 + 本群恒勾选）；
/// - 右：失败态（提交抛错 → 文案保留表单）。
Widget aylaGameRoomCreateSamples() => const _GameRoomCreateDemo();

class _GameRoomCreateDemo extends StatefulWidget {
  const _GameRoomCreateDemo();

  @override
  State<_GameRoomCreateDemo> createState() => _GameRoomCreateDemoState();
}

class _GameRoomCreateDemoState extends State<_GameRoomCreateDemo> {
  int _created = 0;
  String _lastName = '—';

  static const List<({String id, String title})> _groups =
      <({String id, String title})>[
    (id: 'g1', title: '冰樱研究社'),
    (id: 'g2', title: '深夜电台'),
  ];

  Future<void> _fakeSubmit(AylaGameRoomCreateRequest req) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    setState(() {
      _created++;
      _lastName = req.name;
    });
  }

  Widget _sheetMock({required String title, required Widget child}) {
    return SizedBox(
      width: 380,
      child: AylaGlassCard(
        // 模拟 sheet 卡面（真实容器由页面层的 AylaCreateSheet 提供）
        strong: true,
        radius: AylaRadii.rPanel,
        shadow: AylaShadows.modal,
        padding: const EdgeInsets.all(AylaSpacing.sp4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: AylaSpacing.sp3),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _sheetMock(
          title: '一级创建（默认公开）· 已建 $_created 个，最后一次「$_lastName」',
          child: AylaGameRoomCreate(
            groups: _groups,
            onSubmit: _fakeSubmit,
            onCreated: () => setState(() {}),
          ),
        ),
        _sheetMock(
          title: '群内创建（group 非空 ⇒ 群可见锁定 + 本群恒勾选）',
          child: AylaGameRoomCreate(
            groupId: 'g1',
            groups: _groups,
            onSubmit: _fakeSubmit,
          ),
        ),
        _sheetMock(
          title: '失败态（提交抛错 → 文案保留表单）',
          child: AylaGameRoomCreate(
            groups: _groups,
            onSubmit: (AylaGameRoomCreateRequest req) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              throw const AylaGameRoomCreateException('同名桌游室已存在');
            },
          ),
        ),
      ],
    );
  }
}
