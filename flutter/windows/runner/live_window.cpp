#include "live_window.h"

#include <dwmapi.h>
#include <windowsx.h>  // GET_X_LPARAM (WM_NCHITTEST hit testing)
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <chrono>
#include <cstdio>
#include <optional>
#include <sstream>

// The vendored media_kit_video is the ONLY plugin the second engine registers.
// Deliberately NOT RegisterPlugins() (that would spin up a second copy of
// flutter_webrtc / livekit / record for an engine that only paints a video).
#include <media_kit_video/media_kit_video_plugin_c_api.h>

namespace {

/// Window class of the detached live mini window (opaque, black backdrop).
constexpr const wchar_t kLiveWindowClass[] = L"AYLA_DETACHED_LIVE_WINDOW";

/// Window class of the detached floating-ball window (per-pixel transparent).
constexpr const wchar_t kBallWindowClass[] = L"AYLA_DETACHED_BALL_WINDOW";

// ---- Detached live mini window geometry (Flutter LOGICAL pixels) -----------
//
// The window hosts the UNCHANGED AylaLiveMiniPlayer: 168 x 94 (live.css 1026),
// plus 10px on every side because its close / detach buttons sit OUTSIDE the
// card (top/right: -10, clipBehavior: Clip.none). The window is per-pixel
// transparent so those 10px really are empty instead of a black frame.
//
// Must stay in sync with lib/widgets/live/live_window_surface.dart
// (kAylaDetachedMiniWindowWidth / Height).
constexpr int kLiveWindowWidth = 194;
constexpr int kLiveWindowHeight = 120;

// ---- Floating-ball window geometry (Flutter LOGICAL pixels) ----------------
//
// The window hosts the UNCHANGED AylaSessionActivityIndicator, and that widget
// positions itself with `Positioned(right: 24, top: 80)` on a wide viewport
// (shell.css:459-471) - it does NOT derive its top from the window height.
// So the host window has to be tall enough to contain top 80 + the 44px balls,
// and the empty band above the balls must be CLICK-THROUGH (see WM_NCHITTEST
// below), otherwise a transparent always-on-top window would swallow clicks on
// whatever sits underneath it (a maximized app's close button lives exactly
// there).
//
// Group width with no detach key = 44 + 8 + 44 + 8 + 28 = 132, plus right 24
// and a little breathing room for the hover glow (scale 1.08) => 176 wide.
constexpr int kBallWindowWidth = 176;

// The ball window is as TALL AS THE WHOLE WORK AREA on purpose.
//
// Why not a snug 176x132 box (the first attempt):
//   * the widget positions itself with `Positioned(top: <px>)` and CLAMPS the
//     drag to `[8, viewportHeight - 44 - 8]`. In a 132-tall viewport that is
//     `[8, 80]` - and on a 176-wide viewport the widget is in its NARROW档
//     (breakpoint is 768) whose default top is 104, i.e. ALREADY outside the
//     clamp range and 16px past the window's bottom edge => the balls get
//     clipped and dragging does nothing at all.
//   * moving the WINDOW on drag does not fix it either: the widget still
//     applies the same clamp to its own coordinate, so the window offset and
//     the in-window offset double-count and the ball runs away from the
//     cursor.
// With a full-height window the widget's own coordinate space IS the screen's
// vertical space: the clamp becomes `[8, workAreaHeight - 52]`, dragging is a
// plain 1:1 follow, and nothing ever leaves the window.
//
// The cost is a large transparent window, which is why WM_NCHITTEST below is
// load-bearing: every pixel that is not the ball/handle group is reported as
// HTTRANSPARENT so clicks reach the app underneath.
constexpr int kBallWindowMinHeight = 132;

// ---- Hit-test geometry of the ball group (Flutter LOGICAL pixels) ----------
//
// The group is 132 x 44 (two 44px balls + 28px handle + two 8px gaps, no detach
// key). The hit band is that rectangle plus a little tolerance for the hover
// glow (scale 1.08 => ~3.5px) and the focus ring (2px outline + 2px offset),
// rounded up generously - a too-small band makes the ball feel "sticky".
constexpr double kBallGroupWidth = 132.0;
constexpr double kBallGroupHeight = 44.0;

// Individual pieces of the group, used for the EXACT (circle/pill) hit test in
// TickBallHit. Keep in sync with session_activity.dart:
//   ballSize = 44, toggleWidth = 28, gap = AylaSpacing.sp2 = 8.
constexpr double kBallSizePx = 44.0;
constexpr double kToggleWidthPx = 28.0;
constexpr double kBallGapPx = 8.0;
constexpr double kBallHitTestPadTop = 12.0;
constexpr double kBallHitTestPadBottom = 12.0;
constexpr double kBallHitTestPadLeft = 12.0;

/// `.session-activity-group { right: 24px }` (shell.css:461) in the wide档 the
/// overlay always uses (see hostViewportWidth on the Dart side).
constexpr double kBallRightInset = 24.0;

/// Timer that polls the cursor against the rects Flutter measured.
/// 16 ms is below the perception threshold; the work is one GetCursorPos plus a
/// few rect comparisons.
constexpr UINT_PTR kHitRectsTimerId = 0xA71C;

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

