/// 更新检查响应解析 + 请求参数的契约（不触网：直接调 fromJson / 用假 DioClient）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/update/update_api.dart';

Map<String, dynamic> _body({
  bool available = true,
  bool mandatory = false,
  bool degraded = false,
}) {
  return <String, dynamic>{
    'update_available': available,
    'mandatory': mandatory,
    'degraded': degraded,
    'reason': available ? 'update_available' : 'up_to_date',
    'channel': 'stable',
    'current': <String, dynamic>{'version': '1.0.0', 'build': 1},
    'latest': <String, dynamic>{
      'release_id': 'stable-1.0.1-2',
      'version': '1.0.1',
      'build': 2,
      'published_at': '2026-10-18T12:00:00Z',
      'notes': '修复若干问题',
      'min_supported_build': 0,
    },
    'download': <String, dynamic>{
      'kind': 'zip',
      'url': '/releases/stable/windows/1.0.1+2/ayla.zip',
      'file_name': 'ayla.zip',
      'size': 1234,
      'sha256': 'a' * 64,
      'install_url': null,
    },
  };
}

void main() {
  group('AylaUpdateCheck.fromJson', () {
    test('有更新：解析 latest/download，相对下载地址补 origin', () {
      final AylaUpdateCheck check = AylaUpdateCheck.fromJson(_body());
      expect(check.updateAvailable, isTrue);
      expect(check.latest!.build, 2);
      expect(check.download!.sha256, 'a' * 64);
      expect(
        check.download!.url.startsWith('http://127.0.0.1:8100/releases/'),
        isTrue,
      );
      expect(check.hasVisibleUpdate, isTrue);
    });

    test('无更新：latest/download 为 null 也不抛', () {
      final AylaUpdateCheck check = AylaUpdateCheck.fromJson(<String, dynamic>{
        ..._body(available: false),
        'latest': null,
        'download': null,
      });
      expect(check.updateAvailable, isFalse);
      expect(check.hasVisibleUpdate, isFalse);
      expect(check.latest, isNull);
      expect(check.download, isNull);
    });

    test('degraded 清单不可用：解析为 degraded，不当成有更新', () {
      final AylaUpdateCheck check = AylaUpdateCheck.fromJson(<String, dynamic>{
        ..._body(available: false),
        'degraded': true,
        'reason': 'manifest_unavailable',
        'latest': null,
        'download': null,
      });
      expect(check.degraded, isTrue);
      expect(check.hasVisibleUpdate, isFalse);
      expect(check.reason, 'manifest_unavailable');
    });

    test('update_available=true 但缺 download ⇒ 抛异常（不伪造）', () {
      expect(
        () => AylaUpdateCheck.fromJson(<String, dynamic>{
          ..._body(),
          'download': null,
        }),
        throwsA(isA<AylaUpdateException>()),
      );
    });

    test('sha256 非 64 hex ⇒ 抛异常', () {
      final Map<String, dynamic> body = _body();
      (body['download'] as Map<String, dynamic>)['sha256'] = 'zz';
      expect(
        () => AylaUpdateCheck.fromJson(body),
        throwsA(isA<AylaUpdateException>()),
      );
    });

    test('download.url scheme 白名单：javascript: 被拒绝', () {
      final Map<String, dynamic> body = _body();
      (body['download'] as Map<String, dynamic>)['url'] = 'javascript:alert(1)';
      expect(
        () => AylaUpdateCheck.fromJson(body),
        throwsA(isA<AylaUpdateException>()),
      );
    });
  });

  test('平台/架构标识只返回后端允许的值', () {
    expect(<String>[
      'windows',
      'android',
      'ios',
      'macos',
      'linux',
      'web',
      'unknown',
    ], contains(aylaUpdatePlatform()));
    expect(<String>['', 'x64', 'arm64', 'armv7'], contains(aylaUpdateArch()));
  });
}
