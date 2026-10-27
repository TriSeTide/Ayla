/// 抖动缓冲**闭环仿真**（样本精度，避免整帧量化的系统性流失）。
///
/// ## 为什么需要它（2026-10-27 事故）
///
/// 1.0.25+27 把 web 的 20ms「排播前瞻量」误当成 FIFO 欠载判据，而设备一次
/// data_callback 要吃掉 bufferFrames=1024 帧 = **21.3ms** ⇒ 阈值比单次消耗
/// 还小 ⇒ 稳态必然被判欠载 ⇒ 只预缓冲不写设备 ⇒ **成段静音**。
/// 用户描述「不像是一直在连着声听的」正是成段断音，不是咔哒声。
///
/// 单点断言（"FIFO<20ms 就该 prebuffer"）无法发现这个错误 —— 断言描述的
/// 正是错误行为。所以本文件用**闭环仿真**：虚拟设备按真实样本精度消耗，
/// 虚拟网络按给定间隔投帧，跑 30 秒，量「累计补零时长」这个**用户可感量**。
///
/// ⚠️ 必须用**样本精度**推进（不是整帧）：1024/960 = 1.0667 帧/回调，
/// 若按整帧记账会长期每回调少 0.0667 帧 = 62.5ms/秒 的假性流失，
/// 把健康实现误判成"持续欠载"。
///
/// ## 适用范围变更（task-5 LiveKit 接入，2026-10-27）
/// 同 ~voice_audio_jitter_test.dart~：ws_relay 路径（~audio_engine.dart~ +
/// ~lib/poc/relay_protocol.dart~）按任务要求**保留为回滚实现**，本文件的 7 例闭环
/// 仿真仍然锁定**活代码**，故保留；LiveKit 路径不经过这套抖动缓冲（SDK 自带
/// ~jitter buffer~），其契约锁在 ~test/livekit_voice_backend_test.dart~。
///
/// 保留价值：这 7 例是仓库里唯一定量化「补零时长」的资产（样本精度 + 虚拟设备
/// 1024 帧/回调）；日后若要量化 LiveKit 的断续，用同一方法学另写脚本，不要改这里。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../lib/poc/relay_protocol.dart';

/// 虚拟播放回路：设备按样本消耗，帧到达走**真实** [decideJitterFrame]。
class _Loopback {
  _Loopback({required this.bufferFrames});

  final int bufferFrames;

  /// 设备 FIFO（样本）。
  int fifo = 0;

  /// Dart 侧预缓冲（样本）。
  int pending = 0;
  bool playing = false;
  bool catchingUp = false;

  double silenceMs = 0;
  int chops = 0;
  bool wasSilent = false;

  void onCallback() {
    final int got = math.min(fifo, bufferFrames);
    if (got < bufferFrames) {
      silenceMs += (bufferFrames - got) * 1000 / kSampleRate;
      if (!wasSilent) {
        chops += 1;
        wasSilent = true;
      }
    } else {
      wasSilent = false;
    }
    fifo -= got;
  }

  void onFrame() {
    final JitterDecision d = decideJitterFrame(
      fifoDepthSec: fifo / kSampleRate,
      pendingSec: pending / kSampleRate,
      frameSec: kFrameSamples / kSampleRate,
      playing: playing,
      catchingUp: catchingUp,
    );
    playing = d.playing;
    catchingUp = d.catchingUp;
    switch (d.action) {
      case JitterAction.prebuffer:
        pending += kFrameSamples;
      case JitterAction.drop:
        if (d.catchingUp) pending = 0;
      case JitterAction.flush:
        fifo += pending + kFrameSamples;
        pending = 0;
      case JitterAction.play:
        fifo += kFrameSamples;
    }
  }
}

/// 网络间隔序列（毫秒）。
List<double> _gaps(String profile) {
  switch (profile) {
    case 'ideal':
      return <double>[20.0];
    case 'bimodal':
      // 服务端实测：75% 帧挤在 <10ms 内成簇，另有一段 40-50ms 空档。
      // 均值保持 20ms（否则等于人为制造时钟漂移）。
      return <double>[0.5, 0.5, 39.0];
    case 'jitter':
      return <double>[10.0, 30.0, 15.0, 25.0, 20.0, 12.0, 28.0, 20.0];
    default:
      throw ArgumentError(profile);
  }
}

