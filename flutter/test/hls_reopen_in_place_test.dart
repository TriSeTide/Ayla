/// P1「保留实例、只换播放源」的回归锁（`lib/player/hls_player.dart`）。
///
/// ## 这组测试为什么存在
/// 用户实报「唤出小窗黑很久 / 关小窗回页面黑很久」。本机实测（真实 libmpv +
/// 真实 SRS 流，2026-11-02）确认那条路径是**销毁整个播放器再重建**：
/// 「销毁 → 重建 → 出首帧」= 695~824ms。
///
/// 修法是把「销毁重建」降级成最后一档：先试 [HlsReopenable] 的原地换源。
/// 本文件锁住三条不变量：
/// 1. 平台**支持**原地换源且成功 ⇒ **不 dispose 任何实例**（不重建纹理/解码器）；
/// 2. 平台**不支持** ⇒ 退回完整重建（行为与改动前一致，不能更差）；
/// 3. 平台支持但**失败** ⇒ 同样退回完整重建（否则永久黑屏，B3 的教训）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/player/hls_player.dart';

/// 假平台：可选择是否实现 [HlsReopenable]，以及就地换源是否成功。
class _FakeReopenablePlatform implements HlsPlatformPlayer, HlsReopenable {
  _FakeReopenablePlatform({required this.reopenSucceeds});

  final bool reopenSucceeds;
  int attachCalls = 0;
  int disposeCalls = 0;
  int reopenCalls = 0;
  int stopKeepCalls = 0;

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
  Future<void> attach(String url) async => attachCalls += 1;

  @override
  Future<void> play() async {}

  @override
  Future<bool> seekToLiveEdge() async => false;

  @override
  Widget? buildView() => null;

  @override
  Future<void> dispose() async => disposeCalls += 1;

  @override
  Future<bool> reopenInPlace(String url) async {
    reopenCalls += 1;
    return reopenSucceeds;
  }

  @override
  Future<void> stopKeepInstance() async => stopKeepCalls += 1;
}

/// 不支持原地换源的假平台（= 移动端 video_player 那一类）。
class _FakePlainPlatform implements HlsPlatformPlayer {
  int attachCalls = 0;
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
  Future<void> attach(String url) async => attachCalls += 1;
  @override
  Future<void> play() async {}
  @override
  Future<bool> seekToLiveEdge() async => false;
  @override
  Widget? buildView() => null;
  @override
  Future<void> dispose() async => disposeCalls += 1;
}

void main() {
  const String url = 'https://example.test/live/a.m3u8';

  /// 装好一个「已出过画面」的控制器（`_started == true` 是原地换源的前置条件）。
  Future<HlsPlaybackController> started(
    List<HlsPlatformPlayer> created,
    HlsPlatformPlayer Function() make,
  ) async {
    final HlsPlaybackController c = HlsPlaybackController(
      () {
        final HlsPlatformPlayer p = make();
        created.add(p);
        return p;
      },
      HlsPlayerCallbacks()..onLog = (String _) {},
      stallTimeout: const Duration(milliseconds: 50),
      rebuildCooldown: Duration.zero,
    );
    await c.attach(url);
    // 让平台报一次位置前进 ⇒ 控制器认为「真的出过画面」。
    created.last.onPosition?.call(const Duration(seconds: 3));
    return c;
  }

  test('平台支持原地换源且成功 ⇒ 不 dispose、不新建实例（纹理不重建）', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = await started(
      created,
      () => _FakeReopenablePlatform(reopenSucceeds: true),
    );
    final _FakeReopenablePlatform first =
        created.single as _FakeReopenablePlatform;

    await c.rebuild(url);

    expect(first.reopenCalls, 1, reason: '必须尝试原地换源');
    expect(first.disposeCalls, 0, reason: '成功时绝不允许销毁实例');
    expect(created.length, 1, reason: '成功时绝不允许新建实例');
    expect(first.attachCalls, 1, reason: '成功时不应重新 attach');
  });

  test('平台支持但原地换源失败 ⇒ 退回完整重建（不能永久黑屏）', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = await started(
      created,
      () => _FakeReopenablePlatform(reopenSucceeds: false),
    );
    final _FakeReopenablePlatform first =
        created.single as _FakeReopenablePlatform;

    await c.rebuild(url);

    expect(first.reopenCalls, 1);
    expect(first.disposeCalls, 1, reason: '失败必须退回 dispose + attach');
    expect(created.length, 2, reason: '失败必须建新实例兜底');
  });

  test('平台不支持原地换源 ⇒ 行为与改动前一致（dispose + attach）', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = await started(
      created,
      () => _FakePlainPlatform(),
    );
    final _FakePlainPlatform first = created.single as _FakePlainPlatform;

    await c.rebuild(url);

    expect(first.disposeCalls, 1);
    expect(created.length, 2);
    expect((created.last as _FakePlainPlatform).attachCalls, 1);
  });

  test('suspendKeepInstance ⇒ 保留实例（不 dispose），可再次原地恢复', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = await started(
      created,
      () => _FakeReopenablePlatform(reopenSucceeds: true),
    );
    final _FakeReopenablePlatform first =
        created.single as _FakeReopenablePlatform;

    await c.suspendKeepInstance();
    expect(first.stopKeepCalls, 1, reason: '必须走 stop（不是 pause）');
    expect(first.disposeCalls, 0, reason: '挂起绝不允许销毁实例');
    expect(c.suspended, isTrue);

    final bool ok = await c.resumeInPlace();
    expect(ok, isTrue);
    expect(first.reopenCalls, 1);
    expect(created.length, 1, reason: '恢复不得新建实例');
  });

  test('平台不支持保留实例 ⇒ suspend 退回 destroy（不留下半死状态）', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = await started(
      created,
      () => _FakePlainPlatform(),
    );
    final _FakePlainPlatform first = created.single as _FakePlainPlatform;

    await c.suspendKeepInstance();
    expect(first.disposeCalls, 1);
    expect(c.suspended, isFalse, reason: '退回 destroy 后不能留在挂起态');
  });

  test('未出过画面就 rebuild ⇒ 不走原地换源（没有可保的画面）', () async {
    final List<HlsPlatformPlayer> created = <HlsPlatformPlayer>[];
    final HlsPlaybackController c = HlsPlaybackController(
      () {
        final HlsPlatformPlayer p =
            _FakeReopenablePlatform(reopenSucceeds: true);
        created.add(p);
        return p;
      },
      HlsPlayerCallbacks()..onLog = (String _) {},
      rebuildCooldown: Duration.zero,
    );
    await c.attach(url);

    await c.rebuild(url);

    final _FakeReopenablePlatform first =
        created.first as _FakeReopenablePlatform;
    expect(first.reopenCalls, 0, reason: '没出过画面应直接完整重建');
    expect(created.length, 2);
  });
}
