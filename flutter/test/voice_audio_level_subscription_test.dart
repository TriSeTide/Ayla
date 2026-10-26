/// 语音房「谁在说话」条：UI 必须**订阅**电平变化（2026-10-26）。
///
/// 用户实报「听得见声音，但音量条完全不跳动」，且上一轮补了衰减仍无效果。
/// 真实根因（本轮定位）：语音房页面构造成员行时用了
/// `ref.read(voiceStateProvider).memberOf(userId)` —— **处于 build 调用链却是 read**。
/// `ref.read` 不建立订阅 ⇒ `setRemoteAudioLevels`（每 100ms notify）到达后
/// **页面根本不重建** ⇒ 成员行的 `audioLevel` 永远停在初始 0 ⇒ 条子完全不动。
///
/// 音频链路本身是好的（所以能听见声音）；坏的只是 UI 订阅。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/state/voice_state.dart';

void main() {
  test('★ setRemoteAudioLevels 必须 notify（否则页面不会重建）', () {
    final AylaVoiceState voice = AylaVoiceState();
    addTearDown(voice.dispose);
    voice.enterChannel('c1', <AylaVoiceMemberState>[
      const AylaVoiceMemberState(userId: 'u1'),
    ]);

    int notified = 0;
    voice.addListener(() => notified += 1);

    voice.setRemoteAudioLevels(<String, double>{'u1': 0.7});
    expect(notified, greaterThan(0),
        reason: '★ 电平更新必须触发通知，否则 UI 不重建（条子不动）');
    expect(voice.memberOf('u1')?.audioLevel, 0.7);
  });

  test('★ 电平变化逐帧可读（不是只写一次）', () {
    final AylaVoiceState voice = AylaVoiceState();
    addTearDown(voice.dispose);
    voice.enterChannel('c1', <AylaVoiceMemberState>[
      const AylaVoiceMemberState(userId: 'u1'),
    ]);

    for (final double v in <double>[0.2, 0.5, 0.9, 0.1]) {
      voice.setRemoteAudioLevels(<String, double>{'u1': v});
      expect(voice.memberOf('u1')?.audioLevel, v,
          reason: '每次快照都应反映到 store（UI 据此画条）');
    }
  });

  test('★ toMember() 透传 audioLevel（面板行拿到的就是它）', () {
    const AylaVoiceMemberState s = AylaVoiceMemberState(
      userId: 'u1',
      audioLevel: 0.42,
    );
    expect(s.toMember().audioLevel, 0.42);
  });
}