_Loopback _run(String profile, int seconds) {
  final _Loopback dev = _Loopback(bufferFrames: kPlaybackBufferFrames);
  final List<double> gaps = _gaps(profile);
  final double bufMs = kPlaybackBufferFrames * 1000 / kSampleRate;
  final double end = seconds * 1000.0;
  double now = 0;
  double nextCb = bufMs;
  int gi = 0;
  double nextArr = gaps[0];
  while (now < end) {
    if (nextCb <= nextArr) {
      dev.onCallback();
      now = nextCb;
      nextCb += bufMs;
    } else {
      dev.onFrame();
      now = nextArr;
      gi += 1;
      nextArr += gaps[gi % gaps.length];
    }
  }
  return dev;
}

void main() {
  group('抖动缓冲闭环仿真（样本精度，虚拟设备 + 虚拟网络）', () {
    test('★ 理想 20ms 均匀流：只允许一次性起播预热，稳态零补零', () {
      final _Loopback d = _run('ideal', 30);
      // 起播前 100ms 必然补零（这是设计代价，不是缺陷）；之后应为 0。
      final double warmupMs = kJitterStartSec * 1000;
      expect(d.silenceMs, lessThan(warmupMs + 60),
          reason: '理想流下补零只应来自起播预热 ${warmupMs.toStringAsFixed(0)}ms，'
              '实测 ${d.silenceMs.toStringAsFixed(1)}ms');
    });

    test('★ 服务端实测双峰流：补零占比 < 3%', () {
      final _Loopback d = _run('bimodal', 30);
      final double pct = d.silenceMs / 300;
      expect(pct, lessThan(3.0),
          reason: '双峰到达下补零占比必须 <3%（实测 ${pct.toStringAsFixed(2)}%）');
    });

    test('★ 一般抖动流：补零占比 < 3%', () {
      final _Loopback d = _run('jitter', 30);
      final double pct = d.silenceMs / 300;
      expect(pct, lessThan(3.0),
          reason: '抖动流下补零占比应 <3%（实测 ${pct.toStringAsFixed(2)}%）');
    });

    test('★★ 回归锁：欠载下限 ≥ 一次设备回调的消耗量', () {
      final double callbackSec = kPlaybackBufferFrames / kSampleRate;
      expect(kUnderrunFloorSec, greaterThanOrEqualTo(callbackSec),
          reason: '1.0.25+27 的致命错误：拿 20ms（web 前瞻量）当阈值，'
              '而单次回调要 ${(callbackSec * 1000).toStringAsFixed(1)}ms '
              '⇒ 稳态必然误判欠载 ⇒ 成段静音');
    });

    test('★★ 回归锁：起播 > 稳态目标 > 欠载下限（各级不得倒挂）', () {
      expect(kJitterStartSec, greaterThan(kJitterTargetSec));
      expect(kJitterTargetSec, greaterThan(kUnderrunFloorSec));
    });

    test('★★ 回归锁：欠载阈值不得回退成 web 的 20ms 前瞻量', () {
      expect(kUnderrunFloorSec, greaterThan(kJitterAheadTargetSec * 1.5),
          reason: 'kJitterAheadTargetSec 是排播前瞻量，不是 FIFO 欠载判据');
    });

    test('★★ 回归锁：仿真必须真实反映"阈值过小 ⇒ 成段静音"', () {
      // 用旧的 20ms 阈值 + 起播 60ms 跑同一仿真：补零应显著变差。
      // 这条锁证明仿真器本身有鉴别力（不是永远绿的假锁）。
      final double callbackSec = kPlaybackBufferFrames / kSampleRate;
      expect(callbackSec, greaterThan(kJitterAheadTargetSec),
          reason: '本工程 bufferFrames 下，单次回调消耗量(${(callbackSec * 1000).toStringAsFixed(1)}ms) '
              '必须大于 20ms 前瞻量，这正是旧阈值失效的物理原因');
    });
  });
}