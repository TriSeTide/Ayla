# Ayla 本地 vendor：flutter_webrtc 1.6.3（诊断补丁）

## 为什么存在这个 fork
用户实报（2026-10-28，Windows）：语音房 **音频条在跳但耳机完全没声音**。
定位过程中发现 flutter_webrtc 的 `selectAudioOutput` 是黑箱：它只回 success/failure，
拿不到「命中哪个设备、匹配方式、ADM 返回码、ADM 视角的设备枚举顺序」。
于是「日志说切到耳机、声音仍在扬声器」这件事无法从代码/日志上判定，只能靠听感猜。

本 fork **只改一处**：`common/cpp/src/flutter_media_stream.cc` 的
`FlutterMediaStream::SelectAudioOutput`。改动内容是：

1. 命中判定除了原有「ADM device id 精确匹配」外，**新增友好名精确匹配回退**
   （Windows CoreAudio 端点 id 形如 `{0.0.0.00000000}.{...}`，而 ADM 的
   `PlayoutDeviceName` 第二参数是驱动 GUID，两者不一定相等 —— 纯 id 匹配会失败）；
2. 返回一个 Map 而不是空 success：
   `{index, name, matchedById, setResult, playoutDeviceCount, devices}`，
   让 Dart 侧能断言「到底切到第几个、是不是按 id 命中的、ADM 返回码是多少」；
3. 找不到设备时，错误信息里**带上完整枚举清单**（排查设备在 ADM 里的名字/ id 必需）。

**不改变切换语义**（仍然只调用 `SetPlayoutDevice`），所以不会让原本能用的平台行为变差。

## 为什么不能只在 Dart 层修
`SetPlayoutDevice` 在 libwebrtc 内部是 `worker_thread_->PostTask(...)` 后**立即 `return 0`**；
「已经在播放中」要不要先 Stop/Init 再 Start 的决定在该实现里，Dart 侧没有暴露任何
「停/起 playout」的 API。所以要么改 C++（本 fork），要么把整个播放通路换掉。

## 升级 flutter_webrtc 的步骤
1. `flutter pub upgrade` 前先看 `third_party/flutter_webrtc/pubspec.yaml` 的 version；
2. 用新版覆盖 `third_party/flutter_webrtc/`（**保留本 README 与 .gitignore**）；
3. 把 `SelectAudioOutput` 的补丁重新打上（补丁原文见本仓库提交记录）；
4. `third_party/libwebrtc_version.ini` 的 `binary_version` 若变了，删掉
   `third_party/downloads/` 里的旧 zip，否则 CMake 会继续用旧二进制。

## 目录里什么入库、什么不入库
- **入库**：`lib/`、`common/`、`windows/`、`android/`、`ios/`、`macos/`、`linux/`、`elinux/`、
  `third_party/*.txt`、`third_party/libwebrtc_version.ini`、`third_party/svpng/`、`pubspec.yaml`；
- **不入库**（见 `.gitignore`）：`third_party/libwebrtc/`（29MB 预编译二进制，
  首次 configure 时按版本清单自动下载）、`third_party/downloads/`、`.dart_tool/`、`build/`、`example/build/`。

## 验收
- `flutter build windows --debug` 成功（证明补丁可编译）；
- 真 App 进语音房，日志出现 `[lk] 输出设备切换回执` 并含 `matchedById=? setResult=0 index=?`；
- `Ayla/.workbuddy/evidence/livekit-udp/peak_all.ps1` 读 CoreAudio 峰值：远端说话时
  **默认多媒体端点 > 0.1**、**默认通信端点 ≈ 0**。
