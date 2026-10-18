/// 服务根地址唯一推导处：未注入时保持本地开发语义，注入后 HTTP/WS 同源换算。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/api_endpoint.dart';

void main() {
  test('未传 dart-define 时仍是本地回环地址（开发语义不变）', () {
    expect(aylaUsesConfiguredApiBase, isFalse);
    expect(aylaApiBase(), 'http://127.0.0.1:8100');
  });

  test('aylaWsBase 从未配置根地址推导 ws://', () {
    expect(aylaWsBase(), 'ws://127.0.0.1:8100');
  });

  test('aylaAbsoluteApiUrl 只补一次 /api/v1', () {
    expect(
      aylaAbsoluteApiUrl('/media/abc/content'),
      'http://127.0.0.1:8100/api/v1/media/abc/content',
    );
    expect(
      aylaAbsoluteApiUrl('/api/v1/media/abc/content'),
      'http://127.0.0.1:8100/api/v1/media/abc/content',
    );
  });
}