  /// Timer id used by the floating ball to re-evaluate whether the cursor is
  /// over a clickable part of the overlay (see AylaLiveWindowHost::TickBallHit).
  ///
  /// A timer is REQUIRED rather than WM_MOUSEMOVE: while WS_EX_TRANSPARENT is
  /// set the window receives no mouse messages at all, so it could never notice
  /// the cursor coming back in.
  UINT_PTR hit_timer = 0;
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

// ---- Per-pixel transparency (Windows) --------------------------------------
//
// Flutter's Windows embedder has no "transparent background" switch, so the
// floating-ball window is made see-through the same way the well-known
// flutter_acrylic "transparent" effect does it:
//   1. DwmExtendFrameIntoClientArea with -1 margins: the DWM frame is extended
//      over the WHOLE client area, i.e. the window stops painting an opaque
//      background of its own;
//   2. SetWindowCompositionAttribute(ACCENT_ENABLE_TRANSPARENTGRADIENT) with a
//      fully transparent gradient colour: the (now empty) background composites
//      with whatever is behind the window.
// The Flutter surface is premultiplied-alpha, so transparent pixels in the
// widget tree really do show the desktop.
//
// Both calls are resolved dynamically / are no-ops on older Windows, and a
// failure is NOT fatal: worst case the window keeps an opaque backdrop instead
// of a see-through one.

#ifndef ACCENT_ENABLE_TRANSPARENTGRADIENT
#define ACCENT_ENABLE_TRANSPARENTGRADIENT 2
#endif

struct AccentPolicy {
  int accent_state;
  int accent_flags;
  int gradient_color;
  int animation_id;
};

struct WindowCompositionAttributeData {
  int attribute;
  void* data;
  unsigned long size_of_data;
};

/// WCA_ACCENT_POLICY
constexpr int kWindowCompositionAttributeAccentPolicy = 19;

void EnablePerPixelTransparency(HWND window) {
  // 1. No opaque frame background.
  MARGINS margins = {-1, -1, -1, -1};
  ::DwmExtendFrameIntoClientArea(window, &margins);

  // 2. Background = fully transparent accent.
  HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
  if (user32 == nullptr) {
    return;
  }
  using SetWindowCompositionAttributeFn =
      BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);
  auto set_window_composition_attribute =
      reinterpret_cast<SetWindowCompositionAttributeFn>(
          ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (set_window_composition_attribute == nullptr) {
    return;  // pre-Windows-10 fallback: opaque backdrop, still functional.
  }
  AccentPolicy policy = {ACCENT_ENABLE_TRANSPARENTGRADIENT, 2, 0, 0};
  WindowCompositionAttributeData data = {
      kWindowCompositionAttributeAccentPolicy, &policy, sizeof(policy)};
  set_window_composition_attribute(window, &data);
}

}  // namespace

AylaLiveWindowHost::AylaLiveWindowHost(HWND owner_window, AylaOverlayKind kind)
    : owner_window_(owner_window), kind_(kind) {}

AylaLiveWindowHost::~AylaLiveWindowHost() {
  Close(false);
  TearDown();
}

