/// 版本解析契约（Windows exe 的 1.0.0.1 与 Android 的 1.0.0+1 必须得到同一结果）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/app_version.dart';

void main() {
  group('parseAppVersion', () {
    test('三段的 versionName + 独立 buildNumber', () {
      final AylaAppVersion v = parseAppVersion(
        version: '1.2.3',
        buildNumber: '7',
      );
      expect(v.version, '1.2.3');
      expect(v.build, 7);
      expect(v.display, '1.2.3+7');
      expect(v.query, <String, String>{'version': '1.2.3', 'build': '7'});
    });

    test('Windows exe 的四段 FileVersion：前三段 version、第四段 build', () {
      final AylaAppVersion v = parseAppVersion(version: '1.0.0.12');
      expect(v.version, '1.0.0');
      expect(v.build, 12);
      expect(v.display, '1.0.0+12');
    });

    test('Flutter +build 形态优先于 buildNumber', () {
      final AylaAppVersion v = parseAppVersion(
        version: '2.1.0+9',
        buildNumber: '3',
      );
      expect(v.version, '2.1.0');
      expect(v.build, 9);
    });

    test('缺失段补 0；空输入回落 0.0.0+0（不抛异常）', () {
      expect(parseAppVersion(version: '1', buildNumber: '').version, '1.0.0');
      expect(parseAppVersion(version: '', buildNumber: '').display, '0.0.0');
      expect(parseAppVersion(version: '   ', buildNumber: 'abc').build, 0);
    });

    test('超过四段只取前三段 version + 第四段 build（不丢 build）', () {
      final AylaAppVersion v = parseAppVersion(version: '1.2.3.4.5');
      expect(v.version, '1.2.3');
      expect(v.build, 4);
    });

    test('非数字尾巴按数字前缀解析（FileVersion 的脏值不导致崩溃）', () {
      final AylaAppVersion v = parseAppVersion(version: '1.0.0.7-beta');
      expect(v.version, '1.0.0');
      expect(v.build, 7);
    });
  });
}
