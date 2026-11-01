/// B4 纹理尺寸固定回归锁（开发文档 §3 B4；需求 §3.1 B4 / §5.1 S4）。
///
/// ## 缺陷
/// `media_kit_video` 的 `VideoOutput::CheckAndResize()`
/// （`third_party/media_kit_video/windows/video_output.cc:241–266`）在
/// 「视频要求尺寸 ≠ 当前纹理尺寸」时 `UnregisterTexture` + 新建纹理；
/// 而 `GetVideoWidth()`（同文件 `:366–413`）在 `width_` 为空时读的是**视频分辨率**
/// ⇒ 窗口尺寸变化让 mpv 重算输出参数就注销重建纹理（闪黑一帧，严重时永久黑）。
/// Ayla 从未调用 `VideoController.setSize()` ⇒ 这条保护一直没生效。
///
/// ## 修法（本文件锁住决策部分；平台调用在 `media_kit_impl.dart`）
/// 监听 `p.stream.width/height`，**只在视频原生分辨率真的变化时**调 `setSize`：
/// 视频是 1920×1080 就固定 1920×1080，此后再怎么缩放窗口 `CheckAndResize` 都走
/// early-return ⇒ 不重建纹理。窗口尺寸变化根本不会进入本决策器。
///
/// ## 本测试锁住什么
/// 1. **同分辨率只调一次** setSize（幂等）；
/// 2. 分辨率变化才更新；
/// 3. 连续变化在去抖窗口（200ms）内合并成一次；
/// 4. 无效值（null / 0 / 负数）一律忽略（mpv 切分片时会短暂报 0）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/player/texture_size.dart';

void main() {
  late List<AylaTextureSize> applied;

  AylaTextureSizeDecider build({Duration debounce = Duration.zero}) {
    applied = <AylaTextureSize>[];
    return AylaTextureSizeDecider(
      onApply: applied.add,
      debounce: debounce,
    );
  }

  group('同分辨率只调一次 setSize', () {
    test('首次上报 1920x1080 ⇒ 下发一次', () async {
      final AylaTextureSizeDecider d = build();
      expect(d.offer(1920, 1080), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(applied, <AylaTextureSize>[const AylaTextureSize(1920, 1080)]);
      d.dispose();
    });

    test('重复上报同一分辨率 ⇒ 不再下发（窗口尺寸变化就是这么被挡掉的）', () async {
      final AylaTextureSizeDecider d = build();
      d.offer(1920, 1080);
      await Future<void>.delayed(Duration.zero);
      expect(d.offer(1920, 1080), isFalse);
      expect(d.offer(1920, 1080), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied.length,
        1,
        reason: '同分辨率重复 setSize 没有意义，而每次都可能撞上一次 Resize',
      );
      d.dispose();
    });

    test('先 width 后 height 的两次上报只算一次（真实 mpv 上报形态）', () async {
      final AylaTextureSizeDecider d = build(
        debounce: const Duration(milliseconds: 30),
      );
      // media_kit 的 width/height 是两条独立流，落地顺序不保证
      d.offer(1920, null);
      d.offer(1920, 1080);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(applied, <AylaTextureSize>[const AylaTextureSize(1920, 1080)]);
      d.dispose();
    });
  });

  group('分辨率变化才更新', () {
    test('1920x1080 → 1280x720 ⇒ 再下发一次', () async {
      final AylaTextureSizeDecider d = build();
      d.offer(1920, 1080);
      await Future<void>.delayed(Duration.zero);
      expect(d.offer(1280, 720), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(applied, <AylaTextureSize>[
        const AylaTextureSize(1920, 1080),
        const AylaTextureSize(1280, 720),
      ]);
      d.dispose();
    });

    test('只变宽或只变高都算变化', () async {
      final AylaTextureSizeDecider d = build();
      d.offer(1920, 1080);
      await Future<void>.delayed(Duration.zero);
      expect(d.offer(1920, 720), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(applied.last, const AylaTextureSize(1920, 720));
      d.dispose();
    });
  });

  group('去抖（连续变化 200ms 内合并）', () {
    test('窗口内连续 3 个不同分辨率 ⇒ 只落最后一次', () async {
      final AylaTextureSizeDecider d = build(
        debounce: const Duration(milliseconds: 40),
      );
      d.offer(1920, 1080);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      d.offer(1280, 720);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      d.offer(960, 540);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        applied,
        <AylaTextureSize>[const AylaTextureSize(960, 540)],
        reason: '一次真实的分辨率切换会连续上报几次，每次都 setSize 会连闪几帧',
      );
      d.dispose();
    });

    test('生产去抖窗口 = 200ms', () {
      expect(kTextureSizeDebounce, const Duration(milliseconds: 200));
    });
  });

  group('无效值一律忽略', () {
    test('null / 0 / 负数 ⇒ 不接受，也不覆盖已应用的尺寸', () async {
      final AylaTextureSizeDecider d = build();
      d.offer(1920, 1080);
      await Future<void>.delayed(Duration.zero);
      expect(d.offer(null, 1080), isFalse);
      expect(d.offer(1920, null), isFalse);
      expect(d.offer(0, 0), isFalse);
      expect(d.offer(-1, -1), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied.length,
        1,
        reason: 'mpv 切分片时会短暂上报 0，跟着改成 0x0 会比黑屏更难恢复',
      );
      d.dispose();
    });
  });

  test('dispose 取消挂起的计时器（不在已释放的 controller 上打 setSize）', () async {
    final AylaTextureSizeDecider d = build(
      debounce: const Duration(milliseconds: 50),
    );
    d.offer(1920, 1080);
    expect(d.hasPending, isTrue);
    d.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(applied, isEmpty);
  });
}