bool AylaLiveWindowHost::CreateWindowAndEngine(
    const std::string& entrypoint_args,
    int logical_width,
    int logical_height,
    bool transparent,
    bool align_top_right,
    bool fill_work_area_height) {
  // ---- window class (registered lazily, this is the only owner) -------------
  const wchar_t* class_name =
      kind_ == AylaOverlayKind::kActivityBall ? kBallWindowClass
                                              : kLiveWindowClass;
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(WNDCLASSEXW);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = AylaLiveWindowHost::WndProc;
  window_class.cbClsExtra = 0;
  window_class.cbWndExtra = 0;
  window_class.hInstance = instance;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  // A transparent window must NOT paint a background brush at all; the opaque
  // live window keeps the black brush so its very first frames are not garbage.
  window_class.hbrBackground =
      transparent ? nullptr
                  : static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = class_name;
  // Fails with ERROR_CLASS_ALREADY_EXISTS on re-open; that is fine.
  ::RegisterClassExW(&window_class);

  // ---- position ------------------------------------------------------------
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
  const int window_width = static_cast<int>(logical_width * scale);
  logical_width_ = logical_width;

  int window_x = 0;
  int window_y = 0;
  int window_height = 0;
  if (fill_work_area_height) {
    // Full work-area height: the widget's own `Positioned(top:)` coordinate
    // space then equals the screen's vertical space (see kBallWindowMinHeight).
    window_height = work_area.bottom - work_area.top;
    window_x = work_area.right - window_width;
    window_y = work_area.top;
  } else {
    window_height = static_cast<int>(logical_height * scale);
  }

  if (align_top_right) {
    // The floating ball lives at the top-right corner of the work area. Its
    // right edge coincides with the work-area right edge because the widget
    // itself keeps a 24px inset and slides the last 24px right when collapsed
    // (that is what "the handle sticks to the screen edge" means in-app).
    window_x = work_area.right - window_width;
    window_y = work_area.top;
  } else {
    const int margin = static_cast<int>(kLiveWindowMargin * scale);
    window_x = work_area.right - window_width - margin;
    window_y = work_area.bottom - window_height - margin;
  }

  // WS_POPUP            : no title bar / border (the overlay draws its own).
  // WS_CLIPCHILDREN     : the Flutter view is a child HWND; don't paint over it.
  // WS_CLIPSIBLINGS     : same, for sibling ordering.
  // WS_EX_TOPMOST       : stays above other apps (that is the whole point).
  // WS_EX_TOOLWINDOW    : keeps it out of Alt-Tab and the taskbar.
  // WS_EX_NOACTIVATE    : (ball only) clicking the overlay must not steal focus
  //                       from whatever the user is typing in.
  DWORD ex_style = WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
  if (kind_ == AylaOverlayKind::kActivityBall) {
    ex_style |= WS_EX_NOACTIVATE;
  }
  window_handle_ = ::CreateWindowExW(
      ex_style, class_name, L"", WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
      window_x, window_y, window_width, window_height, nullptr, nullptr,
      instance, this);
  if (window_handle_ == nullptr) {
    return false;
  }

  // Square corners: a borderless always-on-top window with Win11 rounding shows
  // the desktop colour in the four corner notches.
  const int corner_preference = DWMWCP_DONOTROUND;
  ::DwmSetWindowAttribute(window_handle_, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));

  if (transparent) {
    EnablePerPixelTransparency(window_handle_);
  }

  // ---- second engine -------------------------------------------------------
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint(kDartEntrypoint);
  project.set_dart_entrypoint_arguments({entrypoint_args});
  // Same renderer choice as the main window (see runner/main.cpp): Skia is the
  // measured-smoother backend on this project, and a second Impeller instance
  // would double the GPU-side surface cost for a small overlay.
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

  if (kind_ == AylaOverlayKind::kActivityBall) {
    // The window is click-through until Flutter reports the button rects; poll
    // the cursor so a transparent window can become interactive again (while
    // transparent it receives no mouse messages at all).
    ::SetTimer(window_handle_, kHitRectsTimerId, 16, nullptr);
  }


  // NOTE: playback / the first payload are handed over by the "ready" call
  // coming back FROM the second engine (see CreateChannel), not here. Doing it
  // inline would race the Dart side's channel handler registration
  // (platform -> Dart messages sent before a handler exists can be dropped),
  // and waiting for "ready" inside this handler would block the MAIN window's
  // UI for the whole cold start of a second engine.

  return true;
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

  play_url_ = play_url;
  title_ = title;

  std::ostringstream payload;
  payload << "{\"kind\":\"liveMini\",\"playUrl\":\"" << JsonEscape(play_url)
          << "\",\"title\":\"" << JsonEscape(title) << "\",\"channelId\":\""
          << JsonEscape(channel_id) << "\"}";

  return CreateWindowAndEngine(payload.str(), kLiveWindowWidth,
                               kLiveWindowHeight, /*transparent=*/true,
                               /*align_top_right=*/false);
}

