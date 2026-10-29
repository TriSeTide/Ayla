#include "live_window.h"

#include <dwmapi.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <chrono>
#include <cstdio>
#include <sstream>

// The vendored media_kit_video is the ONLY plugin the second engine registers.
// Deliberately NOT RegisterPlugins() (that would spin up a second copy of
// flutter_webrtc / livekit / record for an engine that only paints a video).
#include <media_kit_video/media_kit_video_plugin_c_api.h>

namespace {

/// Window class of the detached live window.
constexpr const wchar_t kLiveWindowClass[] = L"AYLA_DETACHED_LIVE_WINDOW";

/// Client size of the detached live window (16:9, 360 x 202 as specified).
constexpr int kLiveWindowWidth = 360;
constexpr int kLiveWindowHeight = 202;

/// Distance from the work-area right/bottom edge.
constexpr int kLiveWindowMargin = 24;

/// DWMWA_WINDOW_CORNER_PREFERENCE (Win11). See win32_window.cpp.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DONOTROUND
#define DWMWCP_DONOTROUND 1
#endif

/// Name of the Dart entrypoint (must exist in lib/main.dart and be a top-level
/// function decorated with @pragma('vm:entry-point')).
constexpr const char* kDartEntrypoint = "aylaLiveWindowMain";

// Per-window state attached through GWLP_USERDATA (WM_NCCREATE wires |host|).
struct LiveWindowContext {
  AylaLiveWindowHost* host = nullptr;
};

/// Minimal JSON string escaping for the Dart entrypoint payload.
///
/// Only used for {playUrl, title, channelId}: escaping + control characters is
/// enough, no unicode escape is needed because the payload is passed as raw
/// UTF-8 on the command line and parsed with dart:convert on the Dart side.
std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (const char c : value) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                        static_cast<unsigned int>(c));
          out += buffer;
        } else {
          out += c;
        }
        break;
    }
  }
  return out;
}

}  // namespace

AylaLiveWindowHost::AylaLiveWindowHost(HWND owner_window)
    : owner_window_(owner_window) {}

AylaLiveWindowHost::~AylaLiveWindowHost() {
  Close(false);
  TearDown();
}

