/// 语音「断断续续」回归锁（2026-10-27，task-2）。
///
/// ## 被锁的行为
/// web 侧 `Ayla/web/src/livekit/wsRelayRoom.ts:311–315` 每帧按 slot 维护
/// playHead、由 **WebAudio 调度器**自带抖动缓冲（落后 20ms 顺延 / 积压 400ms
/// 重置追赶）。Flutter 侧没有调度器，旧实现「解码 → 立刻 write 进 miniaudio
/// FIFO」= 缓冲深度≈0，一次 TCP/frp 抖动或 Dart GC 停顿就把 FIFO 抽干
/// ⇒ `miniaudio_bridge.c:162` 的 `memset(output + samples_to_read, 0, …)`
/// ⇒ 用户听到的「断断续续」。
///
/// 本轮引入 [decideJitterFrame]（纯函数）+ 水位常量，并把播放/采集/编解码
/// 全部改成预分配路径。本文件两件事：
/// 1. **水位纯函数**逐档覆盖（起播 / 稳态 / 欠载 / 积压 / 追赶 / 恢复）；
/// 2. **接线锁**：常量必须真被 audio_engine 引用（死常量就是本 bug 的成因），
///    以及 CPU 热路径上不许再出现每帧 malloc / 每帧 O(n) 搬运。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/poc/relay_protocol.dart';

/// 语音帧长（秒）。20ms 帧。
const double _frameSec = kFrameMs / 1000.0;

/// 读源码（接线锁用）。
String _src(String relative) => File(relative).readAsStringSync();