bool AylaLiveWindowHost::ShowBall(const std::string& payload_json) {
  overlay_payload_ = payload_json;
  // Already up => this is a plain state push (the main engine pushes on every
  // change of the session set), not a re-creation.
  if (window_handle_ != nullptr && controller_ != nullptr) {
    ForwardToEngine("ballPayload", overlay_payload_);
    return true;
  }
  if (window_handle_ != nullptr || controller_ != nullptr) {
    Close(false);
  }

  std::ostringstream entrypoint;
  entrypoint << "{\"kind\":\"activityBall\",\"payload\":"
             << (payload_json.empty() ? "{}" : payload_json) << "}";

  // The window is as tall as the work area (see kBallWindowMinHeight) so the
  // widget's own drag clamp covers the whole screen and no window movement is
  // needed while dragging.
  return CreateWindowAndEngine(entrypoint.str(), kBallWindowWidth,
                               kBallWindowMinHeight, /*transparent=*/true,
                               /*align_top_right=*/true,
                               /*fill_work_area_height=*/true);
}

bool AylaLiveWindowHost::UpdateBall(const std::string& payload_json) {
  overlay_payload_ = payload_json;
  if (window_handle_ == nullptr || controller_ == nullptr) {
    return false;
  }
  ForwardToEngine("ballPayload", overlay_payload_);
  return true;
}

void AylaLiveWindowHost::ForwardToEngine(const char* method,
                                         const std::string& payload) {
  if (channel_ == nullptr) {
    return;
  }
  channel_->InvokeMethod(
      method,
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("payload"), flutter::EncodableValue(payload)},
      }));
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
  // Dart asked for it: no close round-trip.
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
          // safe to hand it the initial state (see the note at the end of
          // CreateWindowAndEngine).
          result->Success(flutter::EncodableValue(true));
          if (kind_ == AylaOverlayKind::kActivityBall) {
            ForwardToEngine("ballPayload", overlay_payload_);
          } else if (channel_ != nullptr) {
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
          // Requested by the Dart side (the overlay's own X button): the Dart
          // side already knows, so no close callback.
          result->Success(flutter::EncodableValue(true));
          RequestClose();
          return;
        }
        if (method == "activateMain") {
          // "click the video => go back to the app": bring the main window back
          // to the foreground and let the main window react to the close
          // notification. The overlay window then closes itself.
          HWND owner = owner_window_;
          if (owner != nullptr) {
            if (::IsIconic(owner)) {
              ::ShowWindow(owner, SW_RESTORE);
            }
            ::SetForegroundWindow(owner);
            ::PostMessageW(owner, WM_APP + 1, 0, 0);
          }
          result->Success(flutter::EncodableValue(true));
          RequestClose();
          return;
        }
        if (method == "ballTap") {
          // "click the floating ball => go back to that session". The main
          // engine owns routing, so hand it the (kind, sourceRoute) pair and
          // let it navigate; the overlay window itself stays open.
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto read = [args](const char* key) -> std::string {
              auto it = args->find(flutter::EncodableValue(key));
              if (it == args->end()) {
                return std::string();
              }
              const auto* value = std::get_if<std::string>(&it->second);
              return value != nullptr ? *value : std::string();
            };
            ball_tap_kind_ = read("kind");
            ball_tap_route_ = read("sourceRoute");
            ball_tap_pending_ = true;
          }
          result->Success(flutter::EncodableValue(true));
          if (owner_window_ != nullptr) {
            if (::IsIconic(owner_window_)) {
              ::ShowWindow(owner_window_, SW_RESTORE);
            }
            ::SetForegroundWindow(owner_window_);
            // WM_APP + 2 = "the user clicked the floating ball" (see
            // flutter_window.cpp). The window stays open on purpose.
            ::PostMessageW(owner_window_, WM_APP + 2, 0, 0);
          }
          return;
        }
        if (method == "setHitRects") {
          // Flutter measured the visible buttons with RenderBox and sent their
          // exact rectangles (logical px, view coordinates). TickHitRects polls
          // the cursor against these to decide whether the window should accept
          // the mouse. No layout knowledge is duplicated here on purpose.
          ball_hit_rects_.clear();
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("rects"));
            if (it != args->end()) {
              const auto* list = std::get_if<flutter::EncodableList>(&it->second);
              if (list != nullptr) {
                for (const flutter::EncodableValue& entry : *list) {
                  const auto* m = std::get_if<flutter::EncodableMap>(&entry);
                  if (m == nullptr) continue;
                  auto num = [m](const char* key) -> double {
                    auto f = m->find(flutter::EncodableValue(key));
                    if (f == m->end()) return 0.0;
                    if (const auto* d = std::get_if<double>(&f->second)) return *d;
                    if (const auto* i = std::get_if<int32_t>(&f->second))
                      return static_cast<double>(*i);
                    if (const auto* l = std::get_if<int64_t>(&f->second))
                      return static_cast<double>(*l);
                    return 0.0;
                  };
                  RECT r = {};
                  r.left = static_cast<LONG>(num("left"));
                  r.top = static_cast<LONG>(num("top"));
                  r.right = static_cast<LONG>(num("right"));
                  r.bottom = static_cast<LONG>(num("bottom"));
                  ball_hit_rects_.push_back(r);
                }
              }
            }
          }
          TickHitRects();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "setBallGroupTop") {
          // The Dart side reports where the ball group currently sits inside
          // this (full-height) window, in logical pixels from the top. Only
          // WM_NCHITTEST consumes it - the window itself never moves while
          // dragging, because the widget's own coordinate space already
          // covers the whole screen (see kBallWindowMinHeight).
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto it = args->find(flutter::EncodableValue("top"));
            if (it != args->end()) {
              const auto* as_double = std::get_if<double>(&it->second);
              const auto* as_int = std::get_if<int32_t>(&it->second);
              const auto* as_long = std::get_if<int64_t>(&it->second);
              if (as_double != nullptr) {
                ball_group_top_ = *as_double;
              } else if (as_int != nullptr) {
                ball_group_top_ = static_cast<double>(*as_int);
              } else if (as_long != nullptr) {
                ball_group_top_ = static_cast<double>(*as_long);
              }
            }
          }
          result->Success(flutter::EncodableValue(true));
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

