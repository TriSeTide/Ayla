/// 语音条真的会跳 —— **生产装配路径**的接线回归锁（2026-10-26）。
///
/// ## 用户实报
/// 「语音房里听得见声音，但音量条完全不跳动」。上一轮（6185995）已把
/// voice_support.dart 里构造成员行的 ref.read(voiceStateProvider) 改成 ref.watch，
/// 并通过了 voice_audio_level_subscription_test.dart —— **仍然不跳**。
///
/// ## 真正根因（本文件锁的就是它）
/// 1. lib/audio/voice_media.dart 的 aylaVoiceMedia() 是**全局单例**；
///    AylaVoiceMedia 在**构造体里**就把 RelayCallbacks / AudioEngineCallbacks
///    逐条转发到它自己的那份 _events（引擎每 100ms 打
///    _events.onRemoteAudioLevels?.call(snapshot)）。
/// 2. lib/pages/voice_support.dart 的页面装配此前写
///    media: aylaVoiceMedia()（**不传 events**），再加上
///    bindMediaEvents(mediaEvents ?? AylaVoiceMediaEvents())
///    —— 会话层把回调挂到**另一个新建对象**上，而单例的那份 _events 永远没人绑。
///    ⇒ setRemoteAudioLevels / setLocalAudioLevel / setMedia **永不触发**，
///    音频链路本身正常（所以照样听得见声音）。
///
/// ## 为什么必须是「装配级」而不是「store 级」
/// store 级测试（voice_audio_level_subscription_test.dart / room_voice_test.dart）
/// 直接调 voice.setRemoteAudioLevels(...)，**绕过了整条装配链** ⇒ 对上面这个缺陷
/// 完全无判别力（这正是上一轮改了却没修好的原因）。
///
/// 本文件的断言全部走生产入口：
/// - aylaVoiceMedia() = 页面实际会用的那个单例；
/// - 用例 B 真的把 AylaVoiceRoomHost 挂进 widget 树（不是手工 new 会话）；
/// - 触发用的是**媒体容器的公开回调**（media.events.onRemoteAudioLevels /
///   onLocalAudioLevel），即引擎真正调用的入口 —— 不是 store 的写入方法。
///
/// ## 变异验证（已实测）
/// 把 bindMediaEvents(mediaEvents ?? _media.events) 临时改回
/// bindMediaEvents(mediaEvents ?? AylaVoiceMediaEvents())：用例 A / B 全部变红
/// （media.events.onRemoteAudioLevels 为 null、store 电平恒 0）；改回即绿。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/audio/voice_media.dart';
import '../lib/pages/voice_support.dart' show AylaVoiceRoomHost, AylaVoiceSession;
import '../lib/state/auth_state.dart' show AuthUser, authNotifierProvider;
import '../lib/state/room_providers.dart'
    show voiceStateProvider, voiceWsProvider;
import '../lib/state/voice_state.dart';
import '../lib/theme/preview_theme.dart' show previewTheme;
import '../lib/widgets/voice/voice_member_row.dart' show AylaVoiceMemberRow;

const AuthUser _me = AuthUser(
  id: 'me',
  username: 'me',
  nickname: '我',
  avatar: '',
  signature: '',
  status: 'auto',
  online: true,
  displayStatus: '在线',
  dateJoined: '',
  isInVoice: false,
  voiceRoomId: null,
  isLive: false,
  liveRoomId: null,
  showContent: true,
  email: '',
);

Widget _host(Widget child) => MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(1440, 900)),
          child: previewTheme(child),
        ),
      ),
    );

/// 挂上生产宿主（AylaVoiceRoomHost）并跑到「会话已构造、可收媒体事件」的时刻。
///
/// **不依赖网络**：_bootstrap 里的 REST 全部失败也无妨 —— 会话对象在 initState
/// 里就已经 bindMediaEvents 完了，用例 B 验的正是那一步。
Future<ProviderContainer> _mountHost(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setUser(_me);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _host(const AylaVoiceRoomHost(channelId: 'v1')),
    ),
  );
  // 让 initState / 首帧 postFrame（开 voice WS）与 bootstrap 的微任务跑完。
  for (int i = 0; i < 8; i += 1) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return container;
}

/// 去掉 Dart 源码里的 `//` / `/* */` 注释，只留可执行代码（静态锁用）。
///
/// 为什么要剥：页头注释里本来就会写「电平（audioLevel）不在这里订阅」——
/// 那是**说明**，不是读取；不剥就会把注释误判成订阅（实测踩过一次）。
String _codeOnly(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  String? quote; // 非 null = 正处在字符串字面量里（不把 // 当注释）
  while (i < source.length) {
    final String c = source[i];
    final String? next = i + 1 < source.length ? source[i + 1] : null;
    if (quote != null) {
      out.write(c);
      if (c == r'\') {
        if (next != null) {
          out.write(next);
          i += 2;
          continue;
        }
      } else if (c == quote) {
        quote = null;
      }
      i += 1;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i += 1;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i += 1;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < source.length &&
          !(source[i] == '*' && source[i + 1] == '/')) {
        i += 1;
      }
      i = i + 2 <= source.length ? i + 2 : source.length;
      continue;
    }
    out.write(c);
    i += 1;
  }
  return out.toString();
}

void main() {
  setUp(() {
    // 每个用例都从「干净的单例」开始（否则上一用例的会话/容器残留会串味）。
    debugSetVoiceMedia(null);
  });
  tearDown(() {
    debugSetVoiceMedia(null);
  });

  test('A 单例的事件容器 = 会话层绑定的那一份（引擎真正调用的入口）', () {
    final AylaVoiceMedia media = aylaVoiceMedia();
    expect(media.events, same(aylaVoiceMedia().events),
        reason: 'events 必须是稳定的同一份容器，不能每次 new');

    final AylaVoiceState voice = AylaVoiceState();
    addTearDown(voice.dispose);
    voice.enterChannel('v1', <AylaVoiceMemberState>[
      const AylaVoiceMemberState(userId: 'u1'),
    ]);

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    // 生产装配的等价物：media: aylaVoiceMedia() 且**不传** mediaEvents
    // （voice_support.dart 的 _AylaVoiceRoomHostState.initState 就是这么建的）。
    final AylaVoiceSession session = AylaVoiceSession(
      voiceState: voice,
      voiceWs: container.read(voiceWsProvider),
      media: media,
      currentUserId: () => 'me',
      accessToken: () => 'token',
    );
    addTearDown(session.dispose);

    // ★★ 核心断言：单例自己的容器上必须挂着会话层的回调。
    // 旧缺陷下这里是 null —— 回调绑到了新建的 AylaVoiceMediaEvents() 上，
    // 而引擎只往这里打事件 ⇒ 条子恒 0。
    expect(media.events.onRemoteAudioLevels, isNotNull,
        reason: '★ 会话层必须绑到媒体单例自己的事件容器（onRemoteAudioLevels）；'
            '为 null = 绑到了孤儿对象，远端条子恒 0');
    expect(media.events.onLocalAudioLevel, isNotNull,
        reason: '★ 同上：onLocalAudioLevel 也必须是同一份容器');
    expect(media.events.onStateChange, isNotNull,
        reason: '★ 媒体连接态（connecting/connected/failed）也走同一份容器');

    // 触发 = 引擎 100ms tick 的调用面（不是 store 的写入方法）。
    media.events.onRemoteAudioLevels!(<String, double>{'u1': 0.7});
    expect(voice.memberOf('u1')?.audioLevel, 0.7,
        reason: '★ 引擎事件必须穿过装配链落到 store（否则成员行条子读不到）');
    media.events.onRemoteAudioLevels!(<String, double>{'u1': 0.15});
    expect(voice.memberOf('u1')?.audioLevel, 0.15,
        reason: '逐帧快照都要落地（条子随说话起伏）');
  });

  test('★C 页面 build 不得订阅电平；电平重绘的唯一入口是面板的 ListenableBuilder', () {
    final String src =
        File('lib/pages/voice_support.dart').readAsStringSync();
    final int start =
        src.indexOf('class _AylaVoiceRoomHostState extends ConsumerState<AylaVoiceRoomHost>');
    expect(start, greaterThan(0), reason: '找不到宿主 State 类');
    final int buildAt = src.indexOf('Widget build(BuildContext context) {', start);
    expect(buildAt, greaterThan(start), reason: '找不到宿主的 build');
    // 只取**代码**：注释里出现这些词是自解释，不算订阅（避免误报）。
    final String buildCode = _codeOnly(src.substring(buildAt));

    // ---- 判据 1：build 代码体内不得出现任何电平相关的读取 ----
    // 若将来有人把 audioLevel 读回 build（无论 `watch` 还是 `select`），
    // 10Hz 电平 notify 会重新唤醒整页 + AylaVoiceRoomBody ⇒ 收敛白做。
    expect(buildCode.contains('audioLevel'), isFalse,
        reason: '★ 页面 build 不得读 audioLevel —— 电平必须只由成员面板的 '
            'ListenableBuilder 消费（否则整页每秒重建 10 次）');
    expect(buildCode.contains('localAudioLevel'), isFalse,
        reason: '★ 页面 build 不得读 localAudioLevel（同上）');
    expect(buildCode.contains('_levelStamp'), isFalse,
        reason: '★ 电平折叠哈希已删除：它本身就是「每秒变 10 次的 stamp」，'
            'watch 它等价于 watch 整个 store');
    final String buildBody = buildCode;

    // ---- 判据 2：面板重绘入口必须是 ListenableBuilder(listenable: voice) ----
    expect(buildBody.contains('ListenableBuilder('), isTrue,
        reason: '★ 成员面板必须由 ListenableBuilder 承担电平重绘');
    expect(buildBody.contains('listenable: voice'), isTrue,
        reason: '★ ListenableBuilder 必须订阅 store 本体（voice），'
            '这样 voice.notify 只在面板子树内生效');

    // ---- 判据 3：本页仍必须保留它真正依赖的那几个窄订阅 ----
    // （收敛重建不等于砍掉订阅 —— 6185995 修的就是「build 里读却没订阅」。）
    for (final String needed in <String>[
      's.channelOf(widget.channelId)',
      's.memberOf(selfId) != null',
      's.media == AylaVoiceMediaConnection.failed',
      's.members.length',
    ]) {
      expect(buildBody.contains(needed), isTrue,
          reason: '★ 页面渲染依赖的字段必须仍有 select 订阅：$needed');
    }
  });

  test('★D token 续期实现在「登出 → 单例重建」后仍然有效', () {
    // 登出会 aylaVoiceMediaTeardown() 把单例置空；main 每进程只注入一次
    // ⇒ 新建的实例必须继承同一个续期实现，否则重新登录后中继又退回「恒返回 null」。
    debugSetVoiceMedia(null);
    int calls = 0;
    aylaVoiceMedia().setTokenRefresher(() async {
      calls += 1;
      return 'fresh-token';
    });
    aylaVoiceMediaTeardown(); // 模拟登出
    final AylaVoiceMedia rebuilt = aylaVoiceMedia();
    addTearDown(() {
      debugSetVoiceMedia(null);
    });
    expect(rebuilt, isNotNull);
    // 读到的是重建后的实例，且不需要再次注入就能拿到续期实现。
    expect(rebuilt.debugHasTokenRefresher, isTrue,
        reason: '★ 单例重建后必须继承模块级续期实现（否则登出再登录后中继续不上 token）');
    expect(calls, 0, reason: '前置：尚未触发续期');
  });

  testWidgets('B 生产宿主挂载后：媒体事件 → store → 成员行子树（含窄订阅重绘）',
      (WidgetTester tester) async {
    final ProviderContainer container = await _mountHost(tester);
    final AylaVoiceMedia media = aylaVoiceMedia();

    // 铺成员表（当前频道 = v1，含自己）—— 无网络时 members/ 拉不到，必须自铺。
    container.read(voiceStateProvider).enterChannel('v1', <AylaVoiceMemberState>[
      const AylaVoiceMemberState(userId: 'me'),
    ]);
    await tester.pump();

    expect(media.events.onRemoteAudioLevels, isNotNull,
        reason: '★ 经 widget 树装配（aylaVoiceMedia() 不传 events）也必须绑到单例');
    expect(media.events.onLocalAudioLevel, isNotNull,
        reason: '★ 同上：本地电平');

    // ---- 路径 1：远端快照 → store ----
    media.events.onRemoteAudioLevels!(<String, double>{'me': 0.42});
    expect(container.read(voiceStateProvider).memberOf('me')?.audioLevel, 0.42,
        reason: '远端快照必须落到成员表');

    // ---- 路径 2：本地电平 → store → **渲染出来的那一行** ----
    // 这一段同时锁住「收敛重建」没有被做坏：电平到达后，成员面板必须重绘并把
    // 新的 localAudioLevel 交给行（行内跳动条宽度就是这个值的函数）。
    media.events.onLocalAudioLevel!(0.8);
    await tester.pump();

    final Iterable<AylaVoiceMemberRow> rows =
        tester.widgetList<AylaVoiceMemberRow>(find.byType(AylaVoiceMemberRow));
    expect(rows, isNotEmpty, reason: '前置：成员面板必须渲染出至少一行');
    final AylaVoiceMemberRow selfRow =
        rows.firstWhere((AylaVoiceMemberRow r) => r.isSelf);
    expect(selfRow.self?.localAudioLevel, 0.8,
        reason: '★ 电平到达后成员行必须拿到新值 —— 若这里仍是 0，说明重绘链断了');

    // 条宽映射（web VoiceMemberRow.tsx:56–63）：电平变化 ⇒ 百分比变化。
    expect(AylaVoiceMemberRow.debugLevelPercent(0.8),
        greaterThan(AylaVoiceMemberRow.debugLevelPercent(0.0)),
        reason: '跳动条宽度是 levelPercent(level) 的函数');
  });
}
