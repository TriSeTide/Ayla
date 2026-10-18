/// HLS 播放器自愈状态机回归锁（`lib/player/hls_player.dart`）。
///
/// 用户 2026-10-18 实报：直播间黑底 + 白色转圈永远不停、没有任何错误文案。
/// 根因（本文件逐条锁住）：
/// 1. `playing=true` 被当成「已恢复」—— mpv 在「连上但无数据」时同样是 playing，
///    于是卡顿计时器被立刻取消 ⇒ 永不重建、永不报错；
/// 2. 卡顿计时器在冷却期命中后**只 return 未重排** ⇒ 之后永远不再检查；
/// 3. 自动重建没有上限 ⇒ 即使真的重建也是无限循环，UI 永远停在 loading。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/player/hls_player.dart';

/// 可控的假平台播放器：测试直接驱动回调。
class _FakePlatform implements HlsPlatformPlayer {
  int attachCalls = 0;
  int playCalls = 0;
  int disposeCalls = 0;

  @override
  void Function(HlsState state)? onStateChange;
  @override
  void Function()? onStall;
  @override
  void Function()? onResume;
  @override
  void Function(String detail)? onFatal;
  @override
  void Function(Duration position)? onPosition;

  @override
  Future<void> attach(String url) async {
    attachCalls += 1;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<bool> seekToLiveEdge() async => false;

  @override
  Widget? buildView() => null;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}

void main() {
  late List<_FakePlatform> created;
  late List<String> errors;

  HlsPlaybackController build({
    Duration stall = const Duration(milliseconds: 40),
    Duration cooldown = const Duration(milliseconds: 10),
    int maxRebuilds = kMaxAutoRebuilds,
  }) {
    created = <_FakePlatform>[];
    errors = <String>[];
    return HlsPlaybackController(
      () {
        final _FakePlatform p = _FakePlatform();
        created.add(p);
        return p;
      },
      HlsPlayerCallbacks()..onError = errors.add,
      stallTimeout: stall,
      rebuildCooldown: cooldown,
      maxAutoRebuilds: maxRebuilds,
    );
  }

  test('playing=true 但位置不动（mpv「连上无数据」）→ 仍会自愈重建', () async {
    final HlsPlaybackController c = build();
    await c.attach('https://x/live/a.m3u8');
    final _FakePlatform p = created.single;
    // mpv 的典型卡死态：playing 为真、buffering 为真、position 恒为 0
    p.onStateChange?.call(HlsState.playing);
    p.onStall?.call();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      created.length,
      greaterThan(1),
      reason: 'playing=true 不得取消卡顿计时器，否则永远不重建（用户实报的转圈）',
    );
  });

  test('位置真的前进 ⇒ 记为已起播，卡顿不会误判重建', () async {
    final HlsPlaybackController c = build();
    await c.attach('https://x/live/a.m3u8');
    final _FakePlatform p = created.single;
    p.onPosition?.call(const Duration(seconds: 2));
    p.onStateChange?.call(HlsState.playing);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(created.length, 1, reason: '已起播且未报 stall ⇒ 不应重建');
  });

  test('自动重建有上限：连续失败后把错误交给 UI（不再无限转圈）', () async {
    final HlsPlaybackController c = build(
      stall: const Duration(milliseconds: 30),
      cooldown: const Duration(milliseconds: 20),
    );
    await c.attach('https://x/live/a.m3u8');
    // 每次新实例都立刻报 fatal（模拟「地址不可达」的确定性失败）
    for (int i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      created.last.onFatal?.call('boom');
      if (errors.isNotEmpty) break;
    }
    expect(errors, isNotEmpty, reason: '达到上限必须上报错误，UI 才能显示「播放失败 + 重试」');
    expect(
      created.length,
      lessThanOrEqualTo(kMaxAutoRebuilds + 2),
      reason: '不得无限重建',
    );
  });

  test('卡顿计时器在冷却期命中后会重排（不静默卡死）', () async {
    final HlsPlaybackController c = build(
      stall: const Duration(milliseconds: 20),
      cooldown: const Duration(milliseconds: 120),
    );
    await c.attach('https://x/live/a.m3u8');
    created.single.onStall?.call();
    // 20ms 后进入冷却期分支（此时距 attach 仍 < 120ms）→ 必须重排而不是放弃
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      created.length,
      greaterThan(1),
      reason: '冷却期命中必须重排计时器，否则永久停在转圈（用户实报现象）',
    );
  });

  test('retry 会重置自愈计数（手动重试不设上限）', () async {
    final HlsPlaybackController c = build();
    await c.attach('https://x/live/a.m3u8');
    await c.retry('https://x/live/a.m3u8');
    expect(created.length, 2, reason: 'retry 必须真的重建平台播放器');
    expect(created.first.disposeCalls, 1);
  });

  test('destroy 幂等且清空状态', () async {
    final HlsPlaybackController c = build();
    await c.attach('https://x/live/a.m3u8');
    await c.destroy();
    await c.destroy();
    expect(c.state, HlsState.idle);
    expect(created.single.disposeCalls, 1);
  });

  test('attach 幂等：同 URL 不重建', () async {
    final HlsPlaybackController c = build();
    await c.attach('https://x/live/a.m3u8');
    await c.attach('https://x/live/a.m3u8');
    expect(created.length, 1);
    expect(created.single.playCalls, 1);
  });
}