/// Applies the interactive/click-through state of the floating-ball window.
///
/// `interactive == true`  -> the window accepts mouse input (buttons work)
/// `interactive == false` -> the whole window is skipped by hit testing, so
///                           clicks reach whatever application is underneath
///                           (cross-process; this is the only mechanism that
///                           does that, HTTRANSPARENT stays in-process).
///
/// Implementation notes that cost this project a lot of time:
///   * WS_EX_TRANSPARENT only reroutes input for a LAYERED window; on a plain
///     window Windows still treats it as an opaque rectangle. Hence WS_EX_LAYERED
///     plus SetLayeredWindowAttributes(0, 255, LWA_ALPHA) - full opacity, so the
///     visuals are untouched.
///   * The flag is all-or-nothing per window, so the DECISION cannot come from
///     the window itself: once transparent it receives no mouse messages at all
///     and could never notice the cursor coming back. A timer polls the cursor
///     against the rects Flutter measured (see TickHitRects).
void AylaLiveWindowHost::SetBallInteractive(bool interactive) {
  if (window_handle_ == nullptr || kind_ != AylaOverlayKind::kActivityBall) {
    return;
  }
  if (interactive == ball_interactive_) {
    return;
  }
  ball_interactive_ = interactive;

  LONG ex = ::GetWindowLong(window_handle_, GWL_EXSTYLE);
  ex |= WS_EX_LAYERED;
  if (interactive) {
    ex &= ~WS_EX_TRANSPARENT;
  } else {
    ex |= WS_EX_TRANSPARENT;
  }
  ::SetWindowLong(window_handle_, GWL_EXSTYLE, ex);
  ::SetLayeredWindowAttributes(window_handle_, 0, 255, LWA_ALPHA);
  ::SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
}

