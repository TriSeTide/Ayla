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
///
/// ## 适用范围变更（task-5 LiveKit 接入，2026-10-27）
/// 本轮把媒体面默认实现扩成**双后端**（LiveKit | ws_relay，见
/// ~lib/audio/voice_media.dart~）。按任务硬性要求，**ws_relay 整条路径一行未删**
/// （~audio_engine.dart~ / ~relay_client.dart~ 是回滚路径），因此本文件锁定的
/// ~audio_engine.dart~ 仍是**活的生产代码**（~VOICE_MEDIA_TRANSPORT=ws_relay~ 时
/// 全量生效），断言继续有效，**未删除、未放宽**。
///
/// 这里显式登记两点，避免下一个 agent 误解：
/// 1. 本文件的 38 例只覆盖 **ws_relay 回滚路径**的抖动缓冲；LiveKit 路径的
///    抖动/丢包恢复由 SDK（~jitter buffer~ + ~RED~）负责，对应契约锁见
///    ~test/livekit_voice_backend_test.dart~（含「DTX 必须关闭」一条）；
/// 2. ~docs/flutter/38~ §六那次事故的**认知**（欠载阈值必须 ≥ 一次设备回调消耗量）
///    已固化在 ~kUnderrunFloorSec~ 的注释与本文件的用例里，不随引擎退役而失效。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/poc/relay_protocol.dart';

/// 语音帧长（秒）。20ms 帧。
const double _frameSec = kFrameMs / 1000.0;

/// 读源码（接线锁用）。
String _src(String relative) => File(relative).readAsStringSync();

