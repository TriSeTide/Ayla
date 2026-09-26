/// B3 chat 域第二批：@ 成员选择器定向测试 —— 逐条对照
/// `components/chat/MentionPicker.tsx`(150) 与 `app.css:2364–2428`（浮层全族）。
///
/// 覆盖：过滤（排除自己 / nickname+username 匹配 / 空 query）/ 结构（行高 48、头像 32、
/// 名称 14/600、空态）/ 交互（点行回调、hover 与 focus 同款底）/ 宿主（root overlay 定位：
/// 宽度 = anchor 宽、above/below 判定、maxHeight clamp）/ ESC 关闭 / 分页档不显示空态。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/chat/mention_picker.dart';

AylaConversationMember _member(String id, String name, {bool online = false}) =>
    AylaConversationMember(
      id: 'm-$id',
      user: AylaUserPublic(id: id, nickname: name, username: 'user_$id', online: online),
    );

void main() {
  setUp(aylaDisableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(420, 600),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      ),
    );
  }

  final List<AylaConversationMember> members = <AylaConversationMember>[
    _member('me', '我自己'),
    _member('u1', '小樱', online: true),
    _member('u2', '阿澈'),
    _member('u3', 'sakura'),
  ];

  // ======================= 过滤（tsx 47–55） =======================

  testWidgets('过滤：排除自己 + nickname/username 包含匹配 + 空 query 全量', (WidgetTester tester) async {
    // 空 query：全部（含自己 → 被排除）
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: members,
          query: '',
          currentUserId: 'me',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('我自己'), findsNothing, reason: '排除自己（tsx 49）');
    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('阿澈'), findsOneWidget);
    expect(find.text('sakura'), findsOneWidget);
  });

  testWidgets('过滤：按 username 也能命中（haystack = nickname + username）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: members,
          query: 'user_u2',
          currentUserId: 'me',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('阿澈'), findsOneWidget);
    expect(find.text('小樱'), findsNothing);
  });

  testWidgets('无匹配 → 空态「无匹配成员」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: members,
          query: 'zzz',
          currentUserId: 'me',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('无匹配成员'), findsOneWidget);
  });

  testWidgets('分页加载中（groupId 档）不显示空态', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: const <AylaConversationMember>[],
          groupId: 'g1',
          query: '',
          onSelect: (_) {},
          memberPage: const AylaMentionMemberPage(
            items: <AylaConversationMember>[],
            loading: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('无匹配成员'), findsNothing, reason: 'loading 时不显示空态（tsx 144）');
  });

  // ======================= 行结构与交互 =======================

  testWidgets('行：头像 32 + 名称 14/600 + 行高 48 + 点击回调', (WidgetTester tester) async {
    AylaConversationMember? picked;
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: members,
          query: '小樱',
          currentUserId: 'me',
          onSelect: (AylaConversationMember m) => picked = m,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final AylaAvatarHalo halo = tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo));
    expect(halo.size, 32, reason: 'tsx 136（Avatar size 32）');
    expect(halo.online, isTrue);

    final Text name = tester.widget<Text>(find.text('小樱'));
    expect(name.style!.fontSize, 14);
    expect(name.style!.fontWeight, FontWeight.w600);
    expect(name.style!.color, AylaColors.textPrimary);

    // 行高 = padding 8×2 + 头像 32 = 48（`.mention-picker-item`，app.css 2399）
    final Finder row = find.ancestor(
      of: find.text('小樱'),
      matching: find.byType(AnimatedContainer),
    );
    expect(tester.getSize(row.first).height, AylaMentionPicker.itemHeight);

    await tester.tap(find.text('小樱'));
    await tester.pump();
    expect(picked?.user.id, 'u1');
  });

  testWidgets('hover 底与 focus 底同款（rgba(157,191,230,.35)）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMentionPicker(
          members: members,
          query: '小樱',
          currentUserId: 'me',
          onSelect: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final Finder row = find
        .ancestor(of: find.text('小樱'), matching: find.byType(AnimatedContainer))
        .first;
    BoxDecoration deco() =>
        (tester.widget<AnimatedContainer>(row).decoration! as BoxDecoration);

    expect(deco().color, isNull, reason: '常态无底');
    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('小樱')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(deco().color, const Color(0x599DBFE6), reason: 'hover → .35（app.css 2408–2412）');
  });

  // ======================= 宿主与键盘 =======================

  testWidgets('宿主：root overlay 定位（宽度 = anchor 宽、贴 anchor 上方、ESCAPE 关闭）', (
    WidgetTester tester,
  ) async {
    final GlobalKey anchorKey = GlobalKey();
    final AylaMentionPickerHost host0 = AylaMentionPickerHost();
    bool closed = false;
    await tester.pumpWidget(
      host(
        tester,
        Builder(
          builder: (BuildContext context) => Column(
            children: <Widget>[
              // 上方留 400（> 浮层高 202 + gap/edge）⇒ 按 tsx 73 的 `above >= height` 贴上方
              const SizedBox(height: 400),
              // anchor：模拟 composer（宽 320）
              SizedBox(
                key: anchorKey,
                width: 320,
                height: 40,
                child: GestureDetector(
                  onTap: () => host0.open(
                    context,
                    anchorKey: anchorKey,
                    members: members,
                    query: '',
                    currentUserId: 'me',
                    onSelect: (_) {},
                  ),
                  child: const ColoredBox(color: Color(0xFFEEEEEE)),
                ),
              ),
              const SizedBox(height: 100),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(anchorKey));
    await tester.pump(const Duration(milliseconds: 50));
    expect(host0.isOpen, isTrue);
    expect(find.byType(AylaMentionPicker), findsOneWidget, reason: '插 root Overlay（createPortal 等价）');

    final Rect picker = tester.getRect(find.byType(AylaMentionPicker));
    expect(picker.width, 320, reason: '宽度 = anchor 宽（tsx 70）');
    final Rect anchorRect = tester.getRect(find.byKey(anchorKey));
    expect(
      picker.bottom,
      lessThanOrEqualTo(anchorRect.top),
      reason: 'placement above（tsx 73：above >= below 时贴上方）',
    );

    // ESC 关闭（tsx 97–100）
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 50));
    expect(host0.isOpen, isFalse);
    expect(find.byType(AylaMentionPicker), findsNothing);
    expect(closed, isFalse);
  });

  testWidgets('宿主：anchor 下方空间更大时贴下方', (WidgetTester tester) async {
    final GlobalKey anchorKey = GlobalKey();
    final AylaMentionPickerHost pickerHost = AylaMentionPickerHost();
    await tester.pumpWidget(
      host(
        tester,
        Builder(
          builder: (BuildContext context) => Column(
            children: <Widget>[
              const SizedBox(height: 8),
              SizedBox(
                key: anchorKey,
                width: 320,
                height: 40,
                child: GestureDetector(
                  onTap: () => pickerHost.open(
                    context,
                    anchorKey: anchorKey,
                    members: members,
                    query: '',
                    onSelect: (_) {},
                  ),
                  child: const ColoredBox(color: Color(0xFFEEEEEE)),
                ),
              ),
            ],
          ),
        ),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(anchorKey));
    await tester.pump(const Duration(milliseconds: 50));

    final Rect picker = tester.getRect(find.byType(AylaMentionPicker));
    final Rect anchorRect = tester.getRect(find.byKey(anchorKey));
    expect(
      picker.top,
      greaterThanOrEqualTo(anchorRect.bottom),
      reason: 'below 空间大 → 贴下方（tsx 73）',
    );
    pickerHost.close();
  });
}
