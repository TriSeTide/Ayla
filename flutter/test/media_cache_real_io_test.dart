// 真实 IO 集成验证（不使用 testWidgets ⇒ 不进入 FakeAsync，磁盘 IO 真实完成）。
//
// 目标：验证缓存层在**真实 Windows 文件系统**上的端到端行为，
// 而不是 mock 出来的假平台。
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/media/media_cache.dart';
import 'package:ayla_flutter/core/media/media_cache_paths.dart';
import 'package:ayla_flutter/core/storage/ayla_storage_paths.dart';
import 'package:ayla_flutter/core/models/media_kind.dart';

/// 真实平台：executablePath 指向真实目录，其余走真实 dart:io 实现。
class _RealPlatform implements AylaMediaCachePlatform {
  _RealPlatform(this._exePath, this._supportDir);
  final String _exePath;
  final Directory? _supportDir;

  @override
  TargetPlatform get targetPlatform => TargetPlatform.windows;

  @override
  String get executablePath => _exePath;

  @override
  Future<Directory> applicationSupportDirectory() async => _supportDir!;

  @override
  Future<Directory?> externalStorageDirectory() async => null;
}

void main() {
  test('真实磁盘 IO：写 → 命中 → 分桶布局 → 统计 → 删除', () async {
    final Directory tempRoot = await Directory.systemTemp.createTemp('ayla-real-io-');
    addTearDown(() async {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    // 模拟真实绿色包：<root>/app/ayla_flutter.exe
    final Directory appDir = Directory('${tempRoot.path}/app');
    await appDir.create(recursive: true);
    final String exePath = '${appDir.path}/ayla_flutter.exe';
    await File(exePath).writeAsBytes(<int>[1, 2, 3]);

    final Directory support = Directory('${tempRoot.path}/support');
    await support.create(recursive: true);

    final AylaMediaCache cache =
        AylaMediaCache(platform: _RealPlatform(exePath, support));
    final AylaMediaCacheLayout layout = (await cache.ensureReady())!;

    // ① 根目录必须是 <exe目录>/data/media-cache（真实 Windows 路径）
    expect(layout.source, AylaMediaCacheRootSource.executableData);
    expect(layout.degraded, isFalse);
    final String norm = layout.root.replaceAll('\\', '/');
    expect(norm.endsWith('/app/data/media-cache'), isTrue,
        reason: '根目录应是 <exe目录>/data/media-cache，实际=${layout.root}');

    // ② 真实写入 1KB
    const String mid = 'realio000000000000000000000000001';
    final List<int> bytes = List<int>.generate(1024, (int i) => i % 256);
    final File? stored = await cache.storeBytes(
      mediaId: mid,
      kind: AylaMediaKind.image,
      bytes: bytes,
      mimeType: 'image/jpeg',
    );
    expect(stored, isNotNull);
    // ③ 文件真的落在磁盘上、内容一致
    expect(await stored!.exists(), isTrue);
    expect(await stored.length(), 1024);
    expect(await stored.readAsBytes(), equals(bytes));

    // ④ 分桶布局：<root>/image/<id 前2位>/<id>.jpg
    final String bucketPath = '${layout.root}/image/re';
    expect(await Directory(bucketPath).exists(), isTrue,
        reason: '应落在 image/re 分桶，实际根=${layout.root}');
    expect(stored.uri.pathSegments.last, 'realio000000000000000000000000001.jpg');
    // data/ 下的运行时文件不被污染
    expect(await File(exePath).exists(), isTrue);

    // ⑤ lookup 真实命中
    final File? hit = await cache.lookup(mid, kind: AylaMediaKind.image);
    expect(hit, isNotNull);
    expect(await hit!.readAsBytes(), equals(bytes));

    // ⑥ stats 真实统计
    final AylaMediaCacheStats stats = await cache.stats();
    expect(stats.fileCount, 1);
    expect(stats.totalBytes, 1024);
    expect(stats.bytesByKind['image'], 1024);

    // ⑦ evict 真删
    expect(await cache.evict(mid), greaterThanOrEqualTo(1));
    expect(await cache.lookup(mid, kind: AylaMediaKind.image), isNull);
    expect(await stored.exists(), isFalse);
  });

  test('真实磁盘 IO：主目录不可写 → 落到显式 Ayla\\data（Program Files 场景仍可用）', () async {
    final Directory tempRoot = await Directory.systemTemp.createTemp('ayla-real-ro-');
    addTearDown(() async {
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });
    final Directory appDir = Directory('${tempRoot.path}/app');
    await appDir.create(recursive: true);
    final String exePath = '${appDir.path}/ayla_flutter.exe';
    await File(exePath).writeAsBytes(<int>[1]);
    // 让 <exe目录>/data 变成**文件**而不是目录 ⇒ 建 media-cache 必失败 ⇒ 触发降级
    await File('${appDir.path}/data').writeAsString('block');

    final Directory support = Directory('${tempRoot.path}/support');
    await support.create(recursive: true);

    // 回落根默认是真实用户目录 %LOCALAPPDATA%\Ayla\data ⇒ 测试必须重定向，
    // 否则会在开发机上留垃圾（2026-11-02 实测踩过）。
    aylaFallbackDataRootForTest = '${tempRoot.path}/localappdata/Ayla/data';
    addTearDown(() => aylaFallbackDataRootForTest = null);

    final AylaMediaCache cache =
        AylaMediaCache(platform: _RealPlatform(exePath, support));
    // 用户 2026-11-02 裁决：Program Files 场景**正常用**，允许写 C 盘，
    // 但数据仍在显式的 Ayla\\data 目录里（不是 %APPDATA% 隐式目录）。
    final AylaMediaCacheLayout? layout = await cache.ensureReady();
    expect(layout, isNotNull, reason: '不可写 exe 同级 ⇒ 回落而不是禁用');
    expect(layout!.degraded, isTrue);
    expect(
      layout.root.replaceAll('\\', '/').toLowerCase(),
      contains('ayla/data/media-cache'),
      reason: '回落点必须是显式 Ayla/data 目录',
    );
    // 反证：没有回到旧实现的 ApplicationSupport 隐式目录
    expect(
      Directory('${support.path}/media-cache').existsSync(),
      isFalse,
      reason: '禁止回到 %APPDATA%\\Roaming 隐式目录',
    );

    final File? stored = await cache.storeBytes(
      mediaId: 'degrade000000000000000000000001',
      kind: AylaMediaKind.image,
      bytes: List<int>.filled(10, 7),
      mimeType: 'image/png',
    );
    expect(stored, isNotNull, reason: '缓存照常工作（不阻断功能）');
    expect(await stored!.exists(), isTrue);
  });
}
