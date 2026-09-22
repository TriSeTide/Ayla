/// voice 域第五批（B1-5）：爱莉语音面板。
///
/// ## ⚠️ 事实前提：web 里这个组件**没有挂载点**
/// `grep -rn "ElysiaVoicePanel" --include=*.tsx` 只命中它自己（`useElysiaVoice` 也只有 vitest
/// 测试）——「控制面闭环」只做到 hook，页面接线从未做 ⇒ **web 上无法对照观感**，
/// 视觉验收只能靠本文件的样张对照下面这些行号（已与用户确认仍按清单复刻）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// ElysiaVoicePanel.tsx 1–108    收起态 = 一个 .btn.btn-glow「爱莉语音」；
///                               展开态 = head(标题 + 收起) + 未接入态/输入行 + 行动区
/// ElysiaVoicePanel.tsx 9        **主体性铁律：本组件不生成任何爱莉第一人称内容**（红线）
/// ElysiaVoicePanel.tsx 32–35    空文本拦截在 hook 的 sendText 里；只在受理后才清空输入
/// ElysiaVoicePanel.tsx 38–44    收起：`<section class="elysia-voice-panel collapsed">`
///                               + `<button class="btn btn-glow">爱莉语音</button>`
/// ElysiaVoicePanel.tsx 49–54    head：`h3.voice-panel-title`「爱莉语音」 + `.msg-action-btn`「收起」
/// ElysiaVoicePanel.tsx 56–57    `!call` → `.voice-list-empty`：`busy ? "接入中…" : "等待接入"`
/// ElysiaVoicePanel.tsx 61–71    输入行：`input.voice-create-input`（placeholder
///                               「对爱莉说的话（文本注入，爱莉发言在聊天页查看）」、
///                               `maxLength={2000}`、Enter 提交）+ `.btn.btn-primary`「发送」
/// ElysiaVoicePanel.tsx 83–103   行动区：`isTerminal` → `.btn.btn-primary`「重新发起」；
///                               否则 `.btn.voice-leave-btn`「结束通话」；两者 `disabled={busy}`
/// app.css 3122–3136              .elysia-voice-panel：flex column · gap sp3 = 12 ·
///                               max-width 560 · padding sp4 = 16 · radius 16 · --glass-bg ·
///                               1px --glass-border · blur(24) sat(1.4) · --glass-shadow
/// app.css 3137–3140              .collapsed：padding **sp3 = 12** + align-items: flex-start
/// app.css 3142–3146              .elysia-voice-head：flex · **align-items: center** ·
///                               justify-content: space-between
///                               （⚠️ B1-4 的 `.voice-panel-head` 是 `baseline`，**别抄错**）
/// app.css 3148–3151              .elysia-voice-input：flex · gap sp2 = 8
/// app.css 3153–3156              .elysia-voice-actions：flex · gap sp2 = 8
/// app.css 1324–1333 / 1362       .msg-action-btn：padding sp1/sp2 · radius-sm ·
///                               12px · --text-secondary · --glass-bg-strong · 1px 亮边；
///                               :hover → --indigo-700
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 用 `useElysiaVoice(open)` 自管通话生命周期（创建/复用、`elysia.voice.call.status` /
/// `elysia.voice.projected` 帧、502 → 「爱莉侧不可用」、结束幂等）。Flutter 侧按既有
/// 「展示型 + 注入」模式，把通话编排留给页面层：
/// - [connected]（web `!!call`）与 [isTerminal] 由页面层注入；
/// - [onEnsureCall]（创建/复用；terminal 时同时承担「重新发起」）/ [onEndCall]；
/// - 文本注入走 [onSubmitText]，**返回是否受理**（web：`sendText` 返回 false ⇒ 不清空输入）；
/// - 面板内只持有两个本地 UI 状态：展开与否、输入框内容（web `useState`）。
///
/// ## 未完成项（登记，交用户裁决）
/// 「收起」与「爱莉语音」等按钮的 `title`（浏览器原生 tooltip）属全库 `Tooltip` 统一项
/// （`13-工作进度与待办.md` §4.2）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// `.elysia-voice-panel` —— 爱莉语音面板（`ElysiaVoicePanel.tsx`）。
class AylaElysiaVoicePanel extends StatefulWidget {
  const AylaElysiaVoicePanel({
    super.key,
    this.connected = false,
    this.busy = false,
    this.isTerminal = false,
    this.onEnsureCall,
    this.onSubmitText,
    this.onEndCall,
  });

  /// 是否已有通话（web `!!call`）：false ⇒ 显示「接入中…」/「等待接入」。
  ///
  /// `call` 的其它字段（`state` 之外的元数据）属页面层，面板只消费「有没有」与 [isTerminal]。
  final bool connected;

  /// 通话编排进行中（web `busy`）⇒ 三个按钮都 disabled。
  final bool busy;

  /// 通话是否已终结（web `isTerminal(call.state)`）⇒ 行动区显示「重新发起」。
  final bool isTerminal;