void main() {
  // 起播水位必须真的比一帧厚；否则这个「抖动缓冲」不存在。
  const double start = kJitterStartSec;
  const double target = kJitterTargetSec;
  const double underrun = kJitterAheadTargetSec;
  const double reset = kJitterResetAtSec;

  group('水位常量自检（web wsRelayRoom.ts:313 的 0.02 / 0.4 为锚）', () {
    test('欠载阈值 = web 的一帧 lead（20ms）', () {
      expect(kJitterAheadTargetSec, 0.02,
          reason: 'web `at < now + 0.02` 的 0.02 是权威值，不许漂移');
    });

    test('积压阈值 = web 的 400ms', () {
      expect(kJitterResetAtSec, 0.4,
          reason: 'web `at > now + 0.4` 的 0.4 是权威值，不许漂移');
    });

    test('★ 起播水位必须 ≥ 3 帧（60ms）——否则等于没有抖动缓冲', () {
      expect(start, greaterThanOrEqualTo(3 * _frameSec),
          reason: '2 帧连丢就会欠载，frp 抖动下依然断续');
      expect(start, lessThanOrEqualTo(0.1),
          reason: '起播垫超过 100ms 会明显拖慢对话节奏');
    });

    test('★ 稳态目标必须夹在欠载阈值与积压阈值之间，且留有余量', () {
      expect(target, greaterThan(underrun),
          reason: '与欠载阈值同值会「抖—停—抖」循环');
      expect(target, lessThan(reset));
      expect(start, greaterThan(target),
          reason: '起播水位必须高于稳态目标，否则 flush 完立刻又欠载');
    });

    test('★ 积压阈值必须 < 播放器 FIFO 容量（否则防积压逻辑是死代码）', () {
      // 48000 * 0.4 = 19200 帧；FIFO 容量若只有默认 8192 帧，永远命不中。
      final int framesForReset = (kSampleRate * 0.4).round();
      expect(kPlaybackFifoCapacityFrames, greaterThan(framesForReset),
          reason: 'FIFO 比高水位还浅 ⇒ 高水位分支永远命中不了');
    });
  });

  group('decideJitterFrame：起播（攒水位）', () {
    JitterDecision d(double fifo, double pending, {bool playing = false}) =>
        decideJitterFrame(
          fifoDepthSec: fifo,
          pendingSec: pending,
          frameSec: _frameSec,
          playing: playing,
          catchingUp: false,
        );

    test('全新 slot、FIFO 空、无预缓冲 ⇒ 本帧进预缓冲，不写设备', () {
      final JitterDecision r = d(0, 0);
      expect(r.action, JitterAction.prebuffer);
      expect(r.playing, isFalse);
      expect(r.catchingUp, isFalse);
    });

    test('第 2 帧仍不够 60ms ⇒ 继续预缓冲', () {
      // 已有 1 帧在预缓冲；再加本帧 = 40ms < 60ms
      expect(d(0, _frameSec).action, JitterAction.prebuffer);
    });

    test('★ 攒满 60ms（3 帧）⇒ 一次性 flush 起播', () {
      final JitterDecision r = d(0, 2 * _frameSec);
      expect(r.action, JitterAction.flush);
      expect(r.playing, isTrue);
      expect(r.catchingUp, isFalse);
    });

    test('设备 FIFO 已有存量也计入水位（不是只看预缓冲）', () {
      // FIFO 40ms + 本帧 20ms = 60ms ⇒ 直接起播
      expect(d(2 * _frameSec, 0).action, JitterAction.flush);
    });

    test('★ 起播后不会因为「只有一帧」就立刻停（欠载阈值 20ms）', () {
      final JitterDecision r = d(_frameSec, 0, playing: true);
      expect(r.action, JitterAction.play,
          reason: '刚好 20ms 提前量应当继续播，否则每帧都停');
    });
  });

  group('decideJitterFrame：稳态', () {
    test('FIFO 深 100ms ⇒ 直接写设备（play）', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.1,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.play);
      expect(r.playing, isTrue);
    });

    test('FIFO 深 399ms（差一点到高水位）⇒ 仍然 play，不误杀', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.399,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.play);
    });
  });

  group('decideJitterFrame：欠载（帧到了但缓冲被抽干）', () {
    test('★ FIFO 浅于一帧 lead ⇒ 退回预缓冲，绝不写设备', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.005, // 比 20ms 还薄
        pendingSec: 0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.prebuffer,
          reason: '不写设备才不会真的补零（data_callback memset）');
      expect(r.playing, isFalse);
    });

    test('★ 欠载后要重新攒到 60ms 才复播（不是攒一帧就播）', () {
      // 欠载后第 1 帧
      JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: false,
        catchingUp: false,
      );
      expect(r.action, JitterAction.prebuffer);
      // 第 2 帧（已攒 1 帧）
      r = decideJitterFrame(
        fifoDepthSec: 0,
        pendingSec: _frameSec,
        frameSec: _frameSec,
        playing: false,
        catchingUp: false,
      );
      expect(r.action, JitterAction.prebuffer);
      // 第 3 帧（已攒 2 帧）⇒ 60ms，复播
      r = decideJitterFrame(
        fifoDepthSec: 0,
        pendingSec: 2 * _frameSec,
        frameSec: _frameSec,
        playing: false,
        catchingUp: false,
      );
      expect(r.action, JitterAction.flush);
      expect(r.playing, isTrue);
    });
  });

  group('decideJitterFrame：积压 / 追赶', () {
    test('★ FIFO 达到 400ms ⇒ 丢帧并进入追赶', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.4,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.drop);
      expect(r.catchingUp, isTrue,
          reason: 'web 这里是 playHead 前跳；Flutter 无 flush 接口 ⇒ 靠丢帧追赶');
      expect(r.playing, isFalse);
    });

    test('★ 追赶期间持续丢帧，直到 FIFO 下探到稳态目标', () {
      for (final double depth in <double>[0.35, 0.2, 0.1, 0.05]) {
        final JitterDecision r = decideJitterFrame(
          fifoDepthSec: depth,
          pendingSec: 0,
          frameSec: _frameSec,
          playing: false,
          catchingUp: true,
        );
        expect(r.action, JitterAction.drop,
            reason: '深度 $depth s 仍在追赶');
        expect(r.catchingUp, isTrue);
      }
    });

    test('★ 追赶到稳态目标以下 ⇒ 退出追赶（交回预缓冲重新起播）', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: kJitterTargetSec / 2,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: false,
        catchingUp: true,
      );
      expect(r.action, JitterAction.drop,
          reason: '本帧仍丢弃（不在深积压上叠写），但状态要交回');
      expect(r.catchingUp, isFalse);
      expect(r.playing, isFalse);
    });

    test('★ 追赶退出后必须重新攒水位，不能直接 play', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: false,
        catchingUp: false,
      );
      expect(r.action, JitterAction.prebuffer);
    });
  });

  group('decideJitterFrame：不变量（任何输入都不许崩 / 不许自相矛盾）', () {
    test('★ 网格扫描：playing 与 catchingUp 永不并存；flush 必然 playing', () {
      for (final double fifo in <double>[
        0,
        0.01,
        0.02,
        0.05,
        0.1,
        0.3,
        0.4,
        1.0,
      ]) {
        for (final double pending in <double>[0, 0.02, 0.04, 0.5]) {
          for (final bool playing in <bool>[true, false]) {
            for (final bool catching in <bool>[true, false]) {
              final JitterDecision r = decideJitterFrame(
                fifoDepthSec: fifo,
                pendingSec: pending,
                frameSec: _frameSec,
                playing: playing,
                catchingUp: catching,
              );
              expect(r.playing && r.catchingUp, isFalse,
                  reason: '状态自相矛盾: $r');
              if (r.action == JitterAction.flush) {
                expect(r.playing, isTrue, reason: 'flush 之后必须处于播放态');
              }
              expect(r.fifoDepthSec, fifo, reason: '必须原样回传输入深度供诊断');
            }
          }
        }
      }
    });

    test('★ 大 pending 不会绕过积压判定（积压优先于 pending）', () {
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.5, // 已超积压阈值
        pendingSec: 1.0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.drop);
      expect(r.catchingUp, isTrue);
    });
  });

  group('接线锁：常量必须真被生产代码引用（旧实现全是死常量）', () {
    test('★ audio_engine.dart 必须引用水位常量并走纯函数决策', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      expect(engine, contains('decideJitterFrame('),
          reason: '播放路径必须真的走纯函数决策');
      expect(engine, contains('kJitterStartSec'),
          reason: '起播水位必须在文件头契约里登记');
      expect(engine, contains('kJitterTargetSec'),
          reason: '追赶目标是决策语义的一部分');
      expect(engine, contains('kJitterResetAtSec'));
    });

    test('★ 常量只允许定义一次（不许散落副本）', () {
      final List<File> libs = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      for (final String name in <String>[
        'kJitterStartSec',
        'kJitterTargetSec',
        'kJitterAheadTargetSec',
        'kJitterResetAtSec',
        'kPlaybackBufferFrames',
        'kPlaybackFifoCapacityFrames',
      ]) {
        int defs = 0;
        for (final File f in libs) {
          final String body = f.readAsStringSync();
          if (body.contains('const double $name =') ||
              body.contains('const int $name =')) {
            defs += 1;
          }
        }
        expect(defs, 1, reason: '$name 只允许有一处定义');
      }
    });

    test('★ 播放器必须显式传 bufferFrames 与 fifoCapacityFrames（不许吃默认 512/8192）',
        () {
      final String engine = _src('lib/audio/audio_engine.dart');
      final int at = engine.indexOf('MiniaudioPlayer(');
      expect(at, greaterThan(0));
      final String ctor = engine.substring(at, engine.indexOf(');', at));
      expect(ctor, contains('bufferFrames: kPlaybackBufferFrames'));
      expect(ctor, contains('fifoCapacityFrames: kPlaybackFifoCapacityFrames'));
      expect(ctor, contains('sampleRate: kSampleRate'));
      expect(ctor, contains('channels: 1'));
      expect(ctor, isNot(contains('bufferFrames: 512')));
    });

    test('★ 设备回调周期必须 ≥ 一帧（512=10.7ms 比语音帧还短 ⇒ 回调过密）', () {
      expect(kPlaybackBufferFrames, greaterThanOrEqualTo(kFrameSamples),
          reason: '1024 帧 = 21.3ms ≥ 20ms 语音帧');
      expect(kPlaybackBufferFrames, lessThanOrEqualTo(2048),
          reason: '再大设备级延迟就明显了（抖动缓冲已垫 60ms）');
    });
  });

  group('接线锁：CPU 热路径不许每帧动态分配 / O(n) 搬运', () {
    test('★ 必须用 BufferedOpusEncoder / BufferedOpusDecoder（预分配）', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      // ① 构造点
      expect(engine, contains('BufferedOpusEncoder('));
      expect(engine, contains('BufferedOpusDecoder('));
      // ② 字段类型（光有构造点不够：字段若还是 Simple*，赋值处就会退回旧类型）
      expect(engine, contains('BufferedOpusEncoder? _encoder;'),
          reason: '字段类型必须一并是 Buffered 版');
      expect(engine, contains('BufferedOpusDecoder? _decoder;'),
          reason: '字段类型必须一并是 Buffered 版');
      // ③ 全库任何 Simple* 引用都不许留（Simple* 每帧 malloc 输入 + malloc 输出，
      //    opus_dart_encoder.dart:107–122 ⇒ 正是 GC 停顿来源）
      expect(engine, isNot(contains('SimpleOpus')),
          reason: 'SimpleOpusEncoder/Decoder 每帧 malloc，是 GC 停顿的来源');
    });

    test('★ 抖动决策必须真的驱动写入（不许手工构造 JitterDecision 绕开纯函数）', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      // 决策只能来自纯函数；手工 new JitterDecision 等于把水位逻辑废掉。
      expect(engine, isNot(contains('JitterDecision(')),
          reason: '禁止手工构造决策：必须由 decideJitterFrame 给出');
      // 四个动作必须都被真的处理（少一个分支 = 某类水位被静默忽略）
      expect(engine, contains('switch (d.action)'));
      for (final String action in <String>[
        'JitterAction.prebuffer',
        'JitterAction.flush',
        'JitterAction.play',
        'JitterAction.drop',
      ]) {
        expect(engine, contains(action), reason: '必须真的处理 $action');
      }
      // 写设备只能发生在这条链路上（_writeNative 是唯一真正 write 的点）
      expect(engine, contains('_writeNative(p, ptr,'),
          reason: '所有写设备路径必须收口到 _writeNative');
      expect(engine, contains('p.write(ptr + written'),
          reason: 'write 只允许出现在 _writeNative 里');
      // 决策必须**逐动作分派**：直接 if (playing) 而不看 action 就等于废掉水位。
      expect(engine, contains('case JitterAction.prebuffer:'));
      expect(engine, contains('case JitterAction.flush:'));
      expect(engine, contains('case JitterAction.play:'));
      expect(engine, contains('case JitterAction.drop:'));
    });

    test('★ inputBufferIndex 必须按**字节**赋值（库契约，写错会静默编错帧）', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      // 库契约：opus_dart_encoder.dart:318–329 —— inputBufferIndex 是**字节数**，
      // 内部按 `~/ (channels * bytesPerInt16Sample)` 反推样本数。
      // 写成 Int16List.length（样本数）会只编出一半音频，且不报错。
      expect(engine, contains('samples.lengthInBytes'),
          reason: '必须从 Int16List 取字节长度');
      final int at = engine.indexOf('enc.inputBufferIndex =');
      expect(at, greaterThan(0), reason: '编码必须显式设置 inputBufferIndex');
      final String line = engine.substring(at, engine.indexOf(';', at));
      expect(line, contains('frameBytes'),
          reason: '必须是字节变量，不能是样本数');
      expect(line, isNot(contains('samples.length')),
          reason: 'samples.length 是样本数（960），不是字节数（1920）');
    });

    test('★ 采集侧必须用环形缓冲，不许再有 addAll + removeRange 的双拷贝', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      // 旧实现的采样缓冲字段（`_captureBuf`）必须彻底消失 —— 连注释里都不留，
      // 否则后来者会照着旧形态改回去。
      expect(engine, isNot(contains('_captureBuf')),
          reason: '每 20ms 整缓冲 addAll + removeRange 是 O(n) 双拷贝');
      expect(engine, contains('_captureRing'),
          reason: '必须是固定容量的环形缓冲');
      expect(engine, contains('kCaptureRingBytes'));
      // 环形缓冲必须按「写指针 / 读指针 / 已存字节数」三件套实现
      expect(engine, contains('_captureWrite'));
      expect(engine, contains('_captureRead'));
      expect(engine, contains('_captureCount'));
    });

    test('★ 下行解包不许再两次拷贝（sublist + fromList）', () {
      final String client = _src('lib/audio/relay_client.dart');
      expect(client, isNot(contains('bytes.sublist')),
          reason: 'sub-区间切片会先分配一份；必须用 sublistView 零拷贝视图');
      expect(client, contains('Uint8List.sublistView'),
          reason: '必须用零拷贝视图 + 一次 fromList');
    });

    test('★ 下行 binary 帧不应再被无谓包一层 Uint8List.fromList', () {
      final String client = _src('lib/audio/relay_client.dart');
      // 上游 adapter_web_socket_channel.dart:86–87 已经是 Uint8List
      expect(client, contains('data is Uint8List'),
          reason: 'web_socket_channel 3.x 的二进制帧本来就是 Uint8List');
    });
  });

  group('语义锁：本轮只改缓冲策略，不许改音频语义', () {
    test('★ 仍 48k mono / Application.voip / 20ms', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      expect(engine, contains('application: Application.voip'));
      expect(engine, contains('sampleRate: kSampleRate'));
      expect(engine, contains('channels: 1'));
      expect(kSampleRate, 48000);
      expect(kFrameMs, 20);
      expect(kFrameSamples, 960);
      expect(kFrameBytes, 1920);
    });

    test('★ 仍只在 speaking 时发帧（静音不发，带宽与 web 一致）', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      expect(engine, contains('if (!nowSpeaking) return;'));
    });

    test('★ decode 输入仍是「整包字节」（BufferedOpusDecoder 契约）', () {
      final String engine = _src('lib/audio/audio_engine.dart');
      expect(engine, contains('dec.inputBufferIndex = take;'));
    });
  });

  group('本地冒烟：纯函数驱动整条播放链路（不启音频设备）', () {
    /// 事件驱动仿真：帧按 20ms 节奏**产生**，网络抖动只推迟到达时间
    ///（TCP 保序，所以后面的帧不得早于前面的帧到达）；设备按
    /// `kPlaybackBufferFrames` 帧 / 回调匀速**取走**。
    ///
    /// 判据只用**客观量**：设备回调取走的样本数 < 需求 ⇒ 剩余部分会被
    /// `miniaudio_bridge.c:162–164` 的 memset 补零 —— 那就是用户耳朵里的
    /// 「断」。返回「整块取空(dry) / 部分取空(partial)」的次数。
    Map<String, int> simulate({
      required int deviceFrames,
      required int fifoCapacityFrames,
      bool useJitter = true,
      int stallEvery = 0,
      double stallSec = 0,
      double seconds = 30,
      double warmupSec = 2,
    }) {
      // 到达时刻（TCP 保序：累积取 max）
      final List<double> arrivals = <double>[];
      double last = -1;
      final int nFrames = (seconds / _frameSec).round();
      for (int i = 0; i < nFrames; i++) {
        double t = (i + 1) * _frameSec;
        if (stallEvery > 0 && i % stallEvery == stallEvery - 1) t += stallSec;
        if (t < last) t = last;
        last = t;
        arrivals.add(t);
      }

      final double devPeriod = deviceFrames / kSampleRate;
      final int nDev = (seconds / devPeriod).floor();
      int ai = 0;
      double fifo = 0;
      double pending = 0;
      bool playing = false;
      bool catching = false;
      int dry = 0;
      int partial = 0;
      int drops = 0;

      double freeSpace() {
        final double free = fifoCapacityFrames - fifo;
        return free < 0 ? 0 : free;
      }

      void write(double samples) {
        final double free = freeSpace();
        fifo += samples < free ? samples : free;
      }

      for (int k = 1; k <= nDev; k++) {
        final double devT = k * devPeriod;
        // 该回调之前到达的帧全部入账
        while (ai < arrivals.length && arrivals[ai] <= devT) {
          if (!useJitter) {
            // 旧实现：解码即写，无任何水位判断
            write(kFrameSamples.toDouble());
          } else {
            final JitterDecision d = decideJitterFrame(
              fifoDepthSec: fifo / kSampleRate,
              pendingSec: pending / kSampleRate,
              frameSec: _frameSec,
              playing: playing,
              catchingUp: catching,
            );
            playing = d.playing;
            catching = d.catchingUp;
            switch (d.action) {
              case JitterAction.prebuffer:
                pending += kFrameSamples;
              case JitterAction.flush:
                write(pending + kFrameSamples);
                pending = 0;
              case JitterAction.play:
                write(kFrameSamples.toDouble());
              case JitterAction.drop:
                drops++;
                if (catching) pending = 0;
            }
          }
          ai++;
        }
        final int take = fifo >= deviceFrames ? deviceFrames : fifo.floor();
        if (devT > warmupSec) {
          if (take == 0) {
            dry++;
          } else if (take < deviceFrames) {
            partial++;
          }
        }
        fifo -= take;
      }
      return <String, int>{
        'dry': dry,
        'partial': partial,
        'drops': drops,
      };
    }

    // 旧实现的真实参数：设备 512 帧（10.7ms）/ FIFO 8192 帧（171ms）/ 无水位判断。
    const int oldDeviceFrames = 512;
    const int oldFifoFrames = 8192;

    test('★ 干净链路（无抖动）：新旧实现都不补零', () {
      final Map<String, int> oldImpl = simulate(
        deviceFrames: oldDeviceFrames,
        fifoCapacityFrames: oldFifoFrames,
        useJitter: false,
      );
      final Map<String, int> newImpl = simulate(
        deviceFrames: kPlaybackBufferFrames,
        fifoCapacityFrames: kPlaybackFifoCapacityFrames,
      );
      expect(oldImpl['dry']! + oldImpl['partial']!, 0);
      expect(newImpl['dry']! + newImpl['partial']!, 0);
    });

    test('★ 单次 40ms / 60ms 卡顿：旧实现必补零，新实现能整段吃掉', () {
      // 旧实现 FIFO 存量只有 ~10ms ⇒ 一卡就断；新实现起播垫到 60ms
      // ⇒ 40ms 卡顿完全被吸收，60ms 卡顿基本被吸收。
      for (final double stall in <double>[0.04, 0.06]) {
        final Map<String, int> oldImpl = simulate(
          deviceFrames: oldDeviceFrames,
          fifoCapacityFrames: oldFifoFrames,
          useJitter: false,
          stallEvery: 100,
          stallSec: stall,
        );
        final Map<String, int> newImpl = simulate(
          deviceFrames: kPlaybackBufferFrames,
          fifoCapacityFrames: kPlaybackFifoCapacityFrames,
          stallEvery: 100,
          stallSec: stall,
        );
        final int stallMs = (stall * 1000).round();
        expect(oldImpl['dry']! + oldImpl['partial']!, greaterThan(0),
            reason: '旧实现（512 帧回调 + 无水位）必须确实会补零，'
                '否则这个对比没有意义');
        expect(newImpl['dry']! + newImpl['partial']!,
            lessThan(oldImpl['dry']! + oldImpl['partial']!),
            reason: '★ ' + stallMs.toString() + 'ms 卡顿下，抖动缓冲必须把补零次数降下来');
      }
    });

    test('★ 100ms 卡顿：新实现仍会漏（诚实边界），但比旧实现少', () {
      // 100ms > 60ms 起播水位 ⇒ 一定还会断；锁住「不是万能」，
      // 同时锁住「仍然严格更好」。
      final Map<String, int> oldImpl = simulate(
        deviceFrames: oldDeviceFrames,
        fifoCapacityFrames: oldFifoFrames,
        useJitter: false,
        stallEvery: 100,
        stallSec: 0.1,
      );
      final Map<String, int> newImpl = simulate(
        deviceFrames: kPlaybackBufferFrames,
        fifoCapacityFrames: kPlaybackFifoCapacityFrames,
        stallEvery: 100,
        stallSec: 0.1,
      );
      expect(newImpl['dry']! + newImpl['partial']!, greaterThan(0),
          reason: '超水位的卡顿必然漏，不能假装已解决');
      expect(newImpl['dry']! + newImpl['partial']!,
          lessThan(oldImpl['dry']! + oldImpl['partial']!),
          reason: '即便超水位，也必须比旧实现好');
    });

    test('★ 一次性积压 1 秒：高水位必须真的触发丢弃并收敛', () {
      double fifo = 0;
      double pending = 0;
      bool playing = false;
      bool catching = false;
      int drops = 0;
      // 50 帧连到、设备一帧不取（瞬时积压 1 秒）
      for (int i = 0; i < 50; i++) {
        final JitterDecision d = decideJitterFrame(
          fifoDepthSec: fifo / kSampleRate,
          pendingSec: pending / kSampleRate,
          frameSec: _frameSec,
          playing: playing,
          catchingUp: catching,
        );
        playing = d.playing;
        catching = d.catchingUp;
        switch (d.action) {
          case JitterAction.prebuffer:
            pending += kFrameSamples;
          case JitterAction.flush:
            fifo += pending + kFrameSamples;
            pending = 0;
          case JitterAction.play:
            fifo += kFrameSamples;
          case JitterAction.drop:
            drops++;
            if (catching) pending = 0;
        }
      }
      expect(catching, isTrue, reason: '积压过深必须进入追赶状态');
      expect(drops, greaterThan(0), reason: '必须真的丢帧，否则延迟追不回来');
      expect(fifo / kSampleRate, greaterThanOrEqualTo(kJitterResetAtSec),
          reason: '触发点就是 400ms 高水位');

      // 设备开始放：追赶期间持续丢帧，直到 FIFO 下探到稳态目标以下
      int guard = 0;
      while (catching && guard < 5000) {
        guard++;
        fifo -= kPlaybackBufferFrames / 8;
        if (fifo < 0) fifo = 0;
        final JitterDecision d = decideJitterFrame(
          fifoDepthSec: fifo / kSampleRate,
          pendingSec: 0,
          frameSec: _frameSec,
          playing: playing,
          catchingUp: catching,
        );
        playing = d.playing;
        catching = d.catchingUp;
      }
      expect(catching, isFalse, reason: '必须能退出追赶状态（否则永久丢帧）');
      expect(guard, lessThan(5000), reason: '追赶必须收敛，不能死循环');
      expect(fifo / kSampleRate, lessThanOrEqualTo(kJitterTargetSec + 1e-9),
          reason: '退出时深度必须已回到稳态目标以下');
    });

    test('★ 默认 FIFO 容量（8192 帧）装不下高水位 —— 本轮的显式容量是必需的', () {
      // 反证：若沿用默认 8192 帧（171ms），400ms 高水位分支永远命不中。
      expect(kJitterResetAtSec * kSampleRate, greaterThan(8192),
          reason: '400ms = 19200 帧 > 8192 帧 ⇒ 默认容量下防积压是死代码');
      expect(kPlaybackFifoCapacityFrames,
          greaterThan(kJitterResetAtSec * kSampleRate),
          reason: '显式容量必须真的装得下高水位');
    });
  });
}
