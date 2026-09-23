/// B2-1：弹幕输入条定向测试 —— 逐条对照 `components/live/DanmakuInput.tsx`(180)
/// 与 `app.css:3764–3827`、`auroraqua.css:347–359 / 378–383 / 390（≥769）`、
/// `auroraqua.css:502–523（字段族）`、`live.css:777–784`。
///
/// 覆盖：三段结构 / 关键尺寸（图片钮 40、发送钮 min-width 72、输入 padding 8-12）/
/// 计数与上限 / 发送成功清空 + 焦点回输入框 / 失败保留草稿 / 图片「选→传→发」
/// 三步与两种失败态的重试语义（上传失败重传同一文件、发送失败复用 media_id）/
/// 发送中**不禁用输入框** / 材质两档 / ownerKey 重置草稿。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart' show AylaPickedFile;
import '../lib/core/media/media_upload.dart' show AylaUploadException;
import '../lib/core/net/dio_client.dart' show ApiException;
import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/danmaku.dart';

AylaPickedFile _file([String name = 'pic.jpg']) => AylaPickedFile(
  name: name,
  size: 1024,
  mimeType: 'image/jpeg',
  readBytes: () async => throw UnimplementedError('样张/测试不读字节'),
);

void main() {
  /// 视口显式钉死（默认测试窗口物理 800×600 / DPR 3 ⇒ 逻辑仅 266×200）。
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(560, 180),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 输入框（web `input.danmaku-input`）与两个按钮。
  Finder input() => find.byType(GlassInput);
  Finder sendButton() => find.byWidgetPredicate(
    (Widget w) => w is GlassButton && w.semanticLabel == '发送弹幕',
  );
  Finder imageButton() => find.byWidgetPredicate(
    (Widget w) => w is GlassButton && w.semanticLabel == '发送弹幕图片',
  );

  group('结构与样式', () {
    testWidgets('三段结构 + 图片钮 40×40 + 发送钮 min-width 72（live.css 779–784）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => true)),
      );
      await settle(tester);

      final GlassButton image = tester.widget<GlassButton>(imageButton());
      expect(image.minHeight, 40);
      expect(image.minWidth, 40); // `.danmaku-image-btn.btn { width: 40; height: 40; padding: 0 }`
      expect(image.padding, EdgeInsets.zero);
      expect(image.variant, GlassButtonVariant.ghost);
      expect(image.glowBorderOnHover, isTrue); // hover/focus 只换 glow 边
      expect(tester.getSize(imageButton()), const Size(40, 40));

      final GlassButton send = tester.widget<GlassButton>(sendButton());
      expect(send.minWidth, 72); // `.danmaku-send-btn { min-width: 72px }`
      expect(send.variant, GlassButtonVariant.primary);
      expect(tester.getSize(sendButton()).width, greaterThanOrEqualTo(72));

      // 图标尺寸：IconImage 17 / IconSend 16（tsx 130/166）
      expect(
        find.descendant(
          of: imageButton(),
          matching: find.byWidgetPredicate((Widget w) => w is AylaIcon && w.size == 17),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sendButton(),
          matching: find.byWidgetPredicate((Widget w) => w is AylaIcon && w.size == 16),
        ),
        findsOneWidget,
      );

      // 输入框：placeholder「发条弹幕吧」/ 单行 / padding sp2 sp3 / 行高 40
      final GlassInput field = tester.widget<GlassInput>(input());
      expect(field.hintText, '发条弹幕吧');
      expect(field.maxLines, 1);
      expect(field.minHeight, 40);
      expect(
        field.padding,
        const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: AylaSpacing.sp2,
        ),
      );
      // 默认档：上边框 1px + padding sp3（3764–3767）
      final Container area = tester.widget<Container>(
        find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ).first,
      );
      expect(
        (area.decoration! as BoxDecoration).border,
        const Border(top: BorderSide(color: AylaColors.glassBorder)),
      );
      expect(area.padding, const EdgeInsets.all(AylaSpacing.sp3));
    });

    testWidgets('narrowCard 档：玻璃底在组件自身（live.css 768–772：--glass-bg + blur18 sat1.4，无边/无阴影/无圆角）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            material: AylaDanmakuInputMaterial.narrowCard,
          ),
        ),
      );
      await settle(tester);

      final GlassSurface surface = tester.widget<GlassSurface>(
        find.byType(GlassSurface),
      );
      expect(surface.blur, AylaGlass.blurNav); // blur(18px) saturate(1.4)
      expect(surface.strong, isFalse); // --glass-bg（不是 strong .78）
      expect(surface.border, isFalse); // 包装层无边
      expect(surface.shadow, isEmpty); // 未声明 box-shadow
      expect(surface.radiusOverride, BorderRadius.zero); // 包装层无圆角
      // 内部仍是 `.danmaku-input-area` 自身：padding sp3 + 上边框 1px
      final Container area = tester.widget<Container>(
        find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ).first,
      );
      expect(area.padding, const EdgeInsets.all(AylaSpacing.sp3));
      expect(
        (area.decoration! as BoxDecoration).border,
        const Border(top: BorderSide(color: AylaColors.glassBorder)),
      );
      // 玻璃底确实铺在输入行下面（宽 = 组件宽，不含 margin——只有 sideCard 档才有 margin）
      expect(
        tester.getSize(find.byType(GlassSurface)).width,
        tester.getSize(find.byType(AylaDanmakuInput)).width,
      );
    });

    testWidgets('sideCard 档（宽屏直播侧栏卡内）：**无玻璃底**、只有上边框分隔线 + margin 12 / padding 8（auroraqua 347–359 被 555–567 清零）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            material: AylaDanmakuInputMaterial.sideCard,
          ),
        ),
      );
      await settle(tester);

      // 347–359 那套玻璃材质在这条链路上永不生效 ⇒ 组件里**没有** GlassSurface
      expect(find.byType(GlassSurface), findsNothing);
      // margin: var(--sidebar-gutter)（由外层 Padding 表达）
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Padding &&
              w.padding == const EdgeInsets.all(AylaSpacing.sidebarGutter),
        ),
        findsOneWidget,
      );
      // 区域自身：padding sp2（被 auroraqua 覆写）+ 仅上边框 + 透明底 + 方角
      final Container area = tester.widget<Container>(
        find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ).first,
      );
      expect(area.padding, const EdgeInsets.all(AylaSpacing.sp2));
      final BoxDecoration decoration = area.decoration! as BoxDecoration;
      expect(decoration.color, isNull); // background: transparent
      expect(
        decoration.border,
        const Border(top: BorderSide(color: AylaColors.glassBorder)),
      );
      expect(decoration.borderRadius, isNull); // border-radius: 0
    });

    testWidgets('计数按 trim 长度 / 上限 400 由 formatter 兜底（tsx 150/174）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => true)),
      );
      await settle(tester);
      expect(find.text('0/200'), findsOneWidget);

      await tester.enterText(input(), '  你好  ');
      await settle(tester);
      expect(find.text('2/200'), findsOneWidget); // trim 后 2

      final GlassInput field = tester.widget<GlassInput>(input());
      expect(field.inputFormatters?.length, 1); // LengthLimitingTextInputFormatter(400)
    });
  });

  group('发送', () {
    testWidgets('空文本禁用发送钮（tsx 161）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => true)),
      );
      await settle(tester);
      expect(tester.widget<GlassButton>(sendButton()).onPressed, isNull);

      await tester.enterText(input(), '嗨');
      await settle(tester);
      expect(tester.widget<GlassButton>(sendButton()).onPressed, isNotNull);
    });

    testWidgets('发送成功 → 清空草稿 + 计数归零 + 焦点回输入框（tsx 59–66）', (WidgetTester tester) async {
      final List<(String, String?)> sent = <(String, String?)>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (String content, String? mediaId) async {
              sent.add((content, mediaId));
              return true;
            },
          ),
        ),
      );
      await settle(tester);

      await tester.enterText(input(), '第一条');
      await settle(tester);
      await tester.tap(sendButton());
      await settle(tester);

      expect(sent, <(String, String?)>[('第一条', null)]);
      expect(tester.widget<GlassInput>(input()).controller.text, isEmpty);
      expect(find.text('0/200'), findsOneWidget);
      // 焦点回到输入框（连续发弹幕不打断）
      expect(
        tester.widget<GlassInput>(input()).focusNode?.hasFocus,
        isTrue,
      );
    });

    testWidgets('发送失败（返回 false）保留草稿（tsx 55–68）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => false)),
      );
      await settle(tester);
      await tester.enterText(input(), '失败也不丢');
      await settle(tester);
      await tester.tap(sendButton());
      await settle(tester);
      expect(tester.widget<GlassInput>(input()).controller.text, '失败也不丢');
    });

    testWidgets('发送抛错 → `.live-form-error` 文案（destructive 13 + margin-top 8）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => throw const ApiException(400, '弹幕不能为空'),
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(input(), 'x');
      await settle(tester);
      await tester.tap(sendButton());
      await settle(tester);

      final Finder error = find.text('弹幕不能为空');
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).style?.color, AylaColors.destructive);
      expect(tester.widget<Text>(error).style?.fontSize, 13);
      expect(
        find.ancestor(
          of: error,
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding && w.padding == const EdgeInsets.only(top: AylaSpacing.sp2),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Enter 提交（tsx 154–156）', (WidgetTester tester) async {
      int count = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async {
              count += 1;
              return true;
            },
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(input(), '回车发送');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(count, 1);
      expect(tester.widget<GlassInput>(input()).controller.text, isEmpty);
    });

    testWidgets('外部 error 文案优先于计数显示（tsx 107/170）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            error: '频道已关闭',
          ),
        ),
      );
      await settle(tester);
      expect(find.text('频道已关闭'), findsOneWidget);
      expect(find.text('0/200'), findsNothing);
    });

    testWidgets('sending=true：输入框仍可用、两钮禁用（tsx 106/151）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => true, sending: true)),
      );
      await settle(tester);
      expect(tester.widget<GlassInput>(input()).enabled, isTrue);
      expect(tester.widget<GlassButton>(sendButton()).onPressed, isNull);
      expect(tester.widget<GlassButton>(imageButton()).onPressed, isNull);
    });
  });

  group('图片三步（tsx 84–105）', () {
    testWidgets('上传失败 → 「图片上传失败」+ 重试；重试**重传同一文件**（不重选）', (WidgetTester tester) async {
      int picks = 0;
      final List<AylaPickedFile> uploads = <AylaPickedFile>[];
      bool failUpload = true;
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            onPickImage: () async {
              picks += 1;
              return _file();
            },
            onUploadImage: (AylaPickedFile file, ValueChanged<double?> _) async {
              uploads.add(file);
              if (failUpload) throw const AylaUploadException('上传失败');
              return 'media-1';
            },
          ),
        ),
      );
      await settle(tester);

      await tester.tap(imageButton());
      await settle(tester);
      expect(picks, 1);
      expect(uploads.length, 1);
      expect(find.text('图片上传失败'), findsOneWidget); // tsx 113

      failUpload = false;
      await tester.tap(find.text('重试图片'));
      await settle(tester);
      expect(picks, 1); // 不重新打开选择器
      expect(uploads.length, 2);
      expect(
        identical(uploads.first, uploads.last),
        isTrue,
        reason: '重试必须重传**同一份文件**',
      );
      expect(find.text('图片上传失败'), findsNothing);
    });

    testWidgets('上传成功但发送失败 → 「图片发送失败」；重试**复用 media_id**（不重传）', (WidgetTester tester) async {
      int uploads = 0;
      final List<String?> sentMedia = <String?>[];
      bool failSend = true;
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (String content, String? mediaId) async {
              sentMedia.add(mediaId);
              if (failSend) return false;
              return true;
            },
            onPickImage: () async => _file(),
            onUploadImage: (AylaPickedFile file, ValueChanged<double?> _) async {
              uploads += 1;
              return 'media-9';
            },
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(input(), '配图弹幕');
      await settle(tester);

      await tester.tap(imageButton());
      await settle(tester);
      expect(uploads, 1);
      expect(sentMedia, <String?>['media-9']);
      expect(find.text('图片发送失败'), findsOneWidget); // tsx 113

      failSend = false;
      await tester.tap(find.text('重试图片'));
      await settle(tester);
      expect(uploads, 1, reason: '发送失败重试不得重新上传');
      expect(sentMedia, <String?>['media-9', 'media-9']);
      // 成功且草稿未被再编辑 → 清空
      expect(tester.widget<GlassInput>(input()).controller.text, isEmpty);
    });

    testWidgets('取消选择：无状态行、无错误（web `if (!file) return`）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            onPickImage: () async => null,
            onUploadImage: (_, _) async => 'media-x',
          ),
        ),
      );
      await settle(tester);
      await tester.tap(imageButton());
      await settle(tester);
      expect(find.text('图片上传失败'), findsNothing);
      expect(find.text('重试图片'), findsNothing);
    });

    testWidgets('本地校验失败 → 错误文案（不进入失败图片态）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            onPickImage: () async => throw const AylaUploadException('图片过大'),
            onUploadImage: (_, _) async => 'media-x',
          ),
        ),
      );
      await settle(tester);
      await tester.tap(imageButton());
      await settle(tester);
      expect(find.text('图片过大'), findsOneWidget);
      expect(find.text('重试图片'), findsNothing);
    });

    testWidgets('上传期间显示「图片上传中…」状态行（tsx 111–113）', (WidgetTester tester) async {
      final Completer<String> gate = Completer<String>();
      await tester.pumpWidget(
        host(
          tester,
          AylaDanmakuInput(
            onSend: (_, _) async => true,
            onPickImage: () async => _file(),
            onUploadImage: (_, _) => gate.future,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(imageButton());
      await tester.pump();

      expect(find.text('图片上传中…'), findsOneWidget);
      gate.complete('media-1');
      await settle(tester);
      expect(find.text('图片上传中…'), findsNothing);
    });

    testWidgets('未注入图片回调时按钮外观照常、点击无动作（不是 disabled）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(tester, AylaDanmakuInput(onSend: (_, _) async => true)),
      );
      await settle(tester);
      expect(tester.widget<GlassButton>(imageButton()).onPressed, isNotNull);
      expect(tester.getSize(imageButton()), const Size(40, 40));
      await tester.tap(imageButton());
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('ownerKey（web key = accountId:channelId）', () {
    testWidgets('换 owner → 草稿与失败态重置', (WidgetTester tester) async {
      // ⚠️ `previewScope` 的 `Overlay(initialEntries:)` 只在首次创建生效 ⇒ 同一用例里
      // 第二次 `pumpWidget` 换 props 不生效（§6.19/§6.21 已记录）→ 用 StatefulBuilder 驱动
      String owner = 'acc:1';
      late StateSetter setLocalState;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setLocalState = setState;
              return AylaDanmakuInput(
                onSend: (_, _) async => true,
                ownerKey: owner,
                onPickImage: () async => _file(),
                onUploadImage: (_, _) async =>
                    throw const AylaUploadException('上传失败'),
              );
            },
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(input(), '旧草稿');
      await tester.tap(imageButton());
      await settle(tester);
      expect(find.text('图片上传失败'), findsOneWidget);
      expect(tester.widget<GlassInput>(input()).controller.text, '旧草稿');

      setLocalState(() => owner = 'acc:2');
      await settle(tester);
      expect(tester.widget<GlassInput>(input()).controller.text, isEmpty);
      expect(find.text('图片上传失败'), findsNothing);
    });
  });
}