  /// 创建/复用通话（web `ensureCall`）——terminal 时也用它承担「重新发起」。
  final Future<void> Function()? onEnsureCall;

  /// 文本注入（web `sendText`）：**返回是否受理**；未受理 ⇒ 不清空输入（tsx 32–35）。
  final Future<bool> Function(String text)? onSubmitText;

  /// 结束通话（web `endCall`，幂等）。
  final Future<void> Function()? onEndCall;

  /// tsx 66：`maxLength={2000}`。
  static const int textMaxLength = 2000;

  /// tsx 64 的 placeholder。
  static const String inputHint = '对爱莉说的话（文本注入，爱莉发言在聊天页查看）';

  /// `.collapsed` 档的 padding（`app.css:3138`）。
  static const double collapsedPadding = AylaSpacing.sp3;

  /// 展开档的 padding（`app.css:3129`）。
  static const double expandedPadding = AylaSpacing.sp4;

  @override
  State<AylaElysiaVoicePanel> createState() => _AylaElysiaVoicePanelState();
}

class _AylaElysiaVoicePanelState extends State<AylaElysiaVoicePanel> {
  /// tsx 15：`const [open, setOpen] = useState(false)`。
  bool _open = false;

  final TextEditingController _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final Future<bool> Function(String)? submit = widget.onSubmitText;
    if (submit == null || _sending) return;
    setState(() => _sending = true);
    bool accepted = false;
    try {
      accepted = await submit(_text.text);
    } catch (_) {
      // 发送失败：保留输入（与 web 一致——只有受理才清空）
      accepted = false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (accepted && mounted) _text.clear();
  }

  bool get _busy => widget.busy || _sending;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    // ---- 收起态：只有一个 `.btn.btn-glow`（tsx 38–44 + `.collapsed` 档）----
    if (!_open) {
      return _shell(
        padding: AylaElysiaVoicePanel.collapsedPadding,
        child: Align(
          // `.collapsed { align-items: flex-start }` ⇒ 内容左对齐
          alignment: Alignment.centerLeft,
          child: GlassButton(
            label: '爱莉语音', // tsx 41
            variant: GlassButtonVariant.glow,
            onPressed: () => setState(() => _open = true),
          ),
        ),
      );
    }

