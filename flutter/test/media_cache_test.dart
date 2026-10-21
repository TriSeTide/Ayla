/// 本地媒体缓存层（`lib/core/media/media_cache.dart` + `media_cache_paths.dart`）的契约测试。
///
/// 覆盖任务要求的五类断言：
/// 1. **路径解析** —— Windows `<exe>/data/media-cache` 分支、Android/iOS
///    `<ApplicationSupport>/media-cache` 分支、mime→扩展名、id 净化；
/// 2. **写入后 lookup 命中** —— 且落盘路径严格符合分桶布局；
/// 3. **并发去重** —— 同一 media_id 并发 `fetchAndStore` 只签名/下载一次；
/// 4. **原子性** —— 写入后不残留 `.tmp`；启动时清掉崩溃留下的 `.tmp`；
/// 5. **可写性降级** —— Windows 主目录不可写时回退到 ApplicationSupport 并标记 `degraded`。
///
/// 全部使用临时目录 + 注入的假平台/假签名器/假下载器，**不碰真实用户缓存目录**、
/// **不发任何网络请求**。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/media/media_cache.dart';
import 'package:ayla_flutter/core/media/media_cache_paths.dart';
import 'package:ayla_flutter/core/media/media_signer.dart';
import 'package:ayla_flutter/core/models/media_kind.dart';

/// 假平台：把「exe 路径」和「应用支持目录」都指向临时目录，并指定目标平台。
class _FakePlatform implements AylaMediaCachePlatform {
  _FakePlatform({
    required this.targetPlatform,
    required this.exeDir,
    required this.supportDir,
  });

  @override
  final TargetPlatform targetPlatform;

  final String exeDir;
  final String supportDir;

  @override
  String get executablePath {
    // 真实实现是 Platform.resolvedExecutable（含文件名与平台分隔符）
    final String sep = Platform.pathSeparator;
    return '$exeDir${sep}ayla_flutter.exe';
  }

  @override
  Future<Directory> applicationSupportDirectory() async =>
      Directory(supportDir);
}

/// 统计下载次数并可挂起的假下载器。
class _FakeDownloader {
  _FakeDownloader(this.bytes);

  final List<int> bytes;
  int calls = 0;
  final List<String> urls = <String>[];

  /// 非 null 时下载会等待它完成（用于制造"飞行中"窗口）。
  Completer<void>? gate;

  Future<Uint8List> call(String url) async {
    calls++;
    urls.add(url);
    final Completer<void>? wait = gate;
    if (wait != null) await wait.future;
    return Uint8List.fromList(bytes);
  }
}

/// 假签名器：可配置为「原图已过期（降级 thumb）」。
class _FakeSigner {
  _FakeSigner({this.originalExpired = false});

  bool originalExpired;
  int calls = 0;
  final List<String> ids = <String>[];

  Future<SignedMediaResult> call(String mediaId, {MediaVariant? variant}) async {
    calls++;
    ids.add(mediaId);
    return SignedMediaResult(
      url: 'https://minio.example/bucket/$mediaId?sig=x',
      originalExpired: originalExpired,
    );
  }
}

/// 递归列目录下全部文件（不含目录）。
Future<List<File>> _allFiles(Directory root) async {
  if (!await root.exists()) return <File>[];
  final List<File> out = <File>[];
  await for (final FileSystemEntity e in root.list(recursive: true)) {
    if (e is File) out.add(e);
  }
  return out;
}

void main() {
  late Directory tempRoot;
  late _FakePlatform windowsPlatform;
  late _FakePlatform mobilePlatform;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ayla-media-cache-test-');
    windowsPlatform = _FakePlatform(
      targetPlatform: TargetPlatform.windows,
      exeDir: '${tempRoot.path}${Platform.pathSeparator}app',
      supportDir: '${tempRoot.path}${Platform.pathSeparator}support-win',
    );
    mobilePlatform = _FakePlatform(
      targetPlatform: TargetPlatform.android,
      exeDir: '/nonexistent',
      supportDir: '${tempRoot.path}${Platform.pathSeparator}support-android',
    );
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 测试临时目录清理失败不影响断言（系统会回收）
    }
  });

  group('路径解析（media_cache_paths）', () {
    test('Windows：根 = <exe目录>/data/media-cache，不污染 data/ 里其它文件', () async {
      final AylaMediaCacheLayout layout =
          await aylaResolveMediaCacheLayout(platform: windowsPlatform);

      final String expected =
          '${windowsPlatform.exeDir}/data/media-cache'.replaceAll('\\', '/');
      expect(layout.root.replaceAll('\\', '/'), expected);
      expect(layout.source, AylaMediaCacheRootSource.executableData);
      expect(layout.degraded, isFalse);

      // 关键约束：缓存根必须是 data 的**子目录**，且原有运行时资源不受影响。
      final String dataDir =
          '${windowsPlatform.exeDir}/data'.replaceAll('\\', '/');
      final Directory runtimeData = Directory(dataDir);
      await runtimeData.create(recursive: true);
      final File appSo = File('$dataDir/app.so');
      await appSo.writeAsBytes(const <int>[1, 2, 3]);

      expect(layout.root.replaceAll('\\', '/').startsWith('$dataDir/'), isTrue,
          reason: '缓存必须落在 data/ 的独立子目录里');
      expect(layout.root.replaceAll('\\', '/'), isNot(dataDir),
          reason: '绝不能直接把 data/ 当缓存根');
      expect(await appSo.exists(), isTrue, reason: '探测不得动 data/ 里的运行时资源');
    });

    test('Android/iOS：根 = <ApplicationSupport>/media-cache（不探测、不降级）', () async {
      final AylaMediaCacheLayout layout =
          await aylaResolveMediaCacheLayout(platform: mobilePlatform);

      expect(
        layout.root.replaceAll('\\', '/'),
        '${mobilePlatform.supportDir}/media-cache'.replaceAll('\\', '/'),
      );
      expect(layout.source, AylaMediaCacheRootSource.applicationSupport);
      expect(layout.degraded, isFalse);
      // 目录已在探测阶段/后续使用前建好
      expect(await Directory(layout.root).exists(), isTrue);
    });

    test('Windows 主目录不可写 → 降级到 ApplicationSupport 且 degraded=true', () async {
      // 造「不可写」：在主路径上放一个**同名文件**，目录 create 必然失败
      // （跨平台稳定，不依赖 ACL/只读属性）。
      final String primary =
          '${windowsPlatform.exeDir}/data/media-cache'.replaceAll('\\', '/');
      await Directory('${windowsPlatform.exeDir}/data').create(recursive: true);
      await File(primary).writeAsBytes(const <int>[9]);

      final AylaMediaCacheLayout layout =
          await aylaResolveMediaCacheLayout(platform: windowsPlatform);

      expect(layout.degraded, isTrue, reason: '主目录不可写必须标记降级');
      expect(layout.source, AylaMediaCacheRootSource.applicationSupport);
      expect(
        layout.root.replaceAll('\\', '/'),
        '${windowsPlatform.supportDir}/media-cache'.replaceAll('\\', '/'),
      );
      // 降级后仍应可用（可写）
      expect(await aylaProbeDirectoryWritable(Directory(layout.root)), isTrue);
    });

    test('分桶布局：<kind>/<id 前2位>/<id>.<ext>', () {
      const AylaMediaCacheLayout layout = AylaMediaCacheLayout(
        root: '/cache/media-cache',
        source: AylaMediaCacheRootSource.executableData,
        degraded: false,
      );
      const String id = '5db02e1571464f91bce21bdda1245125';

      expect(layout.dirFor(AylaMediaKind.image, id),
          '/cache/media-cache/image/5d');
      expect(layout.pathFor(AylaMediaKind.image, id, mimeType: 'image/jpeg'),
          '/cache/media-cache/image/5d/$id.jpg');
      expect(layout.pathFor(AylaMediaKind.voice, id, mimeType: 'audio/webm'),
          '/cache/media-cache/voice/5d/$id.webm');
      expect(
        layout.pathFor(AylaMediaKind.file, id, mimeType: 'application/pdf'),
        '/cache/media-cache/file/5d/$id.pdf',
      );
      // 未知 mime → .bin（不猜扩展名）
      expect(layout.pathFor(AylaMediaKind.file, id),
          '/cache/media-cache/file/5d/$id.bin');
    });

    test('mime → 扩展名：含参数/大小写/未知一律 .bin', () {
      expect(aylaMediaExtensionForMime('image/jpeg'), '.jpg');
      expect(aylaMediaExtensionForMime('IMAGE/PNG'), '.png');
      expect(aylaMediaExtensionForMime('text/plain; charset=utf-8'), '.txt');
      expect(aylaMediaExtensionForMime('application/x-unknown'), '.bin');
      expect(aylaMediaExtensionForMime(null), '.bin');
      expect(aylaMediaExtensionForMime(''), '.bin');
      expect(aylaMediaExtension('jpg'), '.jpg');
      expect(aylaMediaExtension('.MP4'), '.mp4');
      expect(aylaMediaExtension('../evil'), '.bin');
      expect(aylaMediaExtension(''), '.bin');
    });

    test('media_id 净化：防路径穿越 / 非法字符', () {
      expect(aylaSafeMediaId('5DB02E'), '5db02e');
      expect(aylaSafeMediaId('../../etc/passwd'), 'etcpasswd');
      expect(aylaSafeMediaId('../..'), '_');
      expect(aylaSafeMediaId(''), '_');
      expect(aylaSafeMediaId('a-b_c:d'), 'abcd');
      // 分桶前 2 位
      expect(aylaMediaShardOf('5db02e'), '5d');
      expect(aylaMediaShardOf('ab'), 'ab');
    });
  });

  group('写入 / 命中', () {
    test('storeBytes → lookup 命中，且落盘路径严格符合分桶布局', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = '5db02e1571464f91bce21bdda1245125';
      final List<int> bytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];

      final File? stored = await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: bytes,
        mimeType: 'image/jpeg',
      );
      expect(stored, isNotNull);
      final String normalized = stored!.path.replaceAll('\\', '/');
      expect(normalized, endsWith('data/media-cache/image/5d/$id.jpg'));
      expect(await stored.readAsBytes(), bytes, reason: '写入内容必须逐字节一致');

      final File? hit = await cache.lookup(
        id,
        kind: AylaMediaKind.image,
        mimeType: 'image/jpeg',
      );
      expect(hit, isNotNull);
      expect(hit!.path, stored.path);
    });

    test('lookup 在 mime 已知时按确定路径命中；mime 未知时靠扫分桶兜住', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = '51c0e2cd5c2b409ebb89647d53fa0231';
      await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: <int>[1, 2],
        mimeType: 'image/png',
      );

      final File? withMime = await cache.lookup(
        id,
        kind: AylaMediaKind.image,
        mimeType: 'image/png',
      );
      expect(withMime, isNotNull);

      // 调用点没给 mime：仍要命中（扫分桶，不因缺 mime 丢缓存）
      final File? withoutMime =
          await cache.lookup(id, kind: AylaMediaKind.image);
      expect(withoutMime, isNotNull);
      expect(withoutMime!.path, withMime!.path);
    });

    test('跨 kind 互不干扰（同一 media_id 在 image/voice 两个桶里各自命中）', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = 'c904082abf1a4003a5a0db48b5071a0d';
      await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: <int>[1],
        mimeType: 'image/jpeg',
      );
      final File? image = await cache.lookup(id, kind: AylaMediaKind.image);
      final File? voice = await cache.lookup(id, kind: AylaMediaKind.voice);
      expect(image, isNotNull);
      expect(voice, isNull, reason: 'kind 目录也是隔离维度');
    });

    test('不跨账号隔离：换实例（模拟另一账号）仍能命中同一文件', () async {
      const String id = '8a1b2c3d4e5f60718293a4b5c6d7e8f9';
      final AylaMediaCache first = AylaMediaCache(platform: windowsPlatform);
      await first.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.video,
        bytes: <int>[7, 7, 7],
        mimeType: 'video/mp4',
      );

      // 另一个实例（不带任何用户标识）——目录里没有 user_id 段，故必然命中
      final AylaMediaCache second = AylaMediaCache(platform: windowsPlatform);
      final File? hit = await second.lookup(id, kind: AylaMediaKind.video);
      expect(hit, isNotNull, reason: 'D5：缓存跨账号共享');
      expect(hit!.path.replaceAll('\\', '/'),
          endsWith('data/media-cache/video/8a/$id.mp4'));
    });

    test('storeFile 流式落盘后立即可 lookup 命中', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = 'fb485f2570ab4473b8da13688940327b';
      final File source =
          File('${tempRoot.path}${Platform.pathSeparator}src.pdf');
      await source.writeAsBytes(List<int>.generate(4096, (int i) => i % 251));

      final File? stored = await cache.storeFile(
        mediaId: id,
        kind: AylaMediaKind.file,
        source: source,
        mimeType: 'application/pdf',
      );
      expect(stored, isNotNull);
      expect(stored!.path.replaceAll('\\', '/'),
          endsWith('data/media-cache/file/fb/$id.pdf'));
      expect(await stored.length(), 4096);
      expect(await cache.lookup(id, kind: AylaMediaKind.file), isNotNull);
    });

    test('thumb 不缓存（D1）：lookup 恒 null，storeBytes 拒绝写入', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = 'aabbccddeeff00112233445566778899';
      final File? stored = await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: <int>[1],
        mimeType: 'image/jpeg',
        variant: AylaMediaCacheVariant.thumb,
      );
      expect(stored, isNull);
      expect(
        await cache.lookup(id,
            kind: AylaMediaKind.image,
            variant: AylaMediaCacheVariant.thumb),
        isNull,
      );
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      expect(await _allFiles(Directory(layout.root)), isEmpty,
          reason: 'thumb 不得落盘');
    });

    test('空 id / 非法 id 不缓存（不伪造身份、不串内容）', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      expect(await cache.storeBytes(
              mediaId: '', kind: AylaMediaKind.image, bytes: <int>[1]),
          isNull);
      expect(await cache.storeBytes(
              mediaId: '   ', kind: AylaMediaKind.image, bytes: <int>[1]),
          isNull);
      expect(await cache.storeBytes(
              mediaId: '../..', kind: AylaMediaKind.image, bytes: <int>[1]),
          isNull);
      expect(await cache.lookup('', kind: AylaMediaKind.image), isNull);
    });
  });

  group('并发去重', () {
    test('同一 media_id 并发 fetchAndStore：签名/下载各只跑一次', () async {
      final _FakeSigner signer = _FakeSigner();
      final _FakeDownloader downloader = _FakeDownloader(<int>[1, 2, 3, 4]);
      final Completer<void> gate = Completer<void>();
      downloader.gate = gate;

      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: signer.call,
        downloader: downloader.call,
      );
      const String id = '0123456789abcdef0123456789abcdef';

      // 5 个并发请求同时进入（此时还都在"飞行中"）
      final List<Future<File?>> futures = List<Future<File?>>.generate(
        5,
        (_) => cache.fetchAndStore(mediaId: id, kind: AylaMediaKind.image,
            mimeType: 'image/jpeg'),
      );
      // 让出事件循环，确保 5 个调用都已进入 inflight 分支
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final List<File?> results = await Future.wait(futures);

      expect(downloader.calls, 1, reason: '并发只应真正下载一次');
      expect(signer.calls, 1, reason: '并发只应签名一次');
      expect(results.where((File? f) => f != null).length, 5,
          reason: '五个调用方都应拿到同一个本地文件');
      expect(results.map((File? f) => f!.path).toSet().length, 1);
    });

    test('并发窗口结束后 inflight 清空：后续命中本地不再下载', () async {
      final _FakeSigner signer = _FakeSigner();
      final _FakeDownloader downloader = _FakeDownloader(<int>[5, 5, 5]);
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: signer.call,
        downloader: downloader.call,
      );
      const String id = 'feedfacecafebeef0011223344556677';

      await cache.fetchAndStore(mediaId: id, kind: AylaMediaKind.voice,
          mimeType: 'audio/webm');
      expect(downloader.calls, 1);

      // 再取：本地命中 ⇒ 不签名、不下载（文档 §5 第一行）
      final File? again = await cache.fetchAndStore(
          mediaId: id, kind: AylaMediaKind.voice, mimeType: 'audio/webm');
      expect(again, isNotNull);
      expect(downloader.calls, 1, reason: '本地命中不得再发网络请求');
      expect(signer.calls, 1, reason: '本地命中连签名都不该发');
    });

    test('不同 media_id 并发互不阻塞（各自独立 inflight）', () async {
      final _FakeSigner signer = _FakeSigner();
      final _FakeDownloader downloader = _FakeDownloader(<int>[1]);
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: signer.call,
        downloader: downloader.call,
      );

      final List<File?> results = await Future.wait(<Future<File?>>[
        cache.fetchAndStore(mediaId: 'aa11', kind: AylaMediaKind.image),
        cache.fetchAndStore(mediaId: 'bb22', kind: AylaMediaKind.image),
        cache.fetchAndStore(mediaId: 'cc33', kind: AylaMediaKind.image),
      ]);
      expect(results.every((File? f) => f != null), isTrue);
      expect(downloader.calls, 3, reason: '不同媒体各下载一次');
    });
  });

  group('原子性与 .tmp 残留', () {
    test('写入成功后不残留任何 .tmp', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      await cache.storeBytes(
        mediaId: '11111111111111111111111111111111',
        kind: AylaMediaKind.image,
        bytes: List<int>.generate(1024, (int i) => i % 256),
        mimeType: 'image/jpeg',
      );
      await cache.storeBytes(
        mediaId: '22222222222222222222222222222222',
        kind: AylaMediaKind.image,
        bytes: List<int>.generate(2048, (int i) => i % 256),
        mimeType: 'image/png',
      );

      final List<File> files = await _allFiles(Directory(layout.root));
      expect(files, hasLength(2));
      expect(
        files.where((File f) => f.path.endsWith('.tmp')),
        isEmpty,
        reason: '原子写成功后 .tmp 必须已被 rename 掉',
      );
    });

    test('启动清理：崩溃残留的 .tmp 被扫除，且不影响正式文件', () async {
      // 先造一个「上次崩溃残留」的 .tmp 与一个正常文件
      final AylaMediaCacheLayout seedLayout =
          await aylaResolveMediaCacheLayout(platform: windowsPlatform);
      final String shardDir = '${seedLayout.root}/image/aa';
      await Directory(shardDir).create(recursive: true);
      final String goodPath = '$shardDir/aaaa1111.jpg';
      final String tmpPath = '$shardDir/aaaa1111.jpg.tmp';
      await File(goodPath).writeAsBytes(const <int>[1, 2, 3]);
      await File(tmpPath).writeAsBytes(const <int>[9]);

      // 新实例 = 模拟一次新启动：ensureReady 会跑一次性 cleanupTempFiles
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      await cache.ensureReady();

      expect(await File(tmpPath).exists(), isFalse, reason: '.tmp 必须被清理');
      expect(await File(goodPath).exists(), isTrue, reason: '正式文件不能被误删');
    });

    test('半截 .tmp 永远不会被 lookup 命中', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      const String id = 'bbbb2222cccc3333dddd4444eeee5555';
      final String bucket = '${layout.root}/image/bb';
      await Directory(bucket).create(recursive: true);
      // 只有 .tmp，没有正式文件 ⇒ 语义上"从未缓存成功"
      await File('$bucket/$id.jpg.tmp').writeAsBytes(const <int>[1, 2]);

      expect(await cache.lookup(id, kind: AylaMediaKind.image), isNull);
    });

    test('覆盖写同一媒体：内容被整体替换，不留旧半截', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String id = 'cccc3333dddd4444eeee5555ffff6666';
      await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: List<int>.filled(8192, 1),
        mimeType: 'image/jpeg',
      );
      final File? second = await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: <int>[4, 5, 6],
        mimeType: 'image/jpeg',
      );
      expect(second, isNotNull);
      expect(await second!.readAsBytes(), <int>[4, 5, 6]);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      final List<File> files = await _allFiles(Directory(layout.root));
      expect(files, hasLength(1));
      expect(files.single.path.endsWith('.tmp'), isFalse);
    });
  });

  group('降级路径端到端', () {
    test('主目录不可写 → 缓存放进降级根且读写正常', () async {
      // 造不可写（同名文件占位，见上）
      final String primary =
          '${windowsPlatform.exeDir}/data/media-cache'.replaceAll('\\', '/');
      await Directory('${windowsPlatform.exeDir}/data').create(recursive: true);
      await File(primary).writeAsBytes(const <int>[9]);

      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      expect(layout.degraded, isTrue);

      const String id = 'dddd4444eeee5555ffff666677778888';
      final File? stored = await cache.storeBytes(
        mediaId: id,
        kind: AylaMediaKind.image,
        bytes: <int>[1, 2, 3],
        mimeType: 'image/jpeg',
      );
      expect(stored, isNotNull);
      expect(
        stored!.path.replaceAll('\\', '/'),
        '${windowsPlatform.supportDir}/media-cache/image/dd/$id.jpg'
            .replaceAll('\\', '/'),
      );
      expect(await cache.lookup(id, kind: AylaMediaKind.image), isNotNull);
      // 主路径上的占位文件不受影响（降级绝不写主路径）
      expect(await File(primary).exists(), isTrue);
    });

    test('可写探测本身：可写目录 true / 文件占位 false', () async {
      final Directory ok =
          Directory('${tempRoot.path}${Platform.pathSeparator}ok-probe');
      expect(await aylaProbeDirectoryWritable(ok), isTrue);
      // 探测会建目录
      expect(await ok.exists(), isTrue);

      final String blockedPath =
          '${tempRoot.path}${Platform.pathSeparator}blocked-probe';
      await File(blockedPath).writeAsBytes(const <int>[1]);
      expect(await aylaProbeDirectoryWritable(Directory(blockedPath)), isFalse);
    });
  });

  group('fetchAndStore 语义', () {
    test('原图已过期（签名降级 thumb）→ 返回 null 且不落盘（D1）', () async {
      final _FakeSigner signer = _FakeSigner(originalExpired: true);
      final _FakeDownloader downloader = _FakeDownloader(<int>[1, 2, 3]);
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: signer.call,
        downloader: downloader.call,
      );
      const String id = 'eeee5555ffff66667777888899990000';

      final File? result = await cache.fetchAndStore(
          mediaId: id, kind: AylaMediaKind.image, mimeType: 'image/jpeg');
      expect(result, isNull, reason: '只有 thumb 可签时不得冒充原图落盘');
      expect(downloader.calls, 0, reason: '既然不缓存就没必要下载 thumb');
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      expect(await _allFiles(Directory(layout.root)), isEmpty);
    });

    test('签名抛 MediaExpiredError → 原样向上抛（调用方显示已过期）', () async {
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: (String id, {MediaVariant? variant}) async =>
            throw const MediaExpiredError(),
        downloader: _FakeDownloader(<int>[1]).call,
      );
      await expectLater(
        cache.fetchAndStore(mediaId: 'ffff0000111122223333444455556666',
            kind: AylaMediaKind.voice),
        throwsA(isA<MediaExpiredError>()),
      );
    });

    test('下载失败 → 返回 null（不抛，缓存是增强项）', () async {
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: _FakeSigner().call,
        downloader: (String url) async => throw const SocketException('boom'),
      );
      final File? result = await cache.fetchAndStore(
          mediaId: '99990000aaaabbbbccccddddeeeeffff', kind: AylaMediaKind.image);
      expect(result, isNull, reason: '缓存失败不得打断媒体链路');
    });

    test('下载到 0 字节 → 不落盘（不伪造成功的空文件）', () async {
      final _FakeDownloader downloader = _FakeDownloader(<int>[]);
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: _FakeSigner().call,
        downloader: downloader.call,
      );
      final File? result = await cache.fetchAndStore(
          mediaId: 'aaaabbbbccccddddeeeeffff00001111', kind: AylaMediaKind.file);
      expect(result, isNull);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      expect(await _allFiles(Directory(layout.root)), isEmpty);
    });
  });

  group('evict / stats', () {
    test('evict 删除该媒体所有 kind 的变体，其它媒体不受影响', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      const String target = 'abcdef0123456789abcdef0123456789';
      const String other = '123456789abcdef0123456789abcdef0';
      await cache.storeBytes(
          mediaId: target, kind: AylaMediaKind.image,
          bytes: <int>[1], mimeType: 'image/jpeg');
      await cache.storeBytes(
          mediaId: target, kind: AylaMediaKind.file,
          bytes: <int>[2], mimeType: 'application/pdf');
      await cache.storeBytes(
          mediaId: other, kind: AylaMediaKind.image,
          bytes: <int>[3], mimeType: 'image/png');

      expect(await cache.evict(target), 2);
      expect(await cache.lookup(target, kind: AylaMediaKind.image), isNull);
      expect(await cache.lookup(target, kind: AylaMediaKind.file), isNull);
      expect(await cache.lookup(other, kind: AylaMediaKind.image), isNotNull);
    });

    test('stats 汇总总量/条目数与按 kind 分组', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      await cache.storeBytes(
          mediaId: 'aaa111', kind: AylaMediaKind.image,
          bytes: List<int>.filled(100, 1), mimeType: 'image/jpeg');
      await cache.storeBytes(
          mediaId: 'aaa222', kind: AylaMediaKind.image,
          bytes: List<int>.filled(50, 1), mimeType: 'image/png');
      await cache.storeBytes(
          mediaId: 'bbb333', kind: AylaMediaKind.video,
          bytes: List<int>.filled(500, 1), mimeType: 'video/mp4');

      final AylaMediaCacheStats stats = await cache.stats();
      expect(stats.fileCount, 3);
      expect(stats.totalBytes, 650);
      expect(stats.bytesByKind['image'], 150);
      expect(stats.bytesByKind['video'], 500);
      expect(stats.fileCountByKind['image'], 2);
      expect(stats.fileCountByKind['video'], 1);
    });

    test('stats 不把 .tmp 计入条目数', () async {
      final AylaMediaCache cache = AylaMediaCache(platform: windowsPlatform);
      final AylaMediaCacheLayout layout = await cache.ensureReady();
      final String bucket = '${layout.root}/image/cc';
      await Directory(bucket).create(recursive: true);
      await File('$bucket/cc11.jpg').writeAsBytes(List<int>.filled(10, 1));
      // 启动清理已跑过，故手动再造一个 .tmp（模拟运行期正在写）
      await File('$bucket/cc11.jpg.tmp').writeAsBytes(List<int>.filled(99, 1));

      final AylaMediaCacheStats stats = await cache.stats();
      expect(stats.fileCount, 1);
      expect(stats.totalBytes, 10);
    });
  });

  group('测试开关（enabledForTest）', () {
    test('关闭后 lookup/store/fetchAndStore 全部同步短路，不碰磁盘', () async {
      final AylaMediaCache cache = AylaMediaCache(
        platform: windowsPlatform,
        signer: (String id, {MediaVariant? variant}) async {
          fail('关闭状态下不该签名');
        },
        downloader: (String url) async {
          fail('关闭状态下不该下载');
        },
      );
      // 先确认开启态能正常落盘
      await cache.storeBytes(
        mediaId: 'dd44',
        kind: AylaMediaKind.image,
        bytes: List<int>.filled(20, 1),
        mimeType: 'image/png',
      );
      expect(await cache.lookup('dd44', kind: AylaMediaKind.image), isNotNull);

      cache.enabledForTest = false;
      expect(cache.enabled, isFalse);
      // 读：恒 null（且不会因存在旧文件而误命中）
      expect(await cache.lookup('dd44', kind: AylaMediaKind.image), isNull);
      // 写：恒 null
      expect(
        await cache.storeBytes(
          mediaId: 'ee55',
          kind: AylaMediaKind.image,
          bytes: List<int>.filled(20, 1),
          mimeType: 'image/png',
        ),
        isNull,
      );
      // 取回：恒 null，且**不会**触发 signer/downloader（fail() 会炸）
      expect(
        await cache.fetchAndStore(mediaId: 'ff66', kind: AylaMediaKind.image),
        isNull,
      );

      // 重新打开后恢复（布局需重新解析）
      cache.enabledForTest = true;
      expect(cache.enabled, isTrue);
      expect(cache.layout, isNull, reason: '关闭时清掉布局，重开需重新解析');
      expect(await cache.lookup('dd44', kind: AylaMediaKind.image), isNotNull);
    });
  });
}
