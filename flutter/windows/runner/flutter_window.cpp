#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "audio_default_device.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// Posted by AylaLiveWindowHost when a detached overlay window disappeared
// without Dart asking for it (user clicked it away / closed it natively).
constexpr UINT kDetachedLiveWindowClosedMessage = WM_APP + 1;

// Posted by AylaLiveWindowHost when the user clicked the detached floating
// ball (the overlay window stays open; the MAIN engine owns routing).
constexpr UINT kDetachedBallTapMessage = WM_APP + 2;

// Posted by AylaLiveWindowHost when the detached floating-ball window closed
// without Dart asking for it.
constexpr UINT kDetachedBallClosedMessage = WM_APP + 3;

// NOTE: the DWM corner/border/nc-rendering attributes used to be declared here.
// They now live in win32_window.cpp next to SyncWindowFrameDecoration, which is
// their single owner (see that function for why all three act together).

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Expose the OS default audio endpoints (see audio_default_device.h for why).
  audio_device_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ayla/audio_default_device",
          &flutter::StandardMethodCodec::GetInstance());
  audio_device_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "getDefaultAudioDevice") {
          result->NotImplemented();
          return;
        }
        bool capture = false;
        int role = 1;  // eMultimedia = the normal "default device"
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args != nullptr) {
          auto it = args->find(flutter::EncodableValue("capture"));
          if (it != args->end()) {
            const auto* value = std::get_if<bool>(&it->second);
            if (value != nullptr) {
              capture = *value;
            }
          }
          it = args->find(flutter::EncodableValue("role"));
          if (it != args->end()) {
            const auto* as_int = std::get_if<int32_t>(&it->second);
            if (as_int != nullptr) {
              role = *as_int;
            } else {
              const auto* as_long = std::get_if<int64_t>(&it->second);
              if (as_long != nullptr) {
                role = static_cast<int>(*as_long);
              }
            }
          }
        }
        flutter::EncodableMap out;
        out[flutter::EncodableValue("id")] =
            flutter::EncodableValue(AylaDefaultAudioDeviceId(capture, role));
        out[flutter::EncodableValue("name")] =
            flutter::EncodableValue(AylaDefaultAudioDeviceName(capture, role));
        result->Success(flutter::EncodableValue(out));
      });

  // Detached live window: "ayla/desktop_window"
  // (Dart contract: lib/core/platform/detached_live.dart).
  //
  // Why it lives in the runner and not in a plugin package: it has to create a
  // SECOND Flutter engine + top-level HWND, i.e. it needs the runner's own
  // window ownership, and it must keep working while the main window is
  // minimised (WS_EX_TOPMOST | WS_EX_TOOLWINDOW popup).
  desktop_window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "ayla/desktop_window",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();

        auto read_string = [&call](const char* key) -> std::string {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            return std::string();
          }
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) {
            return std::string();
          }
          const auto* value = std::get_if<std::string>(&it->second);
          return value != nullptr ? *value : std::string();
        };

        if (method == "openLiveWindow") {
          if (live_window_host_ == nullptr) {
            live_window_host_ = std::make_unique<AylaLiveWindowHost>(
                GetHandle(), AylaOverlayKind::kLiveMini);
          }
          const bool opened = live_window_host_->Show(
              read_string("channelId"), read_string("title"),
              read_string("playUrl"));
          result->Success(flutter::EncodableValue(opened));
          return;
        }
        if (method == "closeLiveWindow") {
          // Dart-initiated: no onLiveWindowClosed callback (the caller knows).
          // Non-blocking: destroying a second engine synchronously inside this
          // channel callback would re-enter the engine we are running on.
          if (live_window_host_ != nullptr) {
            live_window_host_->RequestClose();
          }
          result->Success(flutter::EncodableValue(std::monostate{}));
          return;
        }
        if (method == "showBall" || method == "updateBall") {
          // Detached FLOATING BALL: the SAME AylaSessionActivityIndicator the
          // app used to draw in its own overlay, now hosted by a transparent
          // always-on-top popup window with a second engine.
          //
          // "payload" is the serialised AylaOverlayPayload
          // (lib/widgets/shell/overlay_window_app.dart) - the second engine has
          // no auth / WS / router, so the MAIN engine pushes the projection.
          const std::string payload = read_string("payload");
          if (ball_window_host_ == nullptr) {
            ball_window_host_ = std::make_unique<AylaLiveWindowHost>(
                GetHandle(), AylaOverlayKind::kActivityBall);
          }
          const bool ok = method == "showBall"
                              ? ball_window_host_->ShowBall(payload)
                              : ball_window_host_->UpdateBall(payload);
          result->Success(flutter::EncodableValue(ok ? "shown" : "failed"));
          return;
        }
        if (method == "hideBall") {
          if (ball_window_host_ != nullptr) {
            // Dart-initiated: no onBallClosed round-trip (the caller knows).
            ball_window_host_->RequestClose();
          }
          result->Success(flutter::EncodableValue(std::monostate{}));
          return;
        }
        if (method == "setWindowFullscreen") {
          // The Dart side tells us explicitly whether the MAIN window is in
          // window-level fullscreen (window_manager.setFullScreen). See
          // FlutterWindow::SyncFullscreenWindowState for why the geometric
          // inference alone is not reliable enough.
          bool fullscreen = false;
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("fullscreen"));
            if (it != args->end()) {
              const auto* value = std::get_if<bool>(&it->second);
              if (value != nullptr) {
                fullscreen = *value;
              }
            }
          }
          fullscreen_hint_ = fullscreen;
          SyncFullscreenWindowState(GetHandle());
          result->Success(flutter::EncodableValue(std::monostate{}));
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Order matters: the detached window is a SECOND engine and must be gone
  // before the main engine (it forwards window messages to Flutter), and the
  // channels hold the engine's messenger so they go first as well.
  if (live_window_host_ != nullptr) {
    live_window_host_->Close(false);
    live_window_host_.reset();
  }
  if (ball_window_host_ != nullptr) {
    ball_window_host_->Close(false);
    ball_window_host_.reset();
  }
  desktop_window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // ---- Ayla custom frame (2026-11-04) -------------------------------------
  // Answered BEFORE the engine: the engine fans these messages out to every
  // registered top-level proc delegate, and window_manager's delegate implements
  // WM_NCCALCSIZE too (its "frameless" path inflates the client rect by the
  // frame thickness, which would make the Flutter view larger than the window).
  // Whichever delegate answers first wins, so the frame is settled here.
  // Design, and the reason the resize edges live in Dart, are in win32_window.h.
  LRESULT frame_result = 0;
  if (HandleNcCalcSize(message, hwnd, wparam, lparam, &frame_result)) {
    return frame_result;
  }
  if (message == WM_NCHITTEST) {
    return HitTestFrame(hwnd, lparam);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kDetachedLiveWindowClosedMessage:
      // The detached live window is gone. Tell Dart so it can fall back to the
      // in-app mini player instead of keeping a phantom "detached" state.
      if (desktop_window_channel_ != nullptr) {
        desktop_window_channel_->InvokeMethod("onLiveWindowClosed", nullptr);
      }
      // ... and bring ourselves back to the foreground ("click the small
      // window => go back to the app").
      if (::IsIconic(hwnd)) {
        ::ShowWindow(hwnd, SW_RESTORE);
      }
      ::SetForegroundWindow(hwnd);
      break;
    case kDetachedBallTapMessage: {
      // The user clicked the detached floating ball. The overlay window stays
      // open (they may well come back to it); the MAIN engine navigates.
      std::string kind;
      std::string route;
      if (ball_window_host_ != nullptr &&
          ball_window_host_->TakePendingBallTap(&kind, &route)) {
        if (desktop_window_channel_ != nullptr) {
          desktop_window_channel_->InvokeMethod(
              "onBallTap",
              std::make_unique<flutter::EncodableValue>(
                  flutter::EncodableMap{
                      {flutter::EncodableValue("kind"),
                       flutter::EncodableValue(kind)},
                      {flutter::EncodableValue("sourceRoute"),
                       flutter::EncodableValue(route)},
                  }));
        }
      }
      break;
    }
    case kDetachedBallClosedMessage:
      // The detached floating ball is gone. Tell Dart so the host can re-create
      // it on the next session change instead of believing it is still shown.
      if (desktop_window_channel_ != nullptr) {
        desktop_window_channel_->InvokeMethod("onBallClosed", nullptr);
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE:
      // window_manager flips the window in/out of fullscreen entirely with
      // SetWindowLongPtr + SetWindowPos, so the only reliable observation
      // point on our side is the resulting WM_SIZE - handled *after* Flutter
      // got its chance above, so the plugin has already run.
      SyncFullscreenWindowState(hwnd);
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SyncFullscreenWindowState(HWND window) {
  if (window == nullptr) {
    return;
  }

  RECT frame{};
  if (::GetWindowRect(window, &frame) == 0) {
    return;
  }
  const HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (::GetMonitorInfo(monitor, &info) == 0) {
    return;
  }

  // "Covers the whole monitor" is what window_manager produces for
  // setFullScreen(true) (rcMonitor, no frame). Comparing with a small
  // tolerance avoids depending on exact rounding of the DPI-scaled rect.
  const RECT& target = info.rcMonitor;
  // NOTE: do not name this helper `near`: windef.h still defines `near`/`far`
  // macros, so "const auto near = ..." fails to compile (C2513).
  const auto within_two_px = [](LONG a, LONG b) {
    const LONG diff = a - b;
    return diff <= 2 && diff >= -2;
  };
  const bool covers_monitor = within_two_px(frame.left, target.left) &&
                              within_two_px(frame.top, target.top) &&
                              within_two_px(frame.right, target.right) &&
                              within_two_px(frame.bottom, target.bottom);

  // "Covers the monitor" alone is not enough: a *maximized* window also fills
  // rcMonitor on a monitor whose taskbar auto-hides (rcWork == rcMonitor).
  //
  // Two independent signals, and the explicit one wins while it is set:
  //
  //  1. **Geometric inference** (below): window_manager's fullscreen path
  //     strips WS_THICKFRAME (SetFullScreen -> SetWindowLongPtr with
  //     ~(WS_THICKFRAME | WS_MAXIMIZEBOX)), so "covers the monitor AND has no
  //     thick frame" identifies fullscreen exactly - PROVIDED the plugin
  //     actually took that branch. It does not when it is entered from a
  //     MAXIMIZED window on old window_manager builds, which is precisely the
  //     "maximized + click fullscreen = nothing happens" bug.
  //
  //  2. **Explicit hint** from Dart: AylaDesktopWindowController.setFullScreen
  //     pushes setWindowFullscreen(true/false) around the window_manager call,
  //     because the Dart side is the one that knows it asked for fullscreen.
  //
  // The hint is only trusted while the geometry agrees with it (a fullscreen
  // hint on a window that does not cover its monitor is stale: the user may
  // have dragged/resized it, or the call failed). It is cleared as soon as the
  // geometry agrees, so it can never stick around and mislabel a maximized
  // window.
  const bool frameless =
      (::GetWindowLong(window, GWL_STYLE) & WS_THICKFRAME) == 0;

  // ⚠️ 2026-11-04（Ayla 自绘标题栏）：**不要再用 client-fills-window 当判据**。
  // 定制边框让 WM_NCCALCSIZE 恒返回 0（客户区 = 整个窗口，见 win32_window.h），
  // 于是 client == window 在**最大化窗口上也永远成立** —— 拿它做 OR 会让
  // 「任务栏自动隐藏的显示器上，最大化窗口」被误判成全屏（后果：Win11 圆角被关掉、
  // is_fullscreen_ 置位后 WM_DPICHANGED 不再重定位，跨显示器拖动会回不去）。
  //
  // 现在唯一可靠的几何信号是 WS_THICKFRAME：只有 window_manager 的
  // SetFullScreen 会把它剥掉（SetAsFrameless / ~WS_THICKFRAME），最大化窗口保留它。
  const bool geometric_fullscreen = covers_monitor && frameless;

  bool is_fullscreen = geometric_fullscreen;
  if (fullscreen_hint_.has_value()) {
    if (*fullscreen_hint_ == covers_monitor) {
      // Hint and geometry agree (either "fullscreen and covering" or "not
      // fullscreen and not covering") => consume the hint.
      is_fullscreen = *fullscreen_hint_;
      fullscreen_hint_.reset();
    } else if (!covers_monitor) {
      // "not fullscreen" hint on a window that does not cover the monitor:
      // the exit is complete, nothing left to wait for.
      fullscreen_hint_.reset();
    }
    // Otherwise: "fullscreen" hint while the window does not cover its monitor
    // yet (window_manager is still mid-flight) => keep the hint, stay
    // not-fullscreen for now and re-evaluate on the next WM_SIZE.
  }

  ApplyFullscreenState(window, is_fullscreen);
}

void FlutterWindow::ApplyFullscreenState(HWND window, bool is_fullscreen) {
  SetFullscreen(is_fullscreen);

  // ⚠️ 圆角 / 阴影 / 1px 边线不再在这里设：`Win32Window::SyncWindowFrameDecoration`
  // 是那三个 DWM 属性的**唯一 owner**（它在 WM_SIZE 里按「窗口化 / 最大化 / 全屏」
  // 三态统一切换）。这里只需要把全屏状态登记进去并推动一次重算 ——
  // 两处都写同一个 DWMWA_WINDOW_CORNER_PREFERENCE 会互相覆盖：
  // 本函数原来在退出全屏时写 DWMWCP_DEFAULT（0），而 DEFAULT 在 Win11 上等于
  // **圆角**，于是「最大化窗口退出全屏」会拿到圆角 + 贴屏边 ⇒ 四角露桌面色。
  SyncWindowFrameDecoration(window);
}