bool AylaLiveWindowHost::Show(const std::string& channel_id,
                              const std::string& title,
                              const std::string& play_url) {
  // A live window is a singleton (UI + resource budget: one engine per window).
  // Re-opening while one exists means "the session switched target", so replace.
  if (window_handle_ != nullptr || controller_ != nullptr) {
    Close(false);
  }
  if (play_url.empty()) {
    // No url => nothing to paint. The Dart side falls back to the mini player.
    return false;
  }

  // ---- window class (registered lazily, this is the only owner) -------------
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = AylaLiveWindowHost::WndProc;
  window_class.cbClsExtra = 0;
  window_class.cbWndExtra = 0;
  window_class.hInstance = instance;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground = static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = kLiveWindowClass;
  // Fails with ERROR_CLASS_ALREADY_EXISTS on re-open; that is fine.
  ::RegisterClassExW(&window_class);

  // ---- position: bottom-right corner of the work area ----------------------
  HMONITOR monitor = ::MonitorFromWindow(
      owner_window_ != nullptr ? owner_window_ : ::GetActiveWindow(),
      MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(MONITORINFO);
  RECT work_area = {};
  if (::GetMonitorInfoW(monitor, &monitor_info)) {
    work_area = monitor_info.rcWork;
  } else {
    ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  }
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;
  const int window_width = static_cast<int>(kLiveWindowWidth * scale);
  const int window_height = static_cast<int>(kLiveWindowHeight * scale);
  const int margin = static_cast<int>(kLiveWindowMargin * scale);
  const int window_x =
      work_area.right - window_width - margin;
  const int window_y =
      work_area.bottom - window_height - margin;

  // WS_POPUP            : no title bar / border (the player draws its own).
  // WS_CLIPCHILDREN     : the Flutter view is a child HWND; don't paint over it.
  // WS_CLIPSIBLINGS     : same, for sibling ordering.
  // WS_EX_TOPMOST       : stays above other apps (that is the whole point).
  // WS_EX_TOOLWINDOW    : keeps it out of Alt-Tab and the taskbar.
  window_handle_ = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kLiveWindowClass, L"",
      WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, window_x, window_y,
      window_width, window_height, nullptr, nullptr, instance, this);
  if (window_handle_ == nullptr) {
    return false;
  }

  // Square corners: a borderless always-on-top window with Win11 rounding shows
  // the desktop colour in the four corner notches.
  const int corner_preference = DWMWCP_DONOTROUND;
  ::DwmSetWindowAttribute(window_handle_, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));

  // ---- second engine -------------------------------------------------------
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint(kDartEntrypoint);

  std::ostringstream payload;
  payload << "{\"playUrl\":\"" << JsonEscape(play_url) << "\",\"title\":\""
          << JsonEscape(title) << "\",\"channelId\":\""
          << JsonEscape(channel_id) << "\"}";
  project.set_dart_entrypoint_arguments({payload.str()});
  // Same renderer choice as the main window (see runner/main.cpp): Skia is the
  // measured-smoother backend on this project, and a second Impeller instance
  // would double the GPU-side surface cost for a 360x202 window.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);

  RECT client_area = {};
  ::GetClientRect(window_handle_, &client_area);
  controller_ = std::make_unique<flutter::FlutterViewController>(
      client_area.right - client_area.left,
      client_area.bottom - client_area.top, project);
  if (!controller_->engine() || !controller_->view()) {
    HWND window = window_handle_;
    TearDown();
    if (window != nullptr) {
      ::DestroyWindow(window);
    }
    window_handle_ = nullptr;
    return false;
  }

  // Register ONLY media_kit_video (see the comment at the include).
  FlutterDesktopPluginRegistrarRef registrar =
      controller_->engine()->GetRegistrarForPlugin("MediaKitVideoPluginCApi");
  if (registrar != nullptr) {
    MediaKitVideoPluginCApiRegisterWithRegistrar(registrar);
  }

  play_url_ = play_url;
  title_ = title;
  CreateChannel();

  // Parent the Flutter view into the popup window.
  HWND view = controller_->view()->GetNativeWindow();
  ::SetParent(view, window_handle_);
  ::GetClientRect(window_handle_, &client_area);
  ::MoveWindow(view, client_area.left, client_area.top,
               client_area.right - client_area.left,
               client_area.bottom - client_area.top, TRUE);

  // SW_SHOWNOACTIVATE: never steal focus from whatever the user is doing.
  ::ShowWindow(window_handle_, SW_SHOWNOACTIVATE);
  controller_->ForceRedraw();

  // NOTE: playback is started by the "ready" call coming back FROM the second
  // engine (see CreateChannel), not here. Doing it inline would race the Dart
  // side's channel handler registration (platform -> Dart messages sent before
  // a handler exists can be dropped), and waiting for "ready" inside this
  // handler would block the MAIN window's UI for the whole cold start of a
  // second engine.

  return true;
}

void AylaLiveWindowHost::Close(bool notify) {
  HWND window = window_handle_;
  if (window == nullptr) {
    TearDown();
    return;
  }
  // The single notification point is WM_DESTROY (see HandleMessage): every
  // close path funnels through DestroyWindow, so putting it there means "the
  // user clicked it away" and "the app tore the session down" cannot drift.
  suppress_closed_notification_ = !notify;
  // WM_DESTROY runs synchronously: window_handle_ becomes nullptr there.
  ::DestroyWindow(window);
  suppress_closed_notification_ = false;
  TearDown();
}

void AylaLiveWindowHost::RequestClose() {
  // Dart asked for it: no onLiveWindowClosed round-trip.
  suppress_closed_notification_ = true;
  if (window_handle_ != nullptr) {
    // Same thread => the flag is already visible when WM_CLOSE is handled.
    ::PostMessageW(window_handle_, WM_CLOSE, 0, 0);
    return;
  }
  TearDown();
}

