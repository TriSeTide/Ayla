# Ayla 本地 vendor：media_kit_video 2.0.1（多引擎补丁）

## 为什么存在这个 fork

用户实报（2026-10-31，Windows）：「电脑端直播小窗，也要脱离应用」。
难点不在开窗口，而在「**主窗口的直播不能因此黑屏**」。

第二个顶层窗口需要第二个 Flutter engine（见
`windows/runner/live_window.cpp`）。而 media_kit_video 2.0.1 的 Windows 插件里有一个
**进程级单例**：

```cpp
// windows/media_kit_video_plugin.h:52 (上游)
static MediaKitVideoPlugin* instance_;
```

每个 engine 注册插件都会把它覆盖成自己；而插件把主窗口的
`GWLP_WNDPROC` 换成了一个**静态** `WindowProcDelegate`，那个 delegate 全凭
`instance_` 分派：

- `kMainThreadTaskMessage` 被派给错误的 engine ⇒ 主窗口的生成回调永远
  不执行 ⇒ **主窗口的 `VideoController.create()` 永久挂起**；
- 旧 WNDPROC 也被转发到错误的对象上 ⇒ 主窗口消息链也不对。

结果就是用户看到的那个现象：**一开独立小窗，主窗口直播就黑屏**。
这是上游已知问题 media-kit#1383（OPEN）。

## 补丁内容（只改两个文件）

### 1. `windows/media_kit_video_plugin.h`

```cpp
#include <unordered_map>   // 新增

  // 旧：static MediaKitVideoPlugin* instance_;
  // 新：按“插件护住的那个 HWND”索引
  static std::unordered_map<HWND, MediaKitVideoPlugin*> instances_;
```

### 2. `windows/media_kit_video_plugin.cc`

```cpp
// 定义
std::unordered_map<HWND, MediaKitVideoPlugin*> MediaKitVideoPlugin::instances_ =
    std::unordered_map<HWND, MediaKitVideoPlugin*>();

// 构造：刚刚 hook 了这个 HWND 的 WNDPROC ⇒ 登记到它名下
flutter_window_ = ::GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
if (flutter_window_ != nullptr) {
  instances_[flutter_window_] = this;
}
original_window_proc_ = ...SetWindowLongPtr(...);

// 析构：只拿掉自己那一条（绝不能清全表）
if (flutter_window_ != nullptr) {
  auto it = instances_.find(flutter_window_);
  if (it != instances_.end() && it->second == this) instances_.erase(it);
}

// WindowProcDelegate：用传入的 hwnd 查表，而不是用全局单例
MediaKitVideoPlugin* instance = nullptr;
auto it = instances_.find(hwnd);
if (it != instances_.end()) instance = it->second;
if (message == kMainThreadTaskMessage && instance) { instance->ProcessMainThreadTasks(); return 0; }
if (instance && instance->original_window_proc_) {
  return ::CallWindowProc(instance->original_window_proc_, hwnd, message, wParam, lParam);
}
return ::DefWindowProc(hwnd, message, wParam, lParam);
```

**不变的部分**：消息号（`WM_USER + 1001`）、任务队列与互斥锁、
`VideoOutputManager` 的生命周期、Dart 侧公开 API 全部不变。
即：单引擎场景的行为与上游**逐字等价**（只是查表代替了单指针）。

## 为什么不能只在 Dart/CMake 层解决

- 不能只开一个 Win32 子窗口：用户要求的是「主窗口最小化后仍能看到」，
  子窗口会跟着父窗口一起隐藏，且主窗口不画的时候子区域不会重绘；
- 不能用 `desktop_multi_window`：它没有 topmost / frameless / 自定义 Dart entrypoint，
  子窗口连热重载都没有；
- 不能照 flutter_webrtc 那种「只加诊断」的做法：这里必须**真的改语义**（单个
  指针 → HWND 表）。

## 升级 media_kit_video 时必须重打的点（忘了就会重现黑屏）

1. 把新版覆盖到 `third_party/media_kit_video/`（**保留本 README**）；
2. 重新对 `windows/media_kit_video_plugin.h` 打：加 `<unordered_map>`、
   `instance_` → `instances_`（类型 `std::unordered_map<HWND, MediaKitVideoPlugin*>`）；
3. 重新对 `windows/media_kit_video_plugin.cc` 打：静态定义、构造函数登记、
   析构函数注销、`WindowProcDelegate` 改成按 `hwnd` 查表；
4. `flutter pub get` 后确认 `pubspec.lock` 里 `media_kit_video` 的 `source: path` 指向
   `third_party/media_kit_video`；
5. 回归：`flutter build windows --debug` 通过 + 主窗口直播能起播（不能只看编译）。

## 目录里什么入库、什么不入库

- **入库**：整个包（`lib/``windows/``android/``ios/``macos/``linux/``common/``pubspec.yaml`…）
  —— 照本仓库已有的 `third_party/flutter_webrtc/` 先例；
- **不入库**：`example/`、`build/`、`.dart_tool/`（已在拷贝时删除）。

## 验收现状（2026-10-31）

- ✅ `flutter build windows --debug` 通过（补丁可编译）；
- ✅ `dart analyze lib` 零告警；
- ⚠️ **未在真实桌面上肉眼验证**「独立小窗弹出 + 主窗口仍能直播」。
  用户验收步骤见 `Ayla/docs/flutter/41-2026-10-31-Windows直播小窗脱离-实现与验收.md` 第三节。
