#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "audio_default_device.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// Posted by AylaLiveWindowHost when the detached live window disappeared
// without Dart asking for it (user clicked it away / closed it natively).
constexpr UINT kDetachedLiveWindowClosedMessage = WM_APP + 1;

// DWMWA_WINDOW_CORNER_PREFERENCE (Windows 11 22H2+, SDK 10.0.22621+).
// Redefined here so the runner still compiles against an older SDK header.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

// DWM_WINDOW_CORNER_PREFERENCE values (dwmapi.h). Spelled out instead of using
// the enum so an older SDK header cannot break the build.
constexpr int kDwmWindowCornerDoNotRound = 1;  // DWMWCP_DONOTROUND
constexpr int kDwmWindowCornerDefault = 0;     // DWMWCP_DEFAULT

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
            live_window_host_ =
                std::make_unique<AylaLiveWindowHost>(GetHandle());
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
        if (method == "showBall") {
          // The detached FLOATING BALL is a separate feature; this runner only
          // implements the live window. Answer with an explicit "unsupported"
          // (never throw) so the Dart side can degrade visibly.
          result->Success(flutter::EncodableValue("unsupported"));
          return;
        }
        if (method == "hideBall") {
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
  // window_manager's fullscreen path is the one that strips WS_THICKFRAME
  // (SetFullScreen -> SetWindowLongPtr with ~(WS_THICKFRAME | WS_MAXIMIZEBOX)),
  // so requiring the missing thick frame tells the two apart exactly.
  const bool frameless =
      (::GetWindowLong(window, GWL_STYLE) & WS_THICKFRAME) == 0;

  const bool is_fullscreen = covers_monitor && frameless;
  SetFullscreen(is_fullscreen);

  // Win11 rounds every app window's corners; in fullscreen that leaves the
  // desktop colour visible in all four corners. Turn it off while (and only
  // while) the window covers a monitor, and back to the system default after.
  if (donotround_hwnd_ == window && donotround_applied_ == is_fullscreen) {
    return;
  }
  const int preference = is_fullscreen ? kDwmWindowCornerDoNotRound
                                       : kDwmWindowCornerDefault;
  const HRESULT hr = ::DwmSetWindowAttribute(
      window, DWMWA_WINDOW_CORNER_PREFERENCE, &preference,
      sizeof(preference));
  // Only remember success: on Windows 10 the attribute does not exist and the
  // call fails, in which case we retry on the next WM_SIZE instead of
  // pretending the corners are square when they are not.
  if (SUCCEEDED(hr)) {
    donotround_hwnd_ = window;
    donotround_applied_ = is_fullscreen;
  }
}