    // ---- 展开态 ----
    return _shell(
      padding: AylaElysiaVoicePanel.expandedPadding,
      child: Column(
        // `.elysia-voice-panel { flex-direction: column; gap: var(--sp-3) }`
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          Row(
            // `.elysia-voice-head { align-items: center; justify-content: space-between }`
            children: <Widget>[
              Expanded(
                child: Text(
                  '爱莉语音', // tsx 50
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // `.voice-panel-title`（复用 B1-4 那档）：16px + h3 默认 700
                  style: t.body.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
              AylaMsgActionButton(
                label: '收起', // tsx 52
                onPressed: () => setState(() => _open = false),
              ),
            ],
          ),
          if (!widget.connected)
            // tsx 56–57：`!call` → `.voice-list-empty`
            Padding(
              padding: const EdgeInsets.all(AylaSpacing.sp4),
              child: Text(
                widget.busy ? '接入中…' : '等待接入',
                textAlign: TextAlign.center,
                style: t.body.copyWith(
                  fontSize: 13,
                  color: AylaColors.textSecondary,
                ),
              ),
            )
          else ...<Widget>[
            if (!widget.isTerminal)
              Row(
                // `.elysia-voice-input { gap: var(--sp-2) }`
                spacing: AylaSpacing.sp2,
                children: <Widget>[
                  Expanded(
                    child: GlassInput(
                      controller: _text,
                      hintText: AylaElysiaVoicePanel.inputHint, // tsx 64
                      minHeight: 36, // 与 `.voice-create-input` 同档
                      padding: const EdgeInsets.symmetric(
                        horizontal: AylaSpacing.sp3,
                        vertical: 8,
                      ),
                      textStyle: t.body.copyWith(fontSize: 13),
                      semanticLabel: AylaElysiaVoicePanel.inputHint,
                      inputFormatters: <TextInputFormatter>[
                        // tsx 66 `maxLength={2000}`：用 formatter（`maxLength` 会带计数器）
                        LengthLimitingTextInputFormatter(
                          AylaElysiaVoicePanel.textMaxLength,
                        ),
                      ],
                      onSubmitted: (_) => unawaited(_submit()), // tsx 68–70：Enter 提交
                    ),
                  ),
                  GlassButton(
                    label: '发送', // tsx 78
                    variant: GlassButtonVariant.primary,
                    onPressed: _busy ? null : () => unawaited(_submit()),
                  ),
                ],
              ),
            Row(
              // `.elysia-voice-actions { gap: var(--sp-2) }`
              spacing: AylaSpacing.sp2,
              children: <Widget>[
                if (widget.isTerminal)
                  GlassButton(
                    label: '重新发起', // tsx 91
                    variant: GlassButtonVariant.primary,
                    onPressed: _busy
                        ? null
                        : () => unawaited(widget.onEnsureCall?.call() ?? Future<void>.value()),
                  )
                else
                  GlassButton(
                    label: '结束通话', // tsx 100
                    // `.btn.voice-leave-btn`（B1-1 已加的档）：透明底 + destructive 字 + 1px 边
                    variant: GlassButtonVariant.outlineDestructive,
                    onPressed: _busy
                        ? null
                        : () => unawaited(widget.onEndCall?.call() ?? Future<void>.value()),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 面板外壳：`.elysia-voice-panel` 的材质与盒模型（两态共用，只有 padding 不同）。
  Widget _shell({required double padding, required Widget child}) {
    return ConstrainedBox(
      // `max-width: 560px`
      constraints: const BoxConstraints(maxWidth: 560),
      child: GlassSurface(
        radiusOverride: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
        blur: AylaGlass.blurCard, // --glass-filter: blur(24px) saturate(1.4)
        shadow: AylaShadows.glass, // --glass-shadow
        padding: EdgeInsets.all(padding),
        child: child,
      ),
    );
  }
}

// ======================= 预览 =======================

/// 爱莉语音面板样张（画布与 @Preview 共用；**可交互**）。
///
/// ⚠️ web 里该组件**没有挂载点**，样张是唯一的视觉验收面（对照 `app.css:3122–3156`）。
///
/// - 收起档：单个 `.btn-glow`「爱莉语音」→ 点它展开；
/// - 已接入档：输入行（Enter 或「发送」）+「结束通话」；输入空文本 → 不进/不清空；
/// - 未接入档：`busy` 切换「接入中…」/「等待接入」；
/// - 终态档：行动区换成「重新发起」。
Widget aylaElysiaVoicePanelSamples() => const _ElysiaVoicePanelDemo();

class _ElysiaVoicePanelDemo extends StatefulWidget {
  const _ElysiaVoicePanelDemo();

  @override
  State<_ElysiaVoicePanelDemo> createState() => _ElysiaVoicePanelDemoState();
}

class _ElysiaVoicePanelDemoState extends State<_ElysiaVoicePanelDemo> {
  bool _busy = false;
  bool _connected = true;
  bool _terminal = false;
  int _sent = 0;
  String _last = '—';

  Future<bool> _send(String text) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // web `sendText` 的语义：空文本不受理 ⇒ 面板不清空
    if (text.trim().isEmpty) return false;
    setState(() {
      _sent++;
      _last = text.trim();
    });
    return true;
  }

  /// [terminalOverride] 供「终态档」单独展示；不传则跟随演示状态
  /// （点「结束通话」后第一档会切成「重新发起」）。
  AylaElysiaVoicePanel _panel({bool? terminalOverride}) {
    return AylaElysiaVoicePanel(
      connected: _connected,
      busy: _busy,
      isTerminal: terminalOverride ?? _terminal,
      onEnsureCall: () async {
        setState(() => _busy = true);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        setState(() {
          _busy = false;
          _connected = true;
          _terminal = false;
        });
      },
      onSubmitText: _send,
      onEndCall: () async {
        setState(() => _busy = true);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        setState(() {
          _busy = false;
          _terminal = true;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '收起档 → 点「爱莉语音」展开（已发送 $_sent 条，最后一条「$_last」）',
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: AylaSpacing.sp2),
              _panel(),
            ],
          ),
        ),
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('未接入档（busy 切换「接入中…」/「等待接入」）',
                  style: TextStyle(fontSize: 11)),
              const SizedBox(height: AylaSpacing.sp2),
              AylaElysiaVoicePanel(
                connected: false, // 未接入档
                busy: _busy,
                onEnsureCall: () async {
                  setState(() => _busy = true);
                  await Future<void>.delayed(const Duration(milliseconds: 600));
                  setState(() {
                    _busy = false;
                    _connected = true;
                  });
                },
              ),
            ],
          ),
        ),
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('终态档：行动区 =「重新发起」', style: TextStyle(fontSize: 11)),
              const SizedBox(height: AylaSpacing.sp2),
              _panel(terminalOverride: true),
            ],
          ),
        ),
        SizedBox(
          width: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              const Text('驱动开关', style: TextStyle(fontSize: 11)),
              GlassButton(
                label: _busy ? 'busy = true（三按钮禁用）' : 'busy = false',
                variant: GlassButtonVariant.ghost,
                minHeight: 32,
                fontSize: 12,
                onPressed: () => setState(() => _busy = !_busy),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 爱莉语音面板（收起 / 已接入 / 未接入 / 终态）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '爱莉语音面板（收起 + 输入注入 + 结束/重新发起）',
  size: Size(1800, 620),
  wrapper: previewTheme,
)
Widget aylaElysiaVoicePanelPreview() => aylaElysiaVoicePanelSamples();
