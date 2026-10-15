/// 端到端确认（**需要真实后端 8100**）：六类单类档都返回可渲染的 items。
///
/// ⚠️ 本文件默认**跳过**（后端不可用时不应让全量测试变红）；
/// 设 `AYLA_E2E=1` 环境变量才真跑。CI/全量回归下它是 no-op。
///
/// 用裸 HttpClient 登录 + 请求（绕开 DioClient 的 tokenStore wiring），
/// 再把真实响应喂给 Flutter 的解析层（AylaSearchResults.fromJson）——
/// 这验证的是用户真机上那一环：切分类后内容区有数据可渲染。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/search_api.dart';

Future<Map<String, dynamic>> _getJson(String path, {String? token}) async {
  final HttpClient client = HttpClient();
  final HttpClientRequest req =
      await client.getUrl(Uri.parse('http://127.0.0.1:8100/api/v1$path'));
  if (token != null) req.headers.set('Authorization', 'Bearer $token');
  final HttpClientResponse resp = await req.close();
  final String body = await resp.transform(utf8.decoder).join();
  client.close();
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> data) async {
  final HttpClient client = HttpClient();
  final HttpClientRequest req =
      await client.postUrl(Uri.parse('http://127.0.0.1:8100/api/v1' + path));
  req.headers.contentType = ContentType.json;
  // ⚠️ skill 记录：daphne(ASGI) 不解析 chunked 请求体 ⇒ dart HttpClient 必须显式 contentLength
  final List<int> bytes = utf8.encode(jsonEncode(data));
  req.contentLength = bytes.length;
  req.add(bytes);
  final HttpClientResponse resp = await req.close();
  final String body = await resp.transform(utf8.decoder).join();
  client.close();
  return jsonDecode(body) as Map<String, dynamic>;
}

void main() {
  // ⚠️ 清掉 flutter_test 装的 HttpOverrides（否则任何 dart:io HTTP 都返回 400）
  HttpOverrides.global = null;
  final bool enabled = Platform.environment['AYLA_E2E'] == '1';

  test('真实后端：六类单类档都返回 items（切换后内容区有数据）', skip: !enabled, () async {
    final Map<String, dynamic> login = await _postJson('/auth/login/', <String, dynamic>{
      'username': '123',
      'password': '12345678',
    });
    final String token = login['access']?.toString() ?? '';
    expect(token.isNotEmpty, isTrue, reason: '登录必须拿到 access');

    const List<String> types = <String>[
      'user', 'group', 'post', 'live', 'voice', 'game',
    ];
    final List<String> report = <String>[];
    final List<String> empty = <String>[];
    for (final String t in types) {
      final Map<String, dynamic> raw = await _getJson(
        '/search/?q=123&pagination=cursor&limit=20&types=$t',
        token: token,
      );
      // 走 Flutter 真实解析层（不是只看 JSON）
      final AylaSearchResults parsed = AylaSearchResults.fromJson(raw);
      final int n = _count(parsed, t);
      report.add('$t=$n');
      if (n <= 0) empty.add(t);
    }
    debugPrint('单类档实测 items 数: ' + report.join(' | '));
    expect(empty, isEmpty,
        reason: '每类都应有 items（空则切换后仍空白）：${empty.join(',')}');
  });
}

int _count(AylaSearchResults r, String t) {
  switch (t) {
    case 'user':
      return r.users?.items.length ?? 0;
    case 'group':
      return r.groups?.items.length ?? 0;
    case 'post':
      return r.posts?.items.length ?? 0;
    case 'live':
      return r.lives?.items.length ?? 0;
    case 'voice':
      return r.voices?.items.length ?? 0;
    case 'game':
      return r.games?.items.length ?? 0;
  }
  return 0;
}