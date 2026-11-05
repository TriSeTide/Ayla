/// 直播音量（2026-11-04 用户需求）回归锁。
///
/// 用户原话：「默认把声音打开。同时，为 Ayla Flutter 的直播间也加上音量开启关闭，
/// Ayla 直播界面默认开。但是 web 和 Flutter 的开播界面，默认把声音关闭。」
///
/// 覆盖四块：
/// 1. **两端默认值不同**：观众端缺省有声、开播控制台缺省静音（偏好键分开）；
/// 2. **偏好持久化**：用户手势写入、取消静音删键、退房不清、跨场次保留；
/// 3. **播放器层 setMuted**：双平台各自落地，且实现不抛异常（画面优先于声音）；
/// 4. **自愈重建不丢静音**：每次 attach（含 rebuild 走的那条）都会新建平台播放器 ⇒
///    必须在 attach 之后重新下发；否则重建一次就恢复满音量。
/// 5. **音量键 UI**：两态图标/文案、只 live 时渲染、点击重置 3s 自动隐藏。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/storage/ayla_storage_paths.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/player/platforms/media_kit_impl.dart';
import '../lib/player/platforms/video_player_impl.dart';
import '../lib/state/live_state.dart';
import '../lib/theme/app_icons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_player.dart';

/// 记录静音下发的平台播放器桩。
///
/// 每个实例代表**一次 attach 新建出来的平台播放器** —— 自愈重建会再 new 一个，
/// 这正是「重建后音量是否保持」的判据。
class _RecordingPlayer implements HlsPlatformPlayer {
  _RecordingPlayer(this.instances);

  /// 全场共享（工厂每 new 一个就 append 到同一个表里）。
  final List<_RecordingPlayer> instances;

  @override
  void Function(HlsState state)? onStateChange;
  @override
  void Function()? onStall;
  @override
  void Function()? onResume;
  @override
  void Function(String detail)? onFatal;

  /// P1-4 新增接口成员（非 fatal 的分片级故障上报）。替身不模拟它，留空即可。
  @override
  void Function(String detail)? onFragmentError;

  @override
  void Function(Duration position)? onPosition;

  /// 本实例收到过的静音下发（按顺序）。
  final List<bool> muteCalls = <bool>[];

  /// 本实例**当前**的静音态（最后一次下发的值；未下发过 = false）。
  bool muted = false;

  @override
  Future<void> attach(String url) async {}

  @override
  Future<void> play() async {}

  @override
  Future<bool> seekToLiveEdge() async => true;

  @override
  Widget? buildView() => const ColoredBox(color: Color(0xFF2A3550));

  @override
  Future<void> setMuted(bool muted) async {
    muteCalls.add(muted);
    this.muted = muted;
  }

  @override
  Future<void> dispose() async {}
}

class _LiveStub {
  AylaLiveSrsStatus srsStatus = AylaLiveSrsStatus.live;

  Future<AylaLiveChannelSnapshot> channel(String id) async =>
      AylaLiveChannelSnapshot(
        id: id,
        title: '深夜电台',
        hlsUrl: 'https://cdn.example/live/$id.m3u8',
        status: AylaLiveStatus.live,
      );

  Future<AylaLiveStatusResult> status(String id) async =>
      AylaLiveStatusResult(status: srsStatus);

  Future<AylaLiveViewersResult> viewers(String id) async =>
      AylaLiveViewersResult(channelId: id, count: 3);
}

void _noop() {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 内存里的偏好表（注入到 [aylaLiveMutedReader] / [aylaLiveMutedWriter]）。
  final Map<String, bool> prefs = <String, bool>{};
  String prefKey({required bool owner}) =>
      owner ? kAylaLiveOwnerMutedKey : kAylaLiveMutedKey;

  late Directory tempRoot;

  setUp(() async {
    // 数据根指到临时目录（同 media_cache_test 的手法）：偏好落盘是真实 IO，
    // **绝不能**写到开发机的 `<exe目录>/data`（storage_no_c_drive_lock_test 的口径）。
    tempRoot = await Directory.systemTemp.createTemp('ayla_live_mute_');
    aylaResetDataRootForTest(root: '${tempRoot.path}/data');
    aylaResetLiveMutePrefsForTest();
    prefs.clear();
    aylaLiveMutedReader = ({required bool owner}) {
      final bool? stored = prefs[prefKey(owner: owner)];
      // 与真实实现同语义：无记录 ⇒ 该端缺省值。
      return stored ?? aylaDefaultLiveMuted(owner: owner);
    };
    aylaLiveMutedWriter = ({required bool muted, required bool owner}) {
      if (muted) {
        prefs[prefKey(owner: owner)] = true;
      } else {
        prefs.remove(prefKey(owner: owner));
      }
    };
  });

  tearDown(() async {
    aylaLiveMutedReader = null;
    aylaLiveMutedWriter = null;
    aylaResetLiveMutePrefsForTest();
    aylaResetDataRootForTest();
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  group('两端缺省值（design.md §12.7.6.4）', () {
    test('观众端缺省有声、开播端缺省静音', () {
      expect(aylaDefaultLiveMuted(owner: false), isFalse);
      expect(aylaDefaultLiveMuted(owner: true), isTrue);
      expect(aylaReadLiveMuted(), isFalse);
      expect(aylaReadLiveMuted(owner: true), isTrue);
    });

    test('偏好键与 web 同名（ayla.live.muted / ayla.live.owner.muted）', () {
      expect(kAylaLiveMutedKey, 'ayla.live.muted');
      expect(kAylaLiveOwnerMutedKey, 'ayla.live.owner.muted');
    });

    test('取消静音 = 删键（不存 0），两端互不影响', () {
      aylaWriteLiveMuted(muted: true, owner: true);
      expect(aylaReadLiveMuted(owner: true), isTrue);
      expect(prefs.containsKey(kAylaLiveOwnerMutedKey), isTrue);
      // 观众端不受影响：仍然有声
      expect(aylaReadLiveMuted(), isFalse);

      aylaWriteLiveMuted(muted: false, owner: true);
      expect(prefs.containsKey(kAylaLiveOwnerMutedKey), isFalse);
      expect(aylaReadLiveMuted(owner: true), isTrue);

      aylaWriteLiveMuted(muted: true);
      expect(aylaReadLiveMuted(), isTrue);
      expect(aylaReadLiveMuted(owner: true), isTrue);
    });
  });

  group('偏好落盘（真实 IO：<数据根>/profile/ayla_live_prefs.json）', () {
    test('写入 → 读盘回来仍在；取消静音 → 键被删掉', () async {
      // 本组必须走**真实**实现：先把注入点摘掉（外层 setUp 装的）。
      aylaLiveMutedReader = null;
      aylaLiveMutedWriter = null;
      await aylaLoadLiveMutePrefs();
      expect(aylaReadLiveMuted(), isFalse, reason: '空文件 ⇒ 观众端缺省有声');
      expect(aylaReadLiveMuted(owner: true), isTrue, reason: '空文件 ⇒ 开播端缺省静音');

      aylaWriteLiveMuted(muted: true);
      expect(aylaReadLiveMuted(), isTrue, reason: '内存缓存立即生效（同步，对齐 web localStorage）');

      final File file = File(
        '${tempRoot.path}/data/$kAylaProfileDirName/$kAylaLivePrefsFileName',
      );
      // 落盘是 fire-and-forget：轮询等它出现（不 sleep 固定时长）。
      for (int i = 0; i < 200 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(file.existsSync(), isTrue, reason: '偏好必须真的落盘（${file.path}）');
      expect(file.readAsStringSync().contains(kAylaLiveMutedKey), isTrue);

      // 模拟进程重启：清缓存后重新读盘。
      aylaResetLiveMutePrefsForTest();
      await aylaLoadLiveMutePrefs();
      expect(aylaReadLiveMuted(), isTrue, reason: '重启后偏好仍在（跨场次保留）');

      aylaWriteLiveMuted(muted: false);
      aylaResetLiveMutePrefsForTest();
      await aylaLoadLiveMutePrefs();
      expect(aylaReadLiveMuted(), isFalse);
    });
  });

  group('播放器层 setMuted（双平台）', () {
    test('HlsPlaybackController：setMuted 下发到平台实例 + isMuted 记住', () async {
      final List<_RecordingPlayer> made = <_RecordingPlayer>[];
      final HlsPlaybackController controller = HlsPlaybackController(
        () {
          final _RecordingPlayer p = _RecordingPlayer(made);
          made.add(p);
          return p;
        },
        HlsPlayerCallbacks(),
      );
      await controller.attach('https://cdn.example/a.m3u8');
      expect(controller.isMuted, isFalse, reason: '缺省有声（平台默认就是满音量）');

      await controller.setMuted(true);
      expect(controller.isMuted, isTrue);
      expect(made.single.muteCalls, <bool>[true]);
      expect(made.single.muted, isTrue);

      await controller.toggleMuted();
      expect(controller.isMuted, isFalse);
      expect(made.single.muteCalls, <bool>[true, false]);
    });

    test('自愈重建（rebuild）后音量必须保持（新建平台实例也要重新下发）', () async {
      final List<_RecordingPlayer> made = <_RecordingPlayer>[];
      final HlsPlaybackController controller = HlsPlaybackController(
        () {
          final _RecordingPlayer p = _RecordingPlayer(made);
          made.add(p);
          return p;
        },
        HlsPlayerCallbacks(),
      );
      await controller.attach('https://cdn.example/a.m3u8');
      await controller.setMuted(true);
      expect(made.single.muted, isTrue);

      // 自愈重建：rebuild → attach → _makePlatform() **新建**一个平台播放器
      // （新实例的音量是平台默认 = 满音量）。
      await controller.rebuild('https://cdn.example/a.m3u8');
      expect(made.length, 2, reason: '重建必须真的新建平台实例（否则这条测试没意义）');
      expect(
        made[1].muted,
        isTrue,
        reason: '重建后的新实例必须收到静音下发 —— 漏了这一步就是「自愈一次声音又炸出来」',
      );
      expect(controller.isMuted, isTrue);

      // 取消静音后再重建：新实例是「有声」档，不必额外下发（平台默认即满音量）。
      await controller.setMuted(false);
      await controller.rebuild('https://cdn.example/a.m3u8');
      expect(made.length, 3);
      expect(made[2].muteCalls, isEmpty);
      expect(made[2].muted, isFalse);
    });

    test('media_kit 实现：未 attach 时下发静音也安全（不抛异常）', () async {
      // 会话 start 的 _initMute 可能早于平台实例就绪 ⇒ 必须容错。
      await MediaKitHls().setMuted(true);
      await MediaKitHls().setMuted(false);
    });

    test('video_player 实现：未 attach 时下发静音也安全（不抛异常）', () async {
      await VideoPlayerHls().setMuted(true);
      await VideoPlayerHls().setMuted(false);
    });
  });

  group('会话层：两端默认值差异 + 偏好持久化', () {
    late AylaLiveState live;
    late _LiveStub stub;
    final List<_RecordingPlayer> made = <_RecordingPlayer>[];

    AylaLiveRoomSession sessionFor({required bool isOwnerConsole}) =>
        AylaLiveRoomSession(
          channelId: 'c1',
          liveState: live,
          // token 为 null ⇒ connect() 是 no-op，不建真实 WS 连接。
          liveWs: AylaLiveWsClient(accessToken: () => null),
          playerFactory: () => HlsPlaybackController(
            () {
              final _RecordingPlayer p = _RecordingPlayer(made);
              made.add(p);
              return p;
            },
            HlsPlayerCallbacks(),
          ),
          channelFetcher: stub.channel,
          statusFetcher: stub.status,
          viewersFetcher: stub.viewers,
          isOwnerConsole: isOwnerConsole,
        );

    setUp(() {
      live = AylaLiveState();
      stub = _LiveStub();
      made.clear();
    });

    tearDown(() => live.dispose());

    test('观众端首次进房 ⇒ 有声（缺省），且 store 投影同步', () async {
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: false);
      await session.start();
      expect(session.isOwnerConsole, isFalse);
      expect(session.muted, isFalse);
      expect(live.muted, isFalse);
      expect(live.mutedOwner, isFalse);
      expect(made.single.muted, isFalse, reason: '缺省有声 ⇒ 不下发 0 音量');
      session.dispose();
    });

    test('开播控制台首次进房 ⇒ 仍静音（缺省静音），且偏好键未被写', () async {
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: true);
      await session.start();
      expect(session.isOwnerConsole, isTrue);
      expect(session.muted, isTrue, reason: '开播端缺省静音（用户 2026-11-04 明确要求）');
      expect(live.muted, isTrue);
      expect(live.mutedOwner, isTrue);
      expect(made.single.muted, isTrue, reason: '静音必须真的下发到平台播放器');
      expect(
        prefs.containsKey(kAylaLiveOwnerMutedKey),
        isFalse,
        reason: '缺省值不是「用户的显式选择」⇒ 不该写偏好键',
      );
      session.dispose();
    });

    test('开播端取消静音 ⇒ 只影响开播键，观众端偏好不受影响', () async {
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: true);
      await session.start();
      expect(session.muted, isTrue);

      await session.toggleMuted();
      expect(session.muted, isFalse);
      expect(live.muted, isFalse);
      expect(made.single.muted, isFalse, reason: '取消静音必须下发到平台播放器');
      expect(
        prefs.containsKey(kAylaLiveOwnerMutedKey),
        isFalse,
        reason: '取消静音 = 删键回到缺省（web writeLiveMuted 同语义）',
      );
      expect(
        prefs.containsKey(kAylaLiveMutedKey),
        isFalse,
        reason: '观众端偏好不得被开播端污染',
      );
      session.dispose();
    });

    test('观众端静音 ⇒ 写观众键，开播端偏好不受影响；退房不清偏好', () async {
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: false);
      await session.start();
      await session.setMuted(true);
      expect(session.muted, isTrue);
      expect(prefs[kAylaLiveMutedKey], isTrue);
      expect(prefs.containsKey(kAylaLiveOwnerMutedKey), isFalse);

      // 退房（web leave：偏好不写、不重置）
      await session.stop();
      expect(prefs[kAylaLiveMutedKey], isTrue, reason: '退房不得清偏好（跨直播间保留）');
      expect(aylaReadLiveMuted(), isTrue);
      session.dispose();
    });

    test('端语义晚到时切换（setMuteOwner）：控制台不会先按观众端响一下', () async {
      // 控制台页的 isOwner 要等频道详情回来才知道 ⇒ 会话先按「控制台」建、再收敛。
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: true);
      await session.start();
      expect(session.muted, isTrue);

      // 详情回来：确认就是自己的控制台 ⇒ 端语义不变 ⇒ no-op（不重放下发）。
      await session.setMuteOwner(true);
      expect(session.muted, isTrue);

      // 详情回来：其实不是自己的（`is_owner` false）⇒ 切回观众端语义 ⇒ 按观众端偏好
      // （缺省有声）重新应用。
      await session.setMuteOwner(false);
      expect(session.isOwnerConsole, isFalse);
      expect(session.muted, isFalse);
      expect(live.mutedOwner, isFalse);
      expect(made.last.muted, isFalse, reason: '切端语义必须真的把音量放回去');
      session.dispose();
    });

    test('观众端已存静音偏好 ⇒ 下次进房仍是静音（跨场次）', () async {
      aylaWriteLiveMuted(muted: true);
      final AylaLiveRoomSession session = sessionFor(isOwnerConsole: false);
      await session.start();
      expect(session.muted, isTrue);
      expect(made.single.muted, isTrue);
      session.dispose();
    });
  });

  group('AylaLivePlayer 音量键（tsx 397–417 + design.md §12.7.3 / §12.7.6.3）', () {
    Widget host(WidgetTester tester, Widget child) {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      return MaterialApp(
        home: previewScope(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, child: child),
          ),
        ),
      );
    }

    Finder byLabel(String label) => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == label,
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('muted=true ⇒ 「打开声音」+ iconSpeakerOff(16)；点击回调一次', (
      WidgetTester tester,
    ) async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            muted: true,
            onToggleMute: () => toggles += 1,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer)); // 显示控件
      await tester.pump();

      expect(byLabel('打开声音'), findsOneWidget);
      expect(byLabel('静音'), findsNothing);
      final AylaIcon icon = tester.widget<AylaIcon>(
        find.byWidgetPredicate(
          (Widget w) => w is AylaIcon && w.icon.name == 'iconSpeakerOff',
        ),
      );
      expect(icon.size, 16); // tsx 415 的 width/height = 16

      await tester.tap(byLabel('打开声音'));
      await tester.pump();
      expect(toggles, 1);
    });

    testWidgets('muted=false ⇒ 「静音」+ iconSpeaker', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            onToggleMute: _noop,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer));
      await tester.pump();

      expect(byLabel('静音'), findsOneWidget);
      expect(byLabel('打开声音'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is AylaIcon && w.icon.name == 'iconSpeaker',
        ),
        findsOneWidget,
      );
    });

    testWidgets('未接 onToggleMute ⇒ 不渲染音量键（画布/测试档保持既有渲染）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(tester, const AylaLivePlayer(srsStatus: AylaLiveSrsStatus.live)),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer));
      await tester.pump();
      expect(byLabel('跳到最新画面'), findsOneWidget, reason: '刷新键照旧');
      expect(byLabel('静音'), findsNothing);
      expect(byLabel('打开声音'), findsNothing);
    });

    testWidgets('非 live / 播放失败态不渲染音量键（与其它悬浮钮同显隐）', (
      WidgetTester tester,
    ) async {
      const List<AylaLivePlayer> players = <AylaLivePlayer>[
        AylaLivePlayer(onToggleMute: _noop),
        AylaLivePlayer(
          srsStatus: AylaLiveSrsStatus.idle,
          onToggleMute: _noop,
        ),
        AylaLivePlayer(
          srsStatus: AylaLiveSrsStatus.live,
          playerError: 'boom',
          onToggleMute: _noop,
        ),
      ];
      for (final AylaLivePlayer player in players) {
        await tester.pumpWidget(host(tester, player));
        await settle(tester);
        expect(byLabel('静音'), findsNothing);
        expect(byLabel('打开声音'), findsNothing);
      }
    });

    testWidgets('点音量键会重置 3s 自动隐藏计时（点按钮 = 有动作）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLivePlayer(
            srsStatus: AylaLiveSrsStatus.live,
            onToggleMute: _noop,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(AylaLivePlayer));
      await tester.pump();
      AnimatedOpacity layer() => tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first,
      );
      expect(layer().opacity, 1);

      // 走过 2s 后点音量键 ⇒ 计时被重置（原本 3s 后隐藏）
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(byLabel('静音'));
      await tester.pump();
      expect(layer().opacity, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(layer().opacity, 1, reason: '重置后 2s 仍可见（原来的 3s 已过）');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(layer().opacity, 0, reason: '再过 2s 到点自动隐藏');
    });
  });
}
