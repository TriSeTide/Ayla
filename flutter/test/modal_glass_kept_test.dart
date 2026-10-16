/// 弹层材质锁（2026-10-16 用户裁决：「改成和 web 一样的」= 保持真玻璃）。
///
/// ## 背景
/// 性能调研曾提出「把弹层玻璃件降档为 `AylaGlassQuality.opaque` 以省 raster 开销」——
/// 那**会改变观感**（web 的弹层是真玻璃：`--glass-bg-strong` + `--glass-filter`，
/// 见 `private.css` 的 `.create-sheet-card`、`share.css` 的 `.share-sheet-card` 等）。
/// 用户裁决：**保持与 web 一致（真玻璃），不做降档**。
///
/// 本文件把该裁决固化为回归锁（三条互补，避免恒真断言）：
/// 1. 默认质量档 = realBackdrop；
/// 2. 弹层卡在默认档下**卡内确有 BackdropFilter**（真玻璃）；
/// 3. 切到 opaque 档后**卡内 BackdropFilter 归零** —— 这一条同时证明 ② 有辨别力
///    （若 ② 是恒真，③ 就不可能归零）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/dialogs.dart';

void main() {
  tearDown(() {
    // 每个用例后复位全局档，避免污染其它测试。
    AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
  });

  test('默认质量档必须是 realBackdrop（web 的弹层是真玻璃）', () {
    expect(AylaGlassConfig.quality, AylaGlassQuality.realBackdrop,
        reason: '性能档只是可选兜底；默认必须与 web 一致');
    expect(AylaGlassConfig.useOpaqueFallback, isFalse);
  });

  testWidgets('弹层卡：默认档 ⇒ 卡内有 BackdropFilter（真玻璃）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 350));
    expect(_cardBackdrops(), greaterThan(0),
        reason: 'web 弹层是真玻璃（--glass-bg-strong + --glass-filter）');
  });

  testWidgets('弹层卡：opaque 档 ⇒ 卡内 BackdropFilter 归零（证明上一条有辨别力）', (
    WidgetTester tester,
  ) async {
    AylaGlassConfig.quality = AylaGlassQuality.opaque;
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 350));
    expect(_cardBackdrops(), 0,
        reason: '实底档整层不装滤镜（dialogs.dart 的 `if (!opaque)` 分支）');
  });
}

/// 弹层卡**内部**（不含外层宿主）的 BackdropFilter 数。
///
/// ⚠️ 不用 `find.descendant` —— 实测它在 `of: AylaModalCard` 时会把卡片**自身**
/// 套的 Stack/face 一并计入，导致两档都读到 1（假读数）。改为按元素祖先链判定：
/// 只统计「祖先里确实经过 AylaModalCard」且「不是宿主背景」的那些。
int _cardBackdrops() {
  int n = 0;
  for (final Element e in find.byType(BackdropFilter).evaluate()) {
    bool insideCard = false;
    e.visitAncestorElements((Element a) {
      if (a.widget is AylaModalCard) {
        insideCard = true;
        return false;
      }
      return true;
    });
    if (insideCard) n++;
  }
  return n;
}

Widget _host() => MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) =>
              AylaModalCard(child: const Text('弹层内容')),
        ),
      ),
    );