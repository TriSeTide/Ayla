/// 字体回退链审计（**回归锁**）—— 防止新增「裸 TextStyle 缺 CJK 回退链」。
///
/// ## 背景（2026-09-28 用户实报）
/// 用户在语音/直播大厅看到侧栏标题「语音房间」「直播间」字体错乱：这两个件的
/// `TextStyle` 只写了 `fontFamily: AylaFonts.display`，**漏了
/// `fontFamilyFallback: AylaFonts.cjkFallback`** ⇒ Fredoka/Nunito/Space Grotesk
/// 都没有中文字形，中文于是落到**引擎默认字体**（Windows 上是系统 UI 字体），
/// 与 web 侧的 CJK 回退链（`app_theme.dart:4` 的全局约定）不一致。
///
/// ## 本测试锁两条
/// 1. **已修的两件不得回退**：`widgets/base/directory_page.dart`（目录侧栏 kicker/title/stats）
///    与 `widgets/base/page_state.dart`（placeholder 标题族）命中数必须为 **0**；
/// 2. **全库命中数必须为 0**：2026-09-28 用户批准后，chat / group / shell / player 等域的
///    同类缺失已一次性补齐（19 号 §11.8），本测试保证**不得回退**。
///
/// ## 判据（与人工审计同口径）
/// 逐个 `TextStyle(` 做括号配对取块：块内含 `AylaFonts.` 且**不含** `fontFamilyFallback`
/// ⇒ 命中。`t.body.copyWith(fontFamily: …)` 这类派生写法天然继承 fallback，不入判据。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 全库登记基线 —— **2026-09-28 用户批准全库统一补齐后已清零**。
///
/// 口径：这个数字**只允许是 0**。新增命中必须当场补 `fontFamilyFallback`，
/// 不要为了让它变绿而抬高基线。
const int kRegisteredMissingFallback = 0;

/// 本批已修、不得回退的两件。
const List<String> kFixedFiles = <String>[
  'widgets/base/directory_page.dart',
  'widgets/base/page_state.dart',
];

void main() {
  final List<({String path, int line})> hits = _scanMissingFallback();

  test('已修件（目录侧栏 + placeholder 标题族）不得回退', () {
    final List<({String path, int line})> fixed = hits
        .where((({String path, int line}) h) =>
            kFixedFiles.any((String f) => h.path.endsWith(f)))
        .toList();
    expect(
      fixed,
      isEmpty,
      reason: '这些 TextStyle 缺 fontFamilyFallback: AylaFonts.cjkFallback ⇒ '
          '中文会落到引擎默认字体：' +
          fixed.map((({String path, int line}) h) => '\n  ' + h.path + ':' + h.line.toString()).join(),
    );
  });

  test('全库命中数不得超过登记基线（只减不增）', () {
    expect(
      hits.length,
      lessThanOrEqualTo(kRegisteredMissingFallback),
      reason: '新增了缺 CJK 回退链的裸 TextStyle（共 ' +
          hits.length.toString() +
          ' 处，基线 ' +
          kRegisteredMissingFallback.toString() +
          '）。请给这些 TextStyle 补 '
              'fontFamilyFallback: AylaFonts.cjkFallback，或把修复后的新基线同步到本测试：' +
          hits
              .map((({String path, int line}) h) =>
                  '\n  ' + h.path + ':' + h.line.toString())
              .join(),
    );
  });
}

/// 扫描 `lib/**/*.dart`，返回缺 CJK 回退链的 `TextStyle(` 位置。
List<({String path, int line})> _scanMissingFallback() {
  final Directory root = Directory('lib');
  final List<({String path, int line})> hits = <({String path, int line})>[];
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final String src = entity.readAsStringSync();
    int index = src.indexOf('TextStyle(');
    while (index >= 0) {
      final int start = index + 'TextStyle('.length;
      int depth = 1;
      int i = start;
      while (i < src.length && depth > 0) {
        final String ch = src[i];
        if (ch == '(') {
          depth += 1;
        } else if (ch == ')') {
          depth -= 1;
        }
        i += 1;
      }
      final String body = src.substring(start, i);
      if (body.contains('AylaFonts.') && !body.contains('fontFamilyFallback')) {
        final int line = '\n'.allMatches(src.substring(0, index)).length + 1;
        hits.add((path: entity.path, line: line));
      }
      index = src.indexOf('TextStyle(', index + 1);
    }
  }
  return hits;
}
