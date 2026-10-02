/// 群表情包面板**网格溢出**回归锁 —— 真机尺寸 + 真实宿主约束（2026-10-02 用户真机验收）。
///
/// ## 现象（Lead 真机截图 + 语义树）
/// 打开群表情包面板后，面板底部三格下方出现红色 `OVERFLOWED BY 17 PIXELS` 徽标。
///
/// ## 根因（本文件用探针逐帧定位，非猜测）
/// 溢出的 RenderFlex **不是面板、也不是网格**，而是**格子里的图片失败占位**：
/// `resource_image.dart:455–503` 的 `_FailedPlaceholder` 是纵向 Column =
/// 「fallback 块（`.emoji-pack-img-fallback { width/height: 100% }` ⇒ 整格 54.5）」
/// + 「失败芯片（`.resource-image-fallback { min-height: 32px }`）」= **86.5**，
/// 而表情格是固定正方形（`.emoji-pack-item { aspect-ratio: 1 }`，app.css 2234–2246）
/// ⇒ 54.5² 的格子里 86.5 的内容被测量为 **overflow 17px**。
/// 探针原文：`constraints: BoxConstraints(w=54.5, h=54.5)` / `size: Size(54.5, 54.5)` /
/// `Column ← _FailedPlaceholder ← AylaResourceImage ← ClipRRect ← … ← AspectRatio`。
///
/// ## web 侧同一 DOM 为什么不报错（以 web 为准）
/// `ResourceImage.tsx:148–167` 失败态渲染
/// `<span class="resource-image-failed-wrap">{fallback}<span class="resource-image-fallback">芯片</span></span>`，
/// 而表情格 `.emoji-pack-item` 里 `.emoji-pack-img-fallback { width: 100%; height: 100% }`
/// （app.css 2265–2271）= 铺满整格，芯片随其后被按钮裁掉、**不可见**。
/// ⇒ 可见结果 = 「只有铺满的灰底占位」，这正是 `live/danmaku.dart:415–422` 已拍板过的
/// 同源处置（"失败态照实渲染，芯片被 overflow 裁掉不可见"）。
///
/// ## 本文件的锁
/// ① 真机逻辑尺寸 1265.6×682.4（DPR 1.3 下的逻辑宽高）+ 真实宿主（composer 在底、
///    面板经 root Overlay 向上弹）⇒ `takeException() == null`（修复前 3× overflow）；
/// ② 宽屏 1600×900 / 窄屏 400×700 各一条「无溢出」；
/// ③ 面板高度上限（宽屏 280 / 窄屏 40vh）。
///
/// ⚠️ 用例**不启用示例图**（不调 `aylaEnableSampleMedia`）并显式
/// `MediaSigner.detach()`：测试进程里签名链路没有 `DioClient` ⇒ 图片确定性进入
/// **失败态**（这正是真机 minio 不可用时的同一状态）。图片加载链路本身**不在本任务范围**，
/// 本文件只锁「失败态在固定正方形格里的布局」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/media/voice_recorder.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/emoji_item.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/models/post.dart' show AylaMediaDescriptor;
import '../lib/core/models/user_public.dart';
import '../lib/theme/buttons.dart' show AylaToolButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/emoji_pack_panel.dart';
import '../lib/widgets/chat/message_input.dart';

AylaEmojiItem _emoji(String id) => AylaEmojiItem(
      id: id,
      media: AylaMediaDescriptor(
        mediaId: 'emoji-$id',
        kind: AylaMediaKind.emoji,
        mimeType: 'image/png',
        size: 12000,
        width: 240,
        height: 240,
        status: 'ready',
      ),
    );

AylaConversationMember _member(String id) => AylaConversationMember(
      id: 'm-$id',
      user: AylaUserPublic(id: id, nickname: 'u$id', username: 'u$id'),
    );

/// 「群表情包」工具键（按 [AylaToolButton.semanticLabel] 精确定位：面板标题同名，不能按文案找）。
Finder _emojiKey() => find.byWidgetPredicate(
      (Widget w) => w is AylaToolButton && w.semanticLabel == '群表情包',
    );

Finder _panel() => find.byType(AylaEmojiPackPanel);

/// 失败芯片（`resource_image.dart:489–495` 的文案）——用来**证明**用例跑的是
/// **失败态**而不是就绪态（否则「无溢出」可能只是因为图片加载成功）。
///
/// ⚠️ 不用 `find.bySemanticsLabel('图片加载失败，重试')`：那个 `Semantics` 会把后代
/// `Text` 合并进同一节点（label 变成两行拼接）⇒ 精确匹配必落空（实测 0 命中）。
Finder _failedChip() => find.text('图片加载失败，点击重试');

/// 格子的可见框（`.emoji-pack-item`，即 `AspectRatio(aspectRatio: 1)` 外壳）。
Finder _cell(int index) => find
    .descendant(of: _panel(), matching: find.byType(AspectRatio))
    .at(index);

void main() {
  setUp(() {
    // 没有 DioClient ⇒ 签名必然失败 ⇒ 图片确定性进入失败态（真机 minio 不可用同态）。
    MediaSigner.instance.detach();
  });
  tearDown(MediaSigner.instance.detach);

  /// 真实宿主：消息区在上（[Expanded]）、composer 贴底 —— 与
  /// `group_chat_page.dart:570–686` 的 `Column[Expanded(消息区), Padding(composer)]` 同构。
  /// 宽屏面板由 [AylaMessageInput] 插 root Overlay 向上弹，锚点取 composer 的真实矩形。
  Widget host(
    WidgetTester tester,
    Size viewport, {
    required bool narrow,
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewTheme(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Expanded(child: SizedBox.expand()),
            AylaMessageInput(
              onSubmit: (_) {},
              draftKey: 'emoji-overflow',
              groupId: 'g1',
              narrow: narrow,
              showEmojiButton: true,
              members: <AylaConversationMember>[_member('u1')],
              voiceRecorder: AylaNoopVoiceRecorder(),
              emojiPanel: AylaEmojiPackPanel(
                narrow: narrow,
                myRole: 'admin',
                onClose: () {},
                onSendEmoji: (_) async {},
                onAddEmoji: (_) async {},
                data: AylaEmojiPackData(
                  packId: 'p1',
                  canUploadFromPack: true,
                  summaryLoaded: true,
                  items: <AylaEmojiItem>[_emoji('a'), _emoji('b'), _emoji('c')],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 开面板并等失败态落地（失败是异步的：initState 的 `_load()` 走 microtask）。
  Future<void> openPanel(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_emojiKey());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 断言「失败芯片被裁到格子可见区之外」+「fallback 铺满整格」。
  ///
  /// 依据：`.emoji-pack-item`（web 的 `<button>`，`aspect-ratio: 1`）对超出自身框的内容
  /// **静默裁剪**（CSS `overflow: hidden`；app.css 2265–2271 的注释原文就是
  /// 「56px 小格内不显示重试按钮」）；Flutter 侧由 [ClipRect]+[OverflowBox] 表达。
  Future<void> _expectChipClippedBelowCell(WidgetTester tester) async {
    final Rect cell = tester.getRect(_cell(0));
    final Rect chip = tester.getRect(_failedChip().first);
    expect(
      chip.top,
      greaterThanOrEqualTo(cell.bottom - 0.5),
      reason: '★ 芯片必须**整块**在格子可见区之下（部分可见就与 web 不一致）'
          '：cell=$cell chip=$chip',
    );
    // fallback 铺满整格（`.emoji-pack-img-fallback { width: 100%; height: 100% }`）。
    // ⚠️ 基准是**内容盒**：`.emoji-pack-item` 有 `border: 1px` 且全局
    // `box-sizing: border-box`（base.css:6–8）⇒ `width: 100%` 解析到内容盒
    // = 格子 − 每边 1px（实测 57 → 55、55 → 53）。
    final Rect fallback = tester.getRect(
      find.descendant(of: _cell(0), matching: find.byType(ColoredBox)).first,
    );
    final Rect content = cell.deflate(1);
    expect(fallback.width, moreOrLessEquals(content.width, epsilon: 0.5));
    expect(fallback.height, moreOrLessEquals(content.height, epsilon: 0.5));
  }

  // ======================= ① 复现（修前红 ⇒ 修后绿） =======================

  testWidgets('★ 复现：真机逻辑尺寸 1265.6×682.4（宽屏档）打开 3 格面板 ⇒ 无溢出', (
    WidgetTester tester,
  ) async {
    // 真机环境：窗口逻辑 1265.6×682.4、DPR 1.3（宽屏档）。
    // MediaQuery.size = physicalSize / DPR（本用例 DPR 归一为 1.0，取同一**逻辑**尺寸）。
    const Size realDevice = Size(1265.6, 682.4);
    await tester.pumpWidget(host(tester, realDevice, narrow: false));
    await openPanel(tester);

    expect(_panel(), findsOneWidget, reason: '面板要真的开出来（否则下面的断言无意义）');
    // ★ 修复前：3 格各报一次「A RenderFlex overflowed by 17 pixels on the bottom」
    //   （_FailedPlaceholder 的 Column：fallback 54.5 + 芯片 32 = 86.5 > 54.5）。
    expect(
      tester.takeException(),
      isNull,
      reason: '★ 本任务的核心判据：固定正方格里失败占位不得产生 RenderFlex overflow',
    );
    // 证明跑的确实是**失败态**（否则"无溢出"可能只是图片加载成功了）。
    expect(_failedChip(), findsNWidgets(3), reason: 'no DioClient ⇒ 三格都该是失败态');
    expect(find.byType(AylaResourceImage), findsNWidgets(3));

    // ★ 可见结果与 web 逐条对齐：芯片**整块落在格子可见区之下**（被裁掉、不可见），
    //   而 fallback（`width/height: 100%`）铺满整格 —— 这正是
    //   app.css:2265–2271 注释原文「56px 小格内不显示重试按钮」的实现。
    await _expectChipClippedBelowCell(tester);
  });

  // ======================= ② 宽屏 / 窄屏「无溢出」 =======================

  testWidgets('宽屏 1600×900：打开面板无溢出', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, const Size(1600, 900), narrow: false));
    await openPanel(tester);

    expect(_panel(), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(_failedChip(), findsNWidgets(3));
    await _expectChipClippedBelowCell(tester);
  });

  testWidgets('窄屏 400×700：打开面板无溢出（inline 向下展开）', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, const Size(400, 700), narrow: true));
    await openPanel(tester);

    expect(_panel(), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(_failedChip(), findsNWidgets(3));
    await _expectChipClippedBelowCell(tester);
  });

  // ======================= ③ 面板高度上限 =======================

  testWidgets('宽屏：面板高度 ≤ 280（`.emoji-pack-panel { max-height: 280px }`，app.css 2195）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, const Size(1600, 900), narrow: false));
    await openPanel(tester);

    final double height = tester.getSize(_panel()).height;
    expect(
      height,
      lessThanOrEqualTo(AylaEmojiPackPanel.wideMaxHeight),
      reason: '面板高度上限 280（app.css 2186–2204）',
    );
    // 面板向上弹：底沿不低于 composer 顶沿（app.css 的 bottom: calc(100% + 8px)）
    expect(
      tester.getBottomLeft(_panel()).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AylaMessageInput)).dy),
    );
  });

  testWidgets('窄屏：面板高度 ≤ 40% 视口高（`.emoji-pack-panel { max-height: 40vh }`，app.css 3211–3215）', (
    WidgetTester tester,
  ) async {
    const Size viewport = Size(400, 700);
    await tester.pumpWidget(host(tester, viewport, narrow: true));
    await openPanel(tester);

    final double height = tester.getSize(_panel()).height;
    expect(
      height,
      lessThanOrEqualTo(viewport.height * 0.4 + 0.01),
      reason: '窄屏 40vh = ${viewport.height * 0.4}（app.css 3211–3215）',
    );
  });

  // ======================= ④ 格几何：失败态不改变格子尺寸 =======================

  testWidgets('失败态下格子仍是正方形（`aspect-ratio: 1`），且整格宽度由网格列宽决定', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, const Size(1600, 900), narrow: false));
    await openPanel(tester);

    final Size cellSize = tester.getSize(_cell(0));
    expect(cellSize.width, moreOrLessEquals(cellSize.height, epsilon: 0.5),
        reason: '`.emoji-pack-item { aspect-ratio: 1 }`（app.css 2240）');
    expect(cellSize.width, greaterThanOrEqualTo(AylaEmojiPackPanel.cellMinSize),
        reason: '列宽下限 minmax(56px, 1fr)（app.css 2226）');
  });
}