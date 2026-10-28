/// 「静音态上报方向」契约测试（2026-10-29）。
///
/// 用户实报（截图）：成员行**麦克风图标是开、副行却写"已静音"**（对调）。
///
/// 根因：`voice.state` 的 `state` 字段语义是 **muted**（静音=true），
/// 而 `toggleMic` 里那个 `next` 是 **micEnabled**（开麦=true）。
/// 两者语义相反，广播时必须取反。两个客户端都曾直接传 `next`。
///
/// 本测试锁死这条**方向**约定，避免以后又被"看起来同名"骗过去。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('静音态上报方向', () {
    late String support;

    setUpAll(() {
      support = File('lib/pages/voice_support.dart').readAsStringSync();
    });

    test('toggleMic 广播时对 micEnabled 取反（传的是 muted 而非 micEnabled）', () {
      // 必须出现取反形式；直接传 next 就是那个 bug。
      expect(
        support.contains('_broadcastMicState(channelId, !next)'),
        isTrue,
        reason: '静音态上报必须取反：next=micEnabled，而 voice.state 的 state 是 muted',
      );
      expect(
        support.contains('_broadcastMicState(channelId, next)'),
        isFalse,
        reason: '直接传 next 会让"开麦"被广播成 muted（用户实报的图标/文案对调）',
      );
    });

    test('上报帧字段名是 voice.mute + muted（与服务端帧契约一致）', () {
      expect(support.contains("'type': 'voice.mute'"), isTrue);
      expect(support.contains("'muted': muted"), isTrue);
    });

    test('本机自行的副行同步也用取反后的语义（muted ⇔ !micEnabled）', () {
      // 不自同步的话，自己关麦后副行仍显示「在频道中」。
      expect(
        support.contains('AylaVoiceMemberEventState.muted') &&
            support.contains('AylaVoiceMemberEventState.unmuted'),
        isTrue,
      );
      // 三元分支里必须是 next ? unmuted : muted（开麦=非静音）
      expect(
        RegExp(r'next\s*\?\s*AylaVoiceMemberEventState\.unmuted\s*:\s*AylaVoiceMemberEventState\.muted')
            .hasMatch(support.replaceAll(RegExp(r'\s+'), ' ')),
        isTrue,
        reason: 'next 为 true（开麦）时必须对应 unmuted',
      );
    });
  });
}