/// Polls the cursor against the rects Flutter measured and flips the click-through
/// state accordingly.
///
/// This has to be a timer: while the window is click-through it receives no mouse
/// messages, so there is no event to react to. 16 ms is below the perception
/// threshold and the work is one GetCursorPos + a handful of rect comparisons.
void AylaLiveWindowHost::TickHitRects() {
  if (window_handle_ == nullptr || kind_ != AylaOverlayKind::kActivityBall) {
    return;
  }
  POINT cursor = {};
  if (!::GetCursorPos(&cursor)) {
    return;
  }
  ::ScreenToClient(window_handle_, &cursor);

  // The rects arrive in the SECOND ENGINE's logical pixels; convert the cursor
  // to the same space (the window's client origin is where that view starts).
  const UINT dpi = FlutterDesktopGetDpiForHWND(window_handle_);
  const double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;
  const double cx = static_cast<double>(cursor.x) / scale;
  const double cy = static_cast<double>(cursor.y) / scale;

  bool over = false;
  for (const RECT& r : ball_hit_rects_) {
    if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
      over = true;
      break;
    }
  }
  SetBallInteractive(over);
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
    case WM_NCHITTEST: {
      if (kind_ != AylaOverlayKind::kActivityBall) {
        break;  // the live window is fully opaque and fully clickable.
      }
      // The floating-ball window covers the WHOLE work area but only a small
      // group (44px balls + 28px handle, ~132 x 44 logical px at the right
      // edge) is real content. Everything else is transparent empty space and
      // MUST NOT swallow clicks meant for the app underneath - which includes
      // a maximized app's close button at the top-right corner.
      //
      // HTTRANSPARENT makes Windows skip this window and keep hit-testing
      // whatever is below it.
      const LRESULT base = ::DefWindowProcW(window, message, wparam, lparam);
      if (base != HTCLIENT) {
        return base;  // borders / caption still belong to us.
      }
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ::ScreenToClient(window, &point);
      RECT client = {};
      ::GetClientRect(window, &client);
      const UINT dpi = FlutterDesktopGetDpiForHWND(window);
      const double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;

      // The group band: from the group's current top (reported by Dart on
      // every drag) down by one group height, plus a few px of tolerance for
      // the hover glow (scale 1.08) and the focus ring.
      const LONG band_top =
          static_cast<LONG>((ball_group_top_ - kBallHitTestPadTop) * scale);
      const LONG band_bottom = static_cast<LONG>(
          (ball_group_top_ + kBallGroupHeight + kBallHitTestPadBottom) * scale);
      // ... and only the rightmost slice of the window is content at all.
      //
      // The widget keeps `right: 24` (wide档, shell.css:461) and slides the
      // group right by another 24 when collapsed, so the group occupies
      //   expanded : [W-24-132, W-24]
      //   collapsed: [W-132,    W]
      // => the leftmost content edge is W-24-132. Subtracting only the pad
      // (and NOT the 24 inset) is deliberate: it covers both states with one
      // band and leaves a few px of slack for the hover glow.
      const LONG band_left = static_cast<LONG>(
          (static_cast<double>(logical_width_) - kBallGroupWidth -
           kBallHitTestPadLeft) *
          scale) -
                          static_cast<LONG>(kBallRightInset * scale);

      const bool in_band = point.y >= band_top && point.y < band_bottom &&
                           point.x >= band_left;
      return in_band ? HTCLIENT : HTTRANSPARENT;
    }
    case WM_TIMER: {
      if (wparam == kHitRectsTimerId &&
          kind_ == AylaOverlayKind::kActivityBall) {
        TickHitRects();
      }
      return 0;
    }
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
      if (kind_ != AylaOverlayKind::kActivityBall && controller_ &&
          controller_->view() != nullptr) {
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
      // Tell the main window the overlay is gone (unless it was the one
      // asking): it then re-creates its own presentation instead of keeping
      // them suspended forever.
      const bool notify = !suppress_closed_notification_;
      // Reset even on the suppressed path: the flag describes ONE close, and a
      // later user-initiated close must notify again.
      suppress_closed_notification_ = false;
      if (had_engine && notify && owner_window_ != nullptr) {
        // WM_APP + 1 = live mini window closed, WM_APP + 3 = ball window
        // closed (see flutter_window.cpp).
        const UINT notification =
            kind_ == AylaOverlayKind::kActivityBall ? WM_APP + 3 : WM_APP + 1;
        ::PostMessageW(owner_window_, notification, 0, 0);
      }
      return 0;
    }
    default:
      break;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
