/// Windows 系统默认音频端点查询（原生 MethodChannel `ayla/audio_default_device`）。
///
/// ## 为什么需要
/// Windows 上「默认设备」和「默认通信设备」是**两个可以独立指定**的端点。
/// WebRTC（LiveKit 的底层）音频设备模块**默认使用"默认通信设备"**，于是在
/// 默认设备 = 蓝牙耳机的机器上，会出现「远端音频条在动、但声音从板载扬声器出/
/// 或者根本听不到」——用户 2026-10-28 实报的正是这个。
///
/// 这里读出系统**真实**的默认端点（MMDevice id），再交给
/// `Hardware.instance.selectAudioOutput` / `selectAudioInput` 指定，
/// 从而让语音跟随用户的系统默认设备，而不是 WebRTC 的通信设备默认值。
///
/// 非 Windows 平台一律返回 null（调用方跳过）。
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 一次查询的结果（id 是 MMDevice 端点 id，name 是友好名）。
typedef AylaAudioEndpoint = ({String id, String name});

class AylaWindowsAudioDevice {
  const AylaWindowsAudioDevice._();

  static const MethodChannel _channel =
      MethodChannel('ayla/audio_default_device');

  /// 当前平台是否支持。
  static bool get supported => Platform.isWindows;

  /// 查询系统默认端点。
  ///
  /// [role] 0 = Console，**1 = Multimedia（"默认设备"，用户日常听声音的那个）**，
  /// 2 = Communications（"默认通信设备"，WebRTC 的默认选择）。
  /// [capture] true 查录音端点，false 查播放端点。
  static Future<AylaAudioEndpoint?> defaultEndpoint({
    bool capture = false,
    int role = 1,
  }) async {
    if (!supported) return null;
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'getDefaultAudioDevice',
        <String, dynamic>{'capture': capture, 'role': role},
      );
      if (raw == null) return null;
      final String id = (raw['id'] ?? '').toString();
      if (id.isEmpty) return null;
      return (id: id, name: (raw['name'] ?? '').toString());
    } catch (_) {
      // 原生通道不可用（如非 Windows 误调）不是错误路径。
      return null;
    }
  }
}