/// 剥掉 `//` 行注释（保留下标对齐无关性：只用于 contains 判断）。
///
/// 用于「源码里不许再出现某段代码」这类锁：文档注释里常引用旧代码作反例，
/// 不剥注释会把反例当成违规（2026-10-27 实测假红一次）。
String _stripLineComments(String src) => src
    .split('\n')
    .map((String line) {
      final int i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

void main() {
  // 起播水位必须真的比一帧厚；否则这个「抖动缓冲」不存在。
  const double start = kJitterStartSec;
  const double target = kJitterTargetSec;
  // ⚠️ 欠载判据是 kUnderrunFloorSec（一次设备回调的 2 倍），
  // **不是** kJitterAheadTargetSec（那是 web 的排播前瞻量，2026-10-27 事故）。
  const double underrun = kUnderrunFloorSec;
  const double reset = kJitterResetAtSec;

  group('水位常量自检（web 0.02 / 0.4 为锚点；欠载判据独立推导）', () {
    test('前瞻量锚点 = web 的一帧 lead（20ms），但它**不作欠载判据**', () {
      expect(kJitterAheadTargetSec, 0.02,
          reason: 'web `at < now + 0.02` 的 0.02 是权威锚点，不许漂移');
      // 2026-10-27 事故订正：这条锚点曾被直接当成 FIFO 欠载阈值，
      // 导致 bufferFrames=1024 下每次回调都误判欠载 ⇒ 成段静音。
      expect(kUnderrunFloorSec, isNot(equals(kJitterAheadTargetSec)),
          reason: '欠载判据必须独立于 web 的排播前瞻量');
    });

    test('积压阈值 = web 的 400ms', () {
      expect(kJitterResetAtSec, 0.4,
          reason: 'web `at > now + 0.4` 的 0.4 是权威值，不许漂移');
    });

    test('★ 起播水位必须 ≥ 3 帧（60ms）——否则等于没有抖动缓冲', () {
      expect(start, greaterThanOrEqualTo(3 * _frameSec),
          reason: '2 帧连丢就会欠载，frp 抖动下依然断续');
      expect(start, lessThanOrEqualTo(0.12),
          reason: '起播垫超过 ~120ms 会明显拖慢对话节奏');
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

    test('第 2 帧仍不够起播水位 ⇒ 继续预缓冲', () {
      // 已攒 1 帧；再加本帧 = 40ms < kJitterStartSec
      expect(d(0, _frameSec).action, JitterAction.prebuffer);
    });

    test('★ 攒满 kJitterStartSec ⇒ 一次性 flush 起播', () {
      // 2026-10-27 订正：旧断言写死「2 帧 + 本帧 = 60ms ⇒ flush」，
      // 而 60ms 起播在服务端实测的双峰到达（75% 帧挤在 <10ms、15% 在
      // 40–50ms 空档）下仍会周期性见底 ⇒ 起播水位已提到 kJitterStartSec。
      final double needSec = kJitterStartSec - _frameSec + 1e-9;
      final JitterDecision r = d(0, needSec);
      expect(r.action, JitterAction.flush);
      expect(r.playing, isTrue);
      expect(r.catchingUp, isFalse);
    });

    test('设备 FIFO 已有存量也计入水位（不是只看预缓冲）', () {
      final double needSec = kJitterStartSec - _frameSec + 1e-9;
      expect(d(needSec, 0).action, JitterAction.flush);
    });

    test('★ 起播后不会因为「只有一帧」就立刻停（欠载下限 ≥ 单次回调消耗量）', () {
      // 2026-10-27 订正：旧断言锁的是「20ms 提前量就该继续播」——
      // 而那正是事故根因：bufferFrames=1024 时一次回调要吃掉 21.3ms，
      // 20ms 的「提前量」根本不够一次回调 ⇒ 每次回调后都判欠载 ⇒ 成段静音。
      // 正确语义：深度 ≥ kUnderrunFloorSec 就继续播。
      final JitterDecision r = d(kUnderrunFloorSec + 1e-9, 0, playing: true);
      expect(r.action, JitterAction.play,
          reason: '达到欠载下限（≥ 一次回调消耗量）就应当继续播');
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

    test('FIFO 深 399ms ⇒ 已过期，必须 drop + 进入追赶（2026-10-27 语义变更）', () {
      // ⚠️ 旧断言是「399ms 仍然 play，不误杀」—— 那在**只看 FIFO 高水位**的模型里成立，
      // 但用户实报「恢复连接时爆发式听见这段时间所有帧」证明：399ms 的积压播出去
      // 就是「补播 0.4 秒前的声音」。实时语音里这已经是**过期音频**，必须丢弃。
      // 现语义：待播总量 > kStaleDropSec(200ms) ⇒ 丢弃并进入追赶（catchingUp）。
      final JitterDecision r = decideJitterFrame(
        fifoDepthSec: 0.399,
        pendingSec: 0,
        frameSec: _frameSec,
        playing: true,
        catchingUp: false,
      );
      expect(r.action, JitterAction.drop,
          reason: '399ms 待播 = 过期音频，播放它等于补播 0.4 秒前的话');
      expect(r.catchingUp, isTrue, reason: '要进入追赶，持续丢弃直到水位回落');
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

    test('★ 欠载后要重新攒到起播水位才复播（不是攒一帧就播）', () {
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
      // 攒够 kJitterStartSec 才复播（2026-10-27：水位已从 60ms 提到 100ms）
      r = decideJitterFrame(
        fifoDepthSec: 0,
        pendingSec: kJitterStartSec - _frameSec + 1e-9,
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
      for (final double depth in <double>[
        0.35,
        0.2,
        kJitterTargetSec * 2,
        kJitterTargetSec * 1.5,
      ]) {
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

    test('★★ 音频帧必须**持续发送**，不得以 speaking 门控（2026-10-27 设计缺陷修复）', () {
      // ⚠️ 必须剥掉注释再判：本文件的文档注释里**故意保留**了旧代码片段
      // `if (!nowSpeaking) return;` 作为反例说明（见 _processFrame 的 docstring），
      // 直接 contains 会命中注释而假红（实测踩过）。
      final String engine = _stripLineComments(_src('lib/audio/audio_engine.dart'));
      // 旧锁断言 `if (!nowSpeaking) return;` 存在 —— 那正是缺陷本身：
      // 人说话的停顿/句尾降调/换气都会跌破阈值 ⇒ 停发 ⇒ 对端只收到有声片段，
      // 听感「有声音才连上去，声音小了就跟断了一样」（用户实报）。
      expect(engine, isNot(contains('if (!nowSpeaking) return;')),
          reason: 'speaking 是 UI 事实，不能当媒体门控');
      // speaking 仍要上报（成员行高亮依赖它）
      expect(engine, contains("sendControl('speaking'"));
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
      // ⚠️ 2026-10-27 语义变更：触发点从「FIFO 400ms 高水位」改为「待播总量 200ms」
      // （kStaleDropSec）。旧断言写的 400ms 已不成立 —— 现在更早介入，
      // 目的就是不让积压长到 400ms 才处理（那已经是 0.4 秒的过期音频）。
      expect(fifo / kSampleRate, greaterThanOrEqualTo(kStaleDropSec),
          reason: '积分段应至少累积到过期阈值 kStaleDropSec 才触发');

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