void AylaLiveWindowHost::CreateChannel() {
  if (!controller_ || !controller_->engine()) {
    return;
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      controller_->engine()->messenger(), "ayla/desktop_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "ready") {
          // The Dart side is alive and its handler is registered: NOW it is
          // safe to hand it the url (see the note at the end of Show()).
          result->Success(flutter::EncodableValue(true));
          if (channel_ != nullptr) {
            channel_->InvokeMethod(
                "play",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {flutter::EncodableValue("url"),
                     flutter::EncodableValue(play_url_)},
                    {flutter::EncodableValue("title"),
                     flutter::EncodableValue(title_)},
                }));
          }
          return;
        }
        if (method == "close") {
          // Requested by the Dart side (the small window's X button): the Dart
          // side already knows, so no onLiveWindowClosed callback.
          result->Success(flutter::EncodableValue(true));
          RequestClose();
          return;
        }
        if (method == "activateMain") {
          // "click the video => go back to the app": bring the main window back
          // to the foreground and let the main window react to
          // onLiveWindowClosed. The live window then closes itself.
          HWND owner = owner_window_;
          if (owner != nullptr) {
            if (::IsIconic(owner)) {
              ::ShowWindow(owner, SW_RESTORE);
            }
            ::SetForegroundWindow(owner);
            ::PostMessageW(owner, WM_APP + 1, 0, 0);
          }
          // The main window got WM_APP + 1 and will emit onLiveWindowClosed,
          // which is exactly the "go back to the app" signal Dart needs.
          result->Success(flutter::EncodableValue(true));
          RequestClose();
          return;
        }
        result->NotImplemented();
      });
}

void AylaLiveWindowHost::TearDown() {
  // Order is load-bearing: |channel_| holds the engine's messenger, which the
  // controller destroys with the engine. Channel first, controller second.
  channel_.reset();
  controller_.reset();
}

LRESULT CALLBACK AylaLiveWindowHost::WndProc(HWND window,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    auto context = new LiveWindowContext();
    context->host =
        static_cast<AylaLiveWindowHost*>(create_struct->lpCreateParams);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(context));
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
  auto context = reinterpret_cast<LiveWindowContext*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (context == nullptr || context->host == nullptr) {
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
  if (message == WM_NCDESTROY) {
    ::SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    delete context;
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
  return context->host->HandleMessage(window, message, wparam, lparam);
}

LRESULT AylaLiveWindowHost::HandleMessage(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) {
  // Every top-level window that hosts a Flutter view MUST forward its messages
  // to the engine, otherwise keyboard / IME / lifecycle are dead in it.
  if (controller_) {
    std::optional<LRESULT> result =
        controller_->HandleTopLevelWindowProc(window, message, wparam, lparam);
    if (result.has_value()) {
      return *result;
    }
  }

  switch (message) {
    case WM_SIZE: {
      if (controller_ && controller_->view() != nullptr) {
        RECT rect = {};
        ::GetClientRect(window, &rect);
        ::MoveWindow(controller_->view()->GetNativeWindow(), rect.left,
                     rect.top, rect.right - rect.left, rect.bottom - rect.top,
                     TRUE);
      }
      return 0;
    }
    case WM_ACTIVATE:
      if (controller_ && controller_->view() != nullptr) {
        ::SetFocus(controller_->view()->GetNativeWindow());
      }
      return 0;
    case WM_CLOSE:
      // Tear down here (not in WM_DESTROY) so the engine is gone before the
      // window disappears. No PostQuitMessage: the main window owns the loop.
      ::DestroyWindow(window);
      return 0;
    case WM_DESTROY: {
      const bool had_engine = controller_ != nullptr;
      TearDown();
      if (window_handle_ == window) {
        window_handle_ = nullptr;
      }
      // Tell the main window the detached live window is gone (unless it was
      // the one asking): it then re-creates its own player / in-app mini player
      // instead of keeping them suspended forever.
      const bool notify = !suppress_closed_notification_;
      // Reset even on the suppressed path: the flag describes ONE close, and a
      // later user-initiated close must notify again.
      suppress_closed_notification_ = false;
      if (had_engine && notify && owner_window_ != nullptr) {
        ::PostMessageW(owner_window_, WM_APP + 1, 0, 0);
      }
      return 0;
    }
    default:
      break;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
