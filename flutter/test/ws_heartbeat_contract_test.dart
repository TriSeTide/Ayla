/// WS 心跳间隔回归锁 —— 锁死 2026-10-28 发现并已修复的缺陷：
///
/// ```
/// flutter/lib/core/ws/ws_manager.dart
///   const int kPingIntervalMs = 15000;   // ← 删除 ws_relay 中继时被误写（原值 25000）
///   ↓
///   kPresenceHeartbeat == 15s（web ws/presence.ts 是 25s）
///   ↓
///   成员进出 / 静音 / 头像在线光环等 presence 热更新异常
/// ```
///
/// ## 为什么必须锁在测试里
/// kPingIntervalMs 只决定「多久发一次 ping」，本身没有任何语义校验：
/// 写成 15000 依然能连上、依然能收帧，只是 presence 心跳节奏与 web 不同源了。
/// 这类「看起来正常工作」的常量漂移只能靠契约测试发现，不能靠联调。
///
/// ## 锁什么（各自能独立变红）
/// 1. kPingIntervalMs == 25000（附带注释说明与 web 同值）；
/// 2. **源码文本**里那一行就是 const int kPingIntervalMs = 25000;
///    —— 防止有人把常量改成间接表达式（如 3 * 5000）而不改注释；
/// 3. 派生常量 kPresenceHeartbeat == Duration(seconds: 25)；
/// 4. **真实装配**：WsManager 建出来的 presence 通道 heartbeatInterval 是 25s
///    （改常量但忘改装配 / 反之都能被抓到）；
/// 5. **跨仓库同值**：直接读 ../web/src/ws/presence.ts 的
///    HEARTBEAT_INTERVAL_MS = 25_000，两边必须相等 —— 这是本次缺陷的真正判据，
///    单看 Flutter 侧无法知道「正确值是多少」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 包名 ayla_flutter（pubspec.yaml）—— 用 package: 导入避免 avoid_relative_lib_imports。
import 'package:ayla_flutter/core/net/dio_client.dart' show AuthTokenStore;
import 'package:ayla_flutter/core/ws/ws_manager.dart';

/// 无令牌 store：connect() 随即 no-op，不会开真 socket（只读 heartbeatInterval）。
class _NoTokenStore implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

/// 从 TS 源码里抽出 `HEARTBEAT_INTERVAL_MS = <n>` 的数值（允许 25_000 数字分隔符）。
int? _tsHeartbeatMs(String source) {
  final RegExpMatch? m =
      RegExp(r'HEARTBEAT_INTERVAL_MS\s*=\s*([0-9_]+)').firstMatch(source);
  if (m == null) return null;
  return int.tryParse(m.group(1)!.replaceAll('_', ''));
}

void main() {
  group('kPingIntervalMs 契约（连 25000）', () {
    test('常量值必须等于 25000（与 web ws/presence.ts 的 25s 同值）', () {
      expect(
        kPingIntervalMs,
        25000,
        reason: '契约：kPingIntervalMs 与 web ws/presence.ts 的 '
            'HEARTBEAT_INTERVAL_MS = 25_000 必须同值。'
            '2026-10-28 删除 ws_relay 中继时被误写成 15000，'
            '导致 presence 心跳节奏与 web 不同源。',
      );
    });

    test('源码文本里那一行就是 const int kPingIntervalMs = 25000;', () {
      final String src = File('lib/core/ws/ws_manager.dart').readAsStringSync();
      expect(
        src.contains('const int kPingIntervalMs = 25000;'),
        isTrue,
        reason: '常量声明行必须保持字面量 25000：改成间接表达式会让注释里的'
            '「与 web 同值」失去可核对性，也会让本回归锁失效。',
      );
      expect(
        src.contains('const int kPingIntervalMs = 15000;'),
        isFalse,
        reason: '15000 是本次缺陷的误值，不得回归。',
      );
    });

    test('派生常量 kPresenceHeartbeat == 25s', () {
      expect(kPresenceHeartbeat, const Duration(milliseconds: 25000));
      expect(kPresenceHeartbeat.inSeconds, 25);
    });

    test('WsManager 装配：presence 25s，chat/voice/live 30s', () {
      final WsManager manager = WsManager(tokens: _NoTokenStore());
      addTearDown(manager.dispose);

      expect(
        manager.presence.heartbeatInterval,
        const Duration(milliseconds: 25000),
        reason: 'presence 通道装配必须消费 kPresenceHeartbeat（web presence.ts 25s）',
      );
      // web 侧另外三条通道都是 30s（ws/chat.ts / ws/voice.ts / ws/live.ts
      // 均为 HEARTBEAT_INTERVAL_MS = 30_000）—— 一起锁住，避免「统一改 25s」的误修。
      expect(manager.chat.heartbeatInterval, kChatHeartbeat);
      expect(manager.voice.heartbeatInterval, kChatHeartbeat);
      expect(manager.live.heartbeatInterval, kChatHeartbeat);
      expect(kChatHeartbeat, const Duration(milliseconds: 30000));
    });
  });

  group('跨仓库同值（Flutter <-> web）', () {
    test('web ws/presence.ts 的 HEARTBEAT_INTERVAL_MS 与 kPingIntervalMs 相等', () {
      final File webPresence = File('../web/src/ws/presence.ts');
      expect(
        webPresence.existsSync(),
        isTrue,
        reason: '跨仓库同值检查需要 ../web/src/ws/presence.ts'
            '（flutter test 的 cwd 是 Ayla/flutter）',
      );
      final int? webMs = _tsHeartbeatMs(webPresence.readAsStringSync());
      expect(webMs, isNotNull,
          reason: 'web presence.ts 必须仍定义 HEARTBEAT_INTERVAL_MS 常量');
      expect(
        webMs,
        kPingIntervalMs,
        reason: '两侧心跳间隔必须同值：web=$webMs ms / flutter=$kPingIntervalMs ms。'
            '不同值 ⇒ presence 心跳节奏与服务端/另一端不一致。',
      );
    });

    test('web ws/voice.ts 与 ws/chat.ts 的间隔 == kChatHeartbeat', () {
      for (final String path in <String>[
        '../web/src/ws/voice.ts',
        '../web/src/ws/chat.ts',
      ]) {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '缺少 $path');
        expect(
          _tsHeartbeatMs(f.readAsStringSync()),
          kChatHeartbeat.inMilliseconds,
          reason: '$path 的 HEARTBEAT_INTERVAL_MS 必须等于 Flutter 的 kChatHeartbeat',
        );
      }
    });
  });
}
