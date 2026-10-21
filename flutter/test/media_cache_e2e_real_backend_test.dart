// 真实端到端：Flutter 缓存层 × 真实后端 × 真实 MinIO。
//
// 本地开发环境没有 nginx，故在测试进程内起一个**双路代理**监听 8200：
//   /api/*   -> 127.0.0.1:8100  (Django)
//   /minio/* -> 127.0.0.1:9000  (MinIO，Host 固定 127.0.0.1:9000，等价生产 nginx)
// 客户端 base 指向 8200，从而 aylaApiBase()+"/minio/..." 真实可达。
//
// 这不是 mock：HTTP、S3 签名校验、Django 鉴权、MinIO 取字节全部真实发生。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/media/media_cache.dart';
import 'package:ayla_flutter/core/media/media_cache_paths.dart';
import 'package:ayla_flutter/core/media/media_signer.dart';
import 'package:ayla_flutter/core/models/media_kind.dart';
import 'package:ayla_flutter/core/net/dio_client.dart'
    show ApiException, AuthTokenStore, DioClient;

const String kProxyOrigin = 'http://127.0.0.1:8200';

const String kAliveImage = '06e781fa39654c9b860935b7108b3677';
const String kAliveEmoji = 'bcc18a315154496a908caa2628f162e8';
const String kStage1Image = 'f2cdb958d901481c9608ac78644a8e19';
const String kExpiredFile = '8b5051365eea4664a129832c0aa10d2f';

class _FixedPlatform implements AylaMediaCachePlatform {
  _FixedPlatform(this._root);
  final Directory _root;

  @override
  TargetPlatform get targetPlatform => TargetPlatform.windows;
  @override
  String get executablePath => '${_root.path}/app/ayla_flutter.exe';
  @override
  Future<Directory> applicationSupportDirectory() async => _root;
}

