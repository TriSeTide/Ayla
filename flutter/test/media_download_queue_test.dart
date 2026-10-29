/// 持久下载队列的契约测试（`lib/core/media/media_download_queue.dart`）。
///
/// 覆盖用户 2026-10-29 拍板的四条硬要求：
/// 1. **直到成功为止**：失败会重排，最多 3 次（`maxAttempts`）；
/// 2. **app 退出后任务仍保留**：任务先落盘再执行，进程重启后 `resumeOnStartup` 重跑；
/// 3. **启动时重新开始**：上次 `running` 的任务恢复成 `pending`；
/// 4. **过期不消耗重试**：云端 410 直接判 failed，避免死任务反复占队列。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ayla_flutter/core/media/media_cache.dart';
import 'package:ayla_flutter/core/media/media_download_queue.dart';
import 'package:ayla_flutter/core/media/media_signer.dart';
import 'package:ayla_flutter/core/models/media_kind.dart';

void main() {
  late Directory tempRoot;
  late File queueFile;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ayla-dlq-test-');
    queueFile = File('${tempRoot.path}/download-queue.json');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响断言
    }
  });

  /// 造一个已注入队列文件的队列（不触碰真实缓存目录）。
  AylaMediaDownloadQueue makeQueue({
    required AylaDownloadRunner runner,
    int maxAttempts = 3,
  }) {
    final AylaMediaDownloadQueue q =
        AylaMediaDownloadQueue(runner: runner, maxAttempts: maxAttempts);
    q.setQueueFileForTest(queueFile);
    return q;
  }

  group('入队与执行', () {
    test('入队后执行成功 → 任务从队列移除', () async {
      final List<String> ran = <String>[];
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          ran.add(t.mediaId);
          return File('${tempRoot.path}/${t.mediaId}.bin');
        },
      );
      await q.enqueue(mediaId: 'm1', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      expect(ran, <String>['m1']);
      expect(q.stats.total, 0);
      final Map<String, dynamic> saved =
          jsonDecode(await queueFile.readAsString()) as Map<String, dynamic>;
      expect((saved['tasks'] as List<dynamic>), isEmpty);
    });

    test('同媒体同形态重复入队只排一次', () async {
      final List<String> ran = <String>[];
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          ran.add(t.mediaId);
          return File('${tempRoot.path}/x.bin');
        },
      );
      await q.enqueue(mediaId: 'm2', kind: AylaMediaKind.image);
      await q.enqueue(mediaId: 'm2', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      expect(ran.length, 1);
    });

    test('同媒体不同形态（thumb / original）是两个任务', () async {
      final List<String> ran = <String>[];
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          ran.add('${t.mediaId}:${t.variant.name}');
          return File('${tempRoot.path}/x.bin');
        },
      );
      await q.enqueue(
        mediaId: 'm3',
        kind: AylaMediaKind.image,
        variant: AylaMediaCacheVariant.thumb,
      );
      await q.enqueue(mediaId: 'm3', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      expect(ran.toSet(), <String>{'m3:thumb', 'm3:original'});
    });
  });

  group('重试语义（最多三次）', () {
    test('前两次失败、第三次成功 → 最终完成且任务移除', () async {
      int calls = 0;
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          calls++;
          if (calls < 3) throw StateError('boom');
          return File('${tempRoot.path}/ok.bin');
        },
      );
      await q.enqueue(mediaId: 'r1', kind: AylaMediaKind.voice);
      await q.waitIdle(timeout: const Duration(seconds: 10));
      expect(calls, 3);
      expect(q.stats.total, 0);
    });

    test('连续失败达上限 → 标记 failed 并保留记录，不再自动重试', () async {
      int calls = 0;
      final AylaMediaDownloadQueue q = makeQueue(
        maxAttempts: 3,
        runner: (AylaDownloadTask t) async {
          calls++;
          throw StateError('always');
        },
      );
      await q.enqueue(mediaId: 'r2', kind: AylaMediaKind.file);
      await q.waitIdle(timeout: const Duration(seconds: 10));
      expect(calls, 3);
      expect(q.stats.failed, 1);
      final AylaDownloadTask t = q.tasks.single;
      expect(t.state, AylaDownloadState.failed);
      expect(t.attempts, 3);
      expect(t.lastError, contains('always'));
    });

    test('云端已过期（MediaExpiredError）不消耗重试次数，直接 failed', () async {
      int calls = 0;
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          calls++;
          throw const MediaExpiredError();
        },
      );
      await q.enqueue(mediaId: 'r3', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      expect(calls, 1, reason: '过期不可恢复，不应反复重试');
      expect(q.tasks.single.state, AylaDownloadState.failed);
      expect(q.tasks.single.lastError, 'media_expired');
    });

    test('返回 null（缓存层放弃）计一次失败', () async {
      int calls = 0;
      final AylaMediaDownloadQueue q = makeQueue(
        maxAttempts: 2,
        runner: (AylaDownloadTask t) async {
          calls++;
          return null;
        },
      );
      await q.enqueue(mediaId: 'r4', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 10));
      expect(calls, 2);
      expect(q.tasks.single.state, AylaDownloadState.failed);
    });
  });

  group('持久化与重启续跑', () {
    test('任务先落盘再执行（进程被杀也能恢复）', () async {
      final Completer<void> gate = Completer<void>();
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async {
          await gate.future; // 永远不完成，模拟「执行中被杀」
          return File('${tempRoot.path}/never.bin');
        },
      );
      await q.enqueue(mediaId: 'p1', kind: AylaMediaKind.image);
      // 落盘发生在执行之前 ⇒ 文件里必须已经有这条任务
      final String text = await queueFile.readAsString();
      expect(text, contains('p1'));
      gate.complete();
    });

    test('重启后 resumeOnStartup 把 running 恢复成 pending 并重跑', () async {
      // 直接伪造「上次进程被杀时留下的队列文件」：状态停在 running。
      // 不通过 first.enqueue 制造，是为了避开「旧实例异步续写」与「新实例读取」
      // 之间的竞态 —— 那个竞态是测试构造问题，不是被测代码的问题。
      await queueFile.writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{
            'media_id': 'p2',
            'kind': 'video',
            'variant': 'original',
            'attempts': 1,
            'state': 'running',
          },
        ],
      }));

      // 新实例读同一份队列文件 = 「app 重新启动」
      final List<String> ran = <String>[];
      final AylaMediaDownloadQueue second = makeQueue(
        runner: (AylaDownloadTask t) async {
          ran.add('${t.mediaId}/${t.attempts}');
          return File('${tempRoot.path}/resumed.bin');
        },
      );
      await second.resumeOnStartup();
      await second.waitIdle(timeout: const Duration(seconds: 30));
      // running 是「上次进程退出时的中间态」⇒ 必须重新排队执行（attempts 保留）
      expect(ran, <String>['p2/1']);
      expect(second.stats.total, 0);
    });

    test('队列文件损坏 → 按空队列处理，不抛', () async {
      await queueFile.writeAsString('{not json');
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async => null,
      );
      await q.ensureReady();
      expect(q.stats.total, 0);
    });

    test('clearFailed 清掉失败记录', () async {
      final AylaMediaDownloadQueue q = makeQueue(
        maxAttempts: 1,
        runner: (AylaDownloadTask t) async => throw StateError('x'),
      );
      await q.enqueue(mediaId: 'c1', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 10));
      expect(q.stats.failed, 1);
      await q.clearFailed();
      expect(q.stats.total, 0);
    });
  });

  group('后台保活同步（Android 前台服务钩子）', () {
    test('入队触发保活同步、队列跑空后再次触发', () async {
      int syncs = 0;
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async =>
            File('${tempRoot.path}/k.bin'),
      );
      q.keepAliveSync = () async {
        syncs++;
      };
      await q.enqueue(mediaId: 'k1', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      // 至少两次：入队后（有活 → 起服务）、完成后（空了 → 停服务）
      expect(syncs, greaterThanOrEqualTo(2));
      expect(q.stats.total, 0);
    });

    test('未注入钩子时不崩（桌面/iOS 路径）', () async {
      final AylaMediaDownloadQueue q = makeQueue(
        runner: (AylaDownloadTask t) async =>
            File('${tempRoot.path}/n.bin'),
      );
      await q.enqueue(mediaId: 'k2', kind: AylaMediaKind.image);
      await q.waitIdle(timeout: const Duration(seconds: 30));
      expect(q.stats.total, 0);
    });
  });

  group('并发上限', () {
    test('同时执行数不超过 maxConcurrent', () async {
      int concurrent = 0;
      int peak = 0;
      final AylaMediaDownloadQueue q = AylaMediaDownloadQueue(
        maxConcurrent: 2,
        runner: (AylaDownloadTask t) async {
          concurrent++;
          peak = concurrent > peak ? concurrent : peak;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          concurrent--;
          return File('${tempRoot.path}/c.bin');
        },
      );
      q.setQueueFileForTest(queueFile);
      for (int i = 0; i < 6; i++) {
        await q.enqueue(mediaId: 'cc$i', kind: AylaMediaKind.image);
      }
      await q.waitIdle(timeout: const Duration(seconds: 10));
      expect(peak, lessThanOrEqualTo(2));
      expect(q.stats.total, 0);
    });
  });
}