class _FixedTokens implements AuthTokenStore {
  _FixedTokens(this._access);
  final String _access;
  @override
  String? get accessToken => _access;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

Future<void> _pipe(HttpRequest req, HttpClient client, Uri target,
    {String? hostHeader, bool forwardAuth = false}) async {
  final HttpClientRequest up = await client.openUrl(req.method, target);
  if (hostHeader != null) up.headers.set('Host', hostHeader);
  for (final String h in <String>[
    'range', 'if-none-match', 'content-type', 'accept', 'authorization'
  ]) {
    if (!forwardAuth && h == 'authorization') continue;
    final String? v = req.headers.value(h);
    if (v != null) up.headers.set(h, v);
  }
  final List<int> body =
      await req.fold<List<int>>(<int>[], (List<int> p, List<int> e) => p..addAll(e));
  if (body.isNotEmpty) up.add(body);
  final HttpClientResponse upResp = await up.close();
  req.response.statusCode = upResp.statusCode;
  for (final String h in <String>[
    'content-type', 'content-range', 'etag', 'content-length', 'cache-control'
  ]) {
    final String? v = upResp.headers.value(h);
    if (v != null) req.response.headers.set(h, v);
  }
  await req.response.addStream(upResp);
  await req.response.close();
}

Future<HttpServer> _startProxy() async {
  final HttpServer server = await HttpServer.bind('127.0.0.1', 8200);
  server.listen((HttpRequest req) async {
    final HttpClient c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final String p = req.uri.path;
      print('[proxy] ${req.method} $p${req.uri.hasQuery ? "?..." : ""}');
      if (p.startsWith('/minio/')) {
        final Uri target = Uri.parse(
            'http://127.0.0.1:9000${p.substring(6)}')
            .replace(query: req.uri.query);
        await _pipe(req, c, target, hostHeader: '127.0.0.1:9000');
      } else if (p.startsWith('/api/')) {
        final Uri target = Uri.parse('http://127.0.0.1:8100$p')
            .replace(query: req.uri.query);
        await _pipe(req, c, target, forwardAuth: true);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    } finally {
      c.close(force: true);
    }
  });
  return server;
}

/// 集成测试开关：需要**本地后端已启动**（127.0.0.1:8100）+ runtime/ayla_token.txt。
///
/// 默认跳过——全量 flutter test 不应依赖外部服务；后端没起时 setUpAll 抛错会把
/// 「环境缺失」伪装成「测试失败」。要跑本文件：
///   1) 启动本地后端（Ayla/backend: launcher.py 或 runserver 8100）
///   2) 写入 runtime/ayla_token.txt（登录拿到的 access token）
///   3) flutter test test/media_cache_e2e_real_backend_test.dart --dart-define=AYLA_E2E=1
const bool kE2EEnabled = bool.fromEnvironment('AYLA_E2E');

void main() {
  if (!kE2EEnabled) {
    test(
      '真实后端集成测试（默认跳过）',
      () {},
      skip: '需要本地后端 8100 + runtime/ayla_token.txt，用 --dart-define=AYLA_E2E=1 开启',
    );
    return;
  }

  late HttpServer proxy;
  late Directory tempRoot;
  late AylaMediaCache cache;

  setUpAll(() async {
    proxy = await _startProxy();
    final String token = File(
      r'E:\Elysium-AyerElysia\Elysium\Ayla\backend\runtime\ayla_token.txt',
    ).readAsStringSync().trim();
    DioClient.instance.debugBaseUrlOverride = kProxyOrigin;
    DioClient.instance.init(
      tokenStore: _FixedTokens(token),
      onSessionExpired: () {},
    );
    MediaSigner.instance.attach(DioClient.instance);
  });

  tearDownAll(() async => proxy.close(force: true));

  /// 直连签名器：返回**原始** MinIO 预签名 URL（不经 /minio 同源改写）。
  ///
  /// 为什么要这个：本地开发环境没有 nginx，`aylaApiBase()+/minio/...` 不可达
  /// （生产由 nginx 的 location /minio/ 承担，已在服务器实测 206 通过）。
  /// 用它可以在本地把「Django 鉴权 → S3 签名 → MinIO 取字节 → 落盘」全链路跑真。
  Future<SignedMediaResult> _directSigner(
    String mediaId, {
    MediaVariant? variant,
  }) async {
    final String token = File(
      r'E:\Elysium-AyerElysia\Elysium\Ayla\backend\runtime\ayla_token.txt',
    ).readAsStringSync().trim();
    final HttpClient c = HttpClient();
    try {
      // ⚠️ 用 **query 参数** 传 variant，不用 body：dart 的 HttpClient.write() 走
      // chunked transfer-encoding，Django/DRF 不解析 chunked 请求体 ⇒ variant 读成空
      // ⇒ 误走 original 分支返回 410（实测）。生产路径走 dio 会正常带 Content-Length，
      // 不受影响；这里只是让测试桩语义与生产一致。
      final Uri uri = variant == null
          ? Uri.parse('http://127.0.0.1:8100/api/v1/media/$mediaId:sign')
          : Uri.parse(
              'http://127.0.0.1:8100/api/v1/media/$mediaId:sign?variant=thumb');
      final HttpClientRequest req = await c.postUrl(uri);
      req.headers.set('Authorization', 'Bearer $token');
      final HttpClientResponse resp = await req.close();
      final String body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        // 与生产 MediaSigner 同语义：410 原图已删 → 降级 thumb；thumb 也 410/404
        // → MediaExpiredError（完全过期）。测试桩必须复刻这条映射，否则无法断言。
        if (resp.statusCode == 410) {
          if (variant != null) throw const MediaExpiredError();
          // original 410 = 阶段 1（原图已删）→ 试签 thumb。
          // 与生产 MediaSigner 一致：thumb 也 410/404 才是「完全过期」；
          // thumb 成功则返回 originalExpired=true（缓存层据此不缓存，D1）。
          final String thumbToken = File(
            r'E:\Elysium-AyerElysia\Elysium\Ayla\backend\runtime\ayla_token.txt',
          ).readAsStringSync().trim();
          final HttpClient c2 = HttpClient();
          try {
            final HttpClientRequest r2 = await c2.postUrl(Uri.parse(
                'http://127.0.0.1:8100/api/v1/media/$mediaId:sign?variant=thumb'));
            r2.headers.set('Authorization', 'Bearer $thumbToken');
            final HttpClientResponse resp2 = await r2.close();
            final String body2 =
                await resp2.transform(utf8.decoder).join();
            if (resp2.statusCode != 200) throw const MediaExpiredError();
            final Map<String, dynamic> j2 =
                jsonDecode(body2) as Map<String, dynamic>;
            return SignedMediaResult(
              url: j2['url'] as String,
              originalExpired: true,
            );
          } finally {
            c2.close(force: true);
          }
        }
        throw ApiException(resp.statusCode, body);
      }
      final Map<String, dynamic> j = jsonDecode(body) as Map<String, dynamic>;
      return SignedMediaResult(
        url: j['url'] as String,
        originalExpired: false,
      );
    } finally {
      c.close(force: true);
    }
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ayla-e2e-');
    Directory('${tempRoot.path}/app').createSync(recursive: true);
    File('${tempRoot.path}/app/ayla_flutter.exe').writeAsBytesSync(<int>[1]);
    cache = AylaMediaCache(
      platform: _FixedPlatform(tempRoot),
      signer: _directSigner,
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('正常图片：真实下载并落盘，二次 lookup 命中', () async {
    final File? f = await cache.fetchAndStore(
      mediaId: kAliveImage,
      kind: AylaMediaKind.image,
    );
    expect(f, isNotNull, reason: '正常媒体应成功缓存');
    expect(await f!.exists(), isTrue);
    expect(await f.length(), greaterThan(1000));
    print('[e2e] cached ${await f.length()} bytes -> ${f.path}');

    final String norm = f.path.replaceAll('\\', '/');
    expect(norm.contains('/data/media-cache/image/06/'), isTrue,
        reason: '应落在 image/06 分桶，实际 ${f.path}');
    // kind 兜底扩展名（无 mimeType 时按 kind 给 .jpg）
    expect(norm.endsWith('$kAliveImage.jpg'), isTrue,
        reason: '应使用 kind 兜底扩展名，实际 ${f.path}');

    final File? hit = await cache.lookup(kAliveImage, kind: AylaMediaKind.image);
    expect(hit, isNotNull);
    expect(await hit!.length(), await f.length());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('表情：真实下载并落盘（kind 分桶正确）', () async {
    final File? f = await cache.fetchAndStore(
      mediaId: kAliveEmoji,
      kind: AylaMediaKind.emoji,
    );
    expect(f, isNotNull);
    final String norm = f!.path.replaceAll('\\', '/');
    expect(norm.contains('/media-cache/emoji/bc/'), isTrue,
        reason: '应落在 emoji/bc 分桶，实际 ${f.path}');
    print('[e2e] emoji cached ${await f.length()} bytes');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('阶段1（原图已删、thumb在）：不缓存（D1）', () async {
    final File? f = await cache.fetchAndStore(
      mediaId: kStage1Image,
      kind: AylaMediaKind.image,
    );
    expect(f, isNull, reason: 'D1：阶段1只剩缩略图，不得冒充原图缓存');
    print('[e2e] D1 verified: stage1 not cached');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('完全过期：抛 MediaExpiredError（UI 显示占位）', () async {
    await expectLater(
      cache.fetchAndStore(mediaId: kExpiredFile, kind: AylaMediaKind.file),
      throwsA(isA<MediaExpiredError>()),
    );
    print('[e2e] expired throws MediaExpiredError');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('D3：本地已有 → 云端 410 也照样命中', () async {
    final File? stored = await cache.storeBytes(
      mediaId: kExpiredFile,
      kind: AylaMediaKind.file,
      bytes: List<int>.filled(2048, 42),
      mimeType: 'application/json',
    );
    expect(stored, isNotNull);
    final File? hit = await cache.lookup(kExpiredFile, kind: AylaMediaKind.file);
    expect(hit, isNotNull, reason: 'D3：本地有就必须命中，与云端状态无关');
    expect(await hit!.length(), 2048);
    print('[e2e] D3 verified: local hit despite cloud 410');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('【本地环境】直连 MinIO：真实下载 84MB 大图并落盘', () async {
    // 本地开发没有 nginx ⇒ /minio 改写不可达（生产由 nginx 承担，已验证 206）。
    // 这里用 signer 注入**原始预签名 URL**（不经 /minio 改写），其余链路全真实：
    // 真实 Django 鉴权 → 真实 S3 签名 → 真实 MinIO 取字节 → 真实磁盘落盘。
    final String token = File(
      r'E:\Elysium-AyerElysia\Elysium\Ayla\backend\runtime\ayla_token.txt',
    ).readAsStringSync().trim();
    final AylaMediaCache direct = AylaMediaCache(
      platform: _FixedPlatform(tempRoot),
      signer: (String mediaId, {MediaVariant? variant}) async {
        final HttpClient c = HttpClient();
        try {
          final HttpClientRequest req = await c
              .postUrl(Uri.parse('http://127.0.0.1:8100/api/v1/media/$mediaId:sign'));
          req.headers.set('Authorization', 'Bearer $token');
          req.headers.contentType = ContentType.json;
          req.write('{}');
          final HttpClientResponse resp = await req.close();
          final String body = await resp.transform(utf8.decoder).join();
          final Map<String, dynamic> j = jsonDecode(body) as Map<String, dynamic>;
          return SignedMediaResult(
            url: j['url'] as String, // 原始 MinIO URL，不改写
            originalExpired: false,
          );
        } finally {
          c.close(force: true);
        }
      },
    );

    final File? f = await direct.fetchAndStore(
      mediaId: kAliveImage,
      kind: AylaMediaKind.image,
    );
    expect(f, isNotNull, reason: '真实 MinIO 下载应成功');
    expect(await f!.exists(), isTrue);
    final int size = await f.length();
    expect(size, 84050281, reason: '应与后端 descriptor 的 size 完全一致');
    print('[e2e] 真实 84MB 大图落盘成功: $size bytes -> ${f.path}');

    final String norm = f.path.replaceAll('\\', '/');
    expect(norm.contains('/data/media-cache/image/06/'), isTrue);
    // kind 兜底扩展名（无 mimeType 时按 kind 给 .jpg；见 aylaMediaExtensionForMimeOrKind）
    expect(norm.endsWith('$kAliveImage.jpg'), isTrue,
        reason: '应使用 kind 兜底扩展名 .jpg，实际 ${f.path}');

    // 二次命中（不走网络）
    final File? hit = await direct.lookup(kAliveImage, kind: AylaMediaKind.image);
    expect(hit, isNotNull);
    expect(await hit!.length(), size);

    // stats
    final AylaMediaCacheStats s = await direct.stats();
    expect(s.fileCount, 1);
    expect(s.totalBytes, size);
    print('[e2e] stats 一致: files=${s.fileCount} bytes=${s.totalBytes}');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('stats 真实统计一致', () async {
    await cache.fetchAndStore(mediaId: kAliveImage, kind: AylaMediaKind.image);
    await cache.fetchAndStore(mediaId: kAliveEmoji, kind: AylaMediaKind.emoji);
    final AylaMediaCacheStats s = await cache.stats();
    expect(s.fileCount, 2);
    expect(s.totalBytes,
        s.bytesByKind.values.fold<int>(0, (int a, int b) => a + b));
    print('[e2e] stats: files=${s.fileCount} bytes=${s.totalBytes} byKind=${s.bytesByKind}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
