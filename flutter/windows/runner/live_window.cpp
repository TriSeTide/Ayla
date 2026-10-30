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

// The ball window is EXACTLY the size of the ball group: 176 x 132 logical px.
//
// Why the window is this small (and why that IS the click-through story):
//   * the Flutter Windows embedder has NO transparent-background mode - its DXGI
//     swapchain carries no alpha - so a large "transparent" window shows PURE BLACK
//     wherever Flutter did not paint;
//   * Microsoft Layered-Windows docs make LWA_COLORKEY a per-pixel match against
//     one exact colour, which black can never satisfy => that black slab eats clicks;
//   * SetWindowRgn crops to rectangles only, so a round ball plus its glow can never
//     fit and the empty corners still swallow clicks ("collapsed into a box").
//
// A window only as big as the group needs none of that: outside it there is no
// window of ours, so input reaches whatever is underneath - for ANY process.
//
// The window travels with the group while dragging (MoveBallWindowToGroupTop), so
// the group always sits at the same spot INSIDE the window.
constexpr int kBallWindowMinHeight = 132;

/// Slack above the ball group inside the ball-sized window (hover glow at scale
/// 1.08 plus the 2px focus ring). The widget positions the group with
/// `Positioned(top: 0)` inside this window, so the window's top edge is the
/// group's top edge minus this pad.
constexpr int kBallWindowPadTop = 8;

/// Design resting position of the ball group: `top: 80px` (shell.css:462) in the
/// wide档 the overlay always uses. Only used for the window's INITIAL placement;
/// after that Dart reports the real top on every drag (setBallGroupTop).
constexpr int kBallDefaultGroupTop = 80;

// ---- Ball geometry constants are gone on purpose ---------------------------
//
// Earlier revisions kept the group size plus hover-glow/focus-ring padding as
// explicit constants and fed them to SetWindowRgn / WM_NCHITTEST / a colour key.
// None of that exists any more: the window IS the group, so there is nothing to
// compute and no hit test to fake.

/// Distance from the work-area right/bottom edge.
constexpr int kLiveWindowMargin = 24;

// ---- Live mini window: native drag / edge resize (2026-11-01 user request) --
//
// «希望改成能拖动到任意位置的小窗，并且鼠标放在小窗边缘可以调节小窗大小»
//
// Both are handed to the OS instead of the Dart side on purpose: AylaLiveMiniPlayer
// is an EXISTING component the user forbade rewriting, and a WS_POPUP window has
// no non-client area for the user to grab, so the window procedure fakes one
// (WM_NCHITTEST -> HTCAPTION / HTLEFT / ...). Sizing therefore goes through the
// normal modal resize loop, which also gives the user the standard resize cursors.
//
// The window is created with the "resizable popup" recipe:
//     WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN | WS_CLIPSIBLINGS
// WS_THICKFRAME on a WS_POPUP window adds the resize frame WITHOUT any caption or
// menu bar. WS_CAPTION (== WS_BORDER | WS_DLGFRAME) is deliberately NOT requested
// - it is what would draw a title bar.
constexpr DWORD kResizablePopupStyle = static_cast<DWORD>(
    WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);

/// Logical (unscaled) size of the client area the Flutter view was built for; the
/// "minimum" of the resize band is enforced as "never smaller than this", which
/// keeps the hosted widget's layout at exactly the size it was designed for.
constexpr int kLiveWindowLogicalWidth = 194;   // == kLiveWindowWidth
constexpr int kLiveWindowLogicalHeight = 120;  // == kLiveWindowHeight

/// Logical thickness of the invisible resize band around the client area
/// (task-8 asked for 6-8px; 6 is used so the band cannot swallow the 24px close
/// button that sits OUTSIDE the card at top/right -10).
constexpr double kResizeBorderThickness = 6.0;

/// Where the live window pushes its client size on every WM_SIZE, in physical
/// pixels (the embedded Flutter view is resized in WM_SIZE; see the note there).
constexpr UINT kDetachedClientSizeMessage = WM_APP + 4;

/// Thickness of the invisible native drag band at the top of the live mini window
/// (logical px).
///
/// 6 is the smaller end of the range the task asked for (6-8) ON PURPOSE: the
/// hosted widget draws its 24x24 close button OUTSIDE the card, at
/// top/right = -10 (live_mini_player.dart:267-274), so inside the client area the
/// button occupies only y in [0, 14). A thicker band would turn half of that
/// button into "drag the window". The close button's 24x24 box (+2px of margin)
/// is additionally carved OUT of the band in LiveHitTest(), so it stays fully
/// clickable no matter what this value is.
constexpr double kCaptionBandHeight = 6.0;

/// Size + inset of the hosted widget's close button in LOGICAL px, used to keep it
/// out of the caption band / out of nothing else.
///
/// Source of truth: lib/widgets/live/live_mini_player.dart:267-274
/// (Positioned(top: -10, right: -10) + _MiniCloseButton's 24x24 Container).
constexpr double kAylaMiniCloseSize = 24.0;
constexpr double kAylaMiniCloseInset = 10.0;

/// How far the mouse may move (physical px) with the button down before a press
/// that started on HTCLIENT is re-classified as a window drag.
constexpr int kDragThreshold = 3;

/// Per-window state attached through GWLP_USERDATA (WM_NCCREATE wires |host|).
struct LiveWindowContext {
  AylaLiveWindowHost* host = nullptr;

  /// Manual window drag (see kClientDragHit). Only used by the live window.
  ///
  /// dragging    = pressed inside the client area, threshold not reached yet
  ///               (=> still a click for the Flutter surface);
  /// drag_moving = threshold passed => the window is following the mouse.
  bool dragging = false;
  bool drag_moving = false;

  /// Cursor position (SCREEN physical px) when the move started.
  POINT drag_origin = {};

  /// Window rect when the move started.
  RECT drag_rect = {};

  /// Number of synthetic WM_LBUTTONDOWN/WM_LBUTTONUP messages this window has
  /// queued for itself (see the re-dispatch note in HandleMessage).
  ///
  /// Without it the re-dispatched pair would be swallowed AGAIN by the very same
  /// "start of a drag" branch, which would queue yet another pair: an endless
  /// PostMessage ping-pong that would freeze the overlay's input.
  int pending_synthetic_clicks = 0;
};

/// Device pixels per Flutter logical pixel for |window|.
double ScaleForWindow(HWND window) {
  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  return dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;
}

// ---- Floating-ball window: the click-through band (shared by region + hit test) ----
//
// ONE definition feeds BOTH SetWindowRgn and WM_NCHITTEST so the two can never
// disagree: whatever the region keeps is exactly what the hit test calls content.
//
// The widget keeps `right: 24px` (wide档, shell.css:461) and slides the group right
// by another 24 when collapsed, so inside a 176-wide window the group occupies
//     expanded : [176-24-132, 176-24] = [20,  152]
//     collapsed: [176-132,    176]     = [44,  176]
// => the union is [20, 176] and the RIGHT edge is the window edge. The widest single
// band is therefore [W-24-132, W] - one band covering both states, which is exactly
// what the task asked for ("region 固定为最宽的那一档，避免收起动画期间丢点击").
//
// The band is also padded for the hover glow (scale 1.08 => ~3.5px) and the focus
// ring (2px outline + 2px offset), otherwise the ball feels sticky at its edges.
//
// The vertical extent is a parameter (not derived inside) so the region and the
// hit test can be given the exact same numbers by their single shared caller.

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
    // The floating ball hugs the right edge of the work area (the widget keeps
    // its own 24px inset inside the window).
    window_x = work_area.right - window_width;
    // Vertically the window must start where the widget will PAINT the group:
    // the design default is `top: 80px` (shell.css:462) measured from the top of
    // the work area, and the widget leaves kBallWindowPadTop of glow slack above
    // it inside the window. Landing on work_area.top would put the group 80px too
    // high until the first drag reports its real position.
    window_y =
        work_area.top + static_cast<int>(kBallDefaultGroupTop * scale) -
        static_cast<int>(kBallWindowPadTop * scale);
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
  // NOTE: no WS_EX_LAYERED. The ball window is exactly the size of the ball
  // group, so there is nothing to make transparent: outside it there is no
  // window of ours, and clicks reach the app underneath by definition.
  DWORD ex_style = WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
  if (kind_ == AylaOverlayKind::kActivityBall) {
    ex_style |= WS_EX_NOACTIVATE;
  }
  // The live mini window is created as a RESIZABLE popup (see kResizablePopupStyle):
  // WS_THICKFRAME gives the user a real grab band for edge-resizing while WS_POPUP
  // keeps the window free of any title bar. The floating ball stays a plain
  // non-resizable popup - it must never look like a window at all.
  const DWORD style = kind_ == AylaOverlayKind::kActivityBall
                          ? static_cast<DWORD>(WS_POPUP | WS_CLIPCHILDREN |
                                               WS_CLIPSIBLINGS)
                          : kResizablePopupStyle;
  window_handle_ =
      ::CreateWindowExW(ex_style, class_name, L"", style, window_x, window_y,
                        window_width, window_height, nullptr, nullptr,
                        instance, this);
  if (window_handle_ == nullptr) {
    return false;
  }

  // Square corners: a borderless always-on-top window with Win11 rounding shows
  // the desktop colour in the four corner notches.
  const int corner_preference = DWMWCP_DONOTROUND;
  ::DwmSetWindowAttribute(window_handle_, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));

  if (kind_ == AylaOverlayKind::kActivityBall) {
    // The ball window is EXACTLY the size of the ball group, so there is nothing
    // to make transparent and nothing to punch through: outside this window
    // there is simply no window of ours at all, and Windows routes the click
    // straight to whatever application is underneath - including other
    // processes. No colour key, no DWM alpha, no window region.
    //
    // This replaces three failed attempts, all of which the user rejected:
    //   * WM_NCHITTEST -> HTTRANSPARENT: only skips to the next window on the
    //     SAME thread, so a click over another process was still eaten;
    //   * SetWindowRgn: crops the window to a RECTANGLE - a round ball plus its
    //     glow can never fit, so it looked like "the window just collapsed into
    //     a box" and the empty corners still swallowed clicks;
    //   * WS_EX_LAYERED + LWA_COLORKEY over a full-work-area window: the Flutter
    //     Windows embedder has NO transparent-background mode (its DXGI swapchain
    //     has no alpha), so every unpainted pixel is pure BLACK, and black can
    //     never equal the colour key => the black slab ate every click. That black
    //     slab is exactly what the user saw.
    //
    // The window keeps a plain opaque backdrop, but it is fully covered by the
    // Flutter surface (the widget paints the whole 176x132 area), so nothing of
    // it is ever visible.
  } else {
    if (transparent) {
      EnablePerPixelTransparency(window_handle_);
    }
    // WS_THICKFRAME changes how the requested width/height map to the CLIENT area
    // (CreateWindowEx sizes the WINDOW rect, and the resize frame now eats a few px
    // per side), but the hosted widget was laid out for exactly
    // kLiveWindowWidth x kLiveWindowHeight logical px. Pin the client size back to
    // that so the second engine's view starts at its designed geometry.
    RECT pin = {0, 0, window_width, window_height};
    ::AdjustWindowRectEx(&pin, style, FALSE, ex_style);
    ::SetWindowPos(window_handle_, nullptr, window_x, window_y,
                   pin.right - pin.left, pin.bottom - pin.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
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

  // Geometry the Dart host needs: the widget lays itself out in SCREEN
  // coordinates (so its own drag clamp covers the whole screen) and then a
  // Transform maps that into this small window.
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
  const UINT monitor_dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double monitor_scale =
      monitor_dpi > 0 ? (static_cast<double>(monitor_dpi) / 96.0) : 1.0;
  const double work_w =
      static_cast<double>(work_area.right - work_area.left) / monitor_scale;
  const double work_h =
      static_cast<double>(work_area.bottom - work_area.top) / monitor_scale;
  // Window origin in SCREEN logical px (the window hugs the right edge and the
  // group's first resting position is the design default top: 80px, shell.css:462).
  const double win_x = work_w - static_cast<double>(kBallWindowWidth);
  const double win_y = 0.0;

  std::ostringstream entrypoint;
  entrypoint << "{\"kind\":\"activityBall\",\"payload\":"
             << (payload_json.empty() ? "{}" : payload_json) << ","
             << "\"viewportWidth\":" << work_w << ","
             << "\"viewportHeight\":" << work_h << ","
             << "\"windowRect\":{\"left\":" << win_x
             << ",\"top\":" << win_y
             << ",\"width\":" << kBallWindowWidth
             << ",\"height\":" << kBallWindowMinHeight << "}}";

  // ⚠️ 2026-11-01 重做（用户：「为什么人家是一个按钮能直接丢出来，
  // 你却要创建一个透明窗口？」）—— 窗口**只包住球组**。
  //
  // 为什么这条路才是对的（微软文档 + Flutter embedder 事实）：
  //   1. Flutter Windows embedder 的 DXGI swapchain **没有 alpha 模式**
  //      （flutter_windows.h 没有任何透明度开关），所以「大透明窗口」里
  //      凡是 Flutter 没画到的像素必然是**纯黑**——这就是用户截图里的黑底。
  //   2. 微软文档（Window Features / Layered Windows）说明：SetLayeredWindowAttributes
  //      的 LWA_COLORKEY 只在像素**精确等于** key 色时才穿孔，黑(0,0,0) 与
  //      key(1,2,3) 永不相等 ⇒ 整块黑底吃掉所有点击。
  //   3. 两者的前提（要透明 vs 要穿透）互相排斥，无论怎么调参数都是错的。
  //
  // 正解：**窗口本身就只有球组那么大**。窗口之外根本不存在矩形 ⇒ 天然穿透；
  // 没有黑底（窗口内只有球组被 Flutter 画满）；也不需要颜色键或 DWM 透明。
  // 拖动由原生跟随（`setBallGroupTop` → 移动窗口），组件坐标经 Transform 映射。
  return CreateWindowAndEngine(entrypoint.str(), kBallWindowWidth,
                               kBallWindowMinHeight, /*transparent=*/false,
                               /*align_top_right=*/true,
                               /*fill_work_area_height=*/false);
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
        if (method == "setBallGroupTop") {
          // The Dart side reports the ball group's new top (SCREEN logical px).
          //
          // The window is now exactly the size of the ball group, so this is what
          // MOVES THE WINDOW: the ball stays at a fixed place *inside* the window
          // and the window travels with it. That is the whole trick - no
          // transparent backdrop, no hit-test region, no colour key.
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
              MoveBallWindowToGroupTop();
            }
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });
}

void AylaLiveWindowHost::MoveBallWindowToGroupTop() {
  if (window_handle_ == nullptr) {
    return;
  }
  if (kind_ != AylaOverlayKind::kActivityBall) {
    return;
  }

  // Work area of whatever monitor the window is currently on (multi-monitor safe).
  HMONITOR monitor = ::MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(MONITORINFO);
  RECT work_area = {};
  if (::GetMonitorInfoW(monitor, &monitor_info)) {
    work_area = monitor_info.rcWork;
  } else {
    ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  }
  const UINT dpi = FlutterDesktopGetDpiForHWND(window_handle_);
  const double scale = dpi > 0 ? (static_cast<double>(dpi) / 96.0) : 1.0;

  // The widget keeps a small pad above the group (hover glow + focus ring), so
  // the window's top edge is the group's top minus that pad - the value Dart
  // reports is the GROUP's top, not the window's.
  const double group_top_px = ball_group_top_ * scale - kBallWindowPadTop * scale;
  int y = work_area.top + static_cast<int>(group_top_px);
  const int max_y = work_area.bottom - kBallWindowMinHeight;
  if (y > max_y) {
    y = max_y;
  }
  if (y < work_area.top) {
    y = work_area.top;
  }
  const int x = work_area.right - kBallWindowWidth;

  // SWP_NOSIZE keeps the client geometry the Flutter view was laid out for;
  // SWP_NOACTIVATE so dragging the ball never steals focus from the app the user
  // is typing in.
  ::SetWindowPos(window_handle_, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
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

  // ---- manual window drag (live mini window only) -------------------------
  //
  // Why not HTCAPTION (the obvious way to get a draggable WS_POPUP window): a
  // caption drag runs in a MODAL message loop owned by DefWindowProc, so the
  // Flutter view inside the window NEVER sees the press - "click the mini player
  // to go back to the room" and its close button would stop working.
  //
  // So the drag is done by hand: the press is swallowed (the surface must not see
  // a button-down it will never get a matching up for), the window only starts
  // moving once the mouse passes [kDragThreshold], and a release below that
  // threshold is re-dispatched as a synthetic press+release pair so the surface's
  // own click handlers keep working exactly as before.
  if (kind_ != AylaOverlayKind::kActivityBall) {
    if (message == WM_LBUTTONDOWN) {
      auto context = reinterpret_cast<LiveWindowContext*>(
          ::GetWindowLongPtrW(window, GWLP_USERDATA));
      if (context != nullptr && context->pending_synthetic_clicks > 0) {
        // Our own re-dispatched click: it must reach the Flutter surface, so it
        // is forwarded WITHOUT starting a new drag session.
        --context->pending_synthetic_clicks;
        return ::DefWindowProcW(window, message, wparam, lparam);
      }
      if (context != nullptr) {
        POINT cursor = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ::ClientToScreen(window, &cursor);
        context->dragging = true;
        context->drag_moving = false;
        context->drag_origin = cursor;
        ::GetWindowRect(window, &context->drag_rect);
        ::SetCapture(window);
        return 0;
      }
    } else if (message == WM_MOUSEMOVE) {
      auto context = reinterpret_cast<LiveWindowContext*>(
          ::GetWindowLongPtrW(window, GWLP_USERDATA));
      if (context != nullptr && context->dragging) {
        POINT cursor = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ::ClientToScreen(window, &cursor);
        const int dx = cursor.x - context->drag_origin.x;
        const int dy = cursor.y - context->drag_origin.y;
        if (!context->drag_moving &&
            (dx * dx + dy * dy) >= kDragThreshold * kDragThreshold) {
          context->drag_moving = true;
        }
        if (context->drag_moving) {
          ::MoveWindow(window, context->drag_rect.left + dx,
                       context->drag_rect.top + dy,
                       context->drag_rect.right - context->drag_rect.left,
                       context->drag_rect.bottom - context->drag_rect.top,
                       TRUE);
        }
        return 0;
      }
    } else if (message == WM_LBUTTONUP) {
      auto context = reinterpret_cast<LiveWindowContext*>(
          ::GetWindowLongPtrW(window, GWLP_USERDATA));
      if (context != nullptr && !context->dragging &&
          context->pending_synthetic_clicks == 0) {
        // Nothing was swallowed => this is an ordinary release; let the surface
        // have it. (`return DefWindowProc` == the `break` this block would do if
        // it were inside the switch below - `break` is illegal in this if-chain.)
        return ::DefWindowProcW(window, message, wparam, lparam);
      }
      if (context != nullptr && context->dragging) {
        const bool moved = context->drag_moving;
        context->dragging = false;
        context->drag_moving = false;
        ::ReleaseCapture();
        if (moved) {
          return 0;  // end of a drag: not a click
        }
        // Not a drag => hand the press/release pair to the Flutter surface. Both
        // messages were swallowed above, so synthesize them at the same position.
        context->pending_synthetic_clicks += 1;
        const LPARAM point = lparam;
        ::PostMessageW(window, WM_LBUTTONDOWN, wparam, point);
        ::PostMessageW(window, WM_LBUTTONUP, wparam, point);
        return 0;
      }
    } else if (message == WM_CAPTURECHANGED) {
      auto context = reinterpret_cast<LiveWindowContext*>(
          ::GetWindowLongPtrW(window, GWLP_USERDATA));
      if (context != nullptr) {
        context->dragging = false;
        context->drag_moving = false;
      }
      return 0;
    }
  }

  switch (message) {
    case WM_NCHITTEST: {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (kind_ == AylaOverlayKind::kActivityBall) {
        // The whole window IS the ball group, so every point inside it belongs
        // to us - there is no empty area to pass through. Click-through happens
        // at a much simpler level: the window is only as big as the group, so
        // the desktop outside it is not ours at all.
        break;
      }

      // ---- live mini window: fake non-client area -> OS drag / resize --------
      //
      // A WS_POPUP window has no frame, so the user has nothing to grab. The
      // window procedure reports the standard non-client hit codes and Windows
      // runs its own (modal) move loop / resize loop for us - which is also what
      // gives the correct resize cursors.
      RECT window_rect = {};
      ::GetWindowRect(window, &window_rect);
      const double scale = ScaleForWindow(window);
      const LONG resize = static_cast<LONG>(kResizeBorderThickness * scale);
      const bool at_left = point.x < window_rect.left + resize;
      const bool at_right = point.x >= window_rect.right - resize;
      const bool at_top = point.y < window_rect.top + resize;
      const bool at_bottom = point.y >= window_rect.bottom - resize;
      if (at_top && at_left) {
        return HTTOPLEFT;
      }
      if (at_top && at_right) {
        return HTTOPRIGHT;
      }
      if (at_bottom && at_left) {
        return HTBOTTOMLEFT;
      }
      if (at_bottom && at_right) {
        return HTBOTTOMRIGHT;
      }
      if (at_left) {
        return HTLEFT;
      }
      if (at_right) {
        return HTRIGHT;
      }
      if (at_top) {
        return HTTOP;
      }
      if (at_bottom) {
        return HTBOTTOM;
      }

      // Invisible drag band across the top of the card - except under the close
      // button, which sits OUTSIDE the card at top/right -10 (24x24, so it pokes
      // 14px INTO the client area) and must stay a normal click target.
      POINT client = point;
      ::ScreenToClient(window, &client);
      RECT client_rect = {};
      ::GetClientRect(window, &client_rect);
      RECT close_rect = {};
      close_rect.right =
          client_rect.right - static_cast<LONG>(kAylaMiniCloseInset * scale);
      close_rect.left = close_rect.right - static_cast<LONG>(kAylaMiniCloseSize * scale);
      close_rect.top =
          client_rect.top - static_cast<LONG>(kAylaMiniCloseInset * scale);
      close_rect.bottom = close_rect.top + static_cast<LONG>(kAylaMiniCloseSize * scale);
      const bool over_close = client.x >= close_rect.left - resize &&
                              client.x < close_rect.right + resize &&
                              client.y >= close_rect.top - resize &&
                              client.y < close_rect.bottom + resize;
      if (!over_close && client.y < static_cast<LONG>(kCaptionBandHeight * scale)) {
        return HTCAPTION;
      }
      return HTCLIENT;
    }
    case WM_SIZING: {
      if (kind_ == AylaOverlayKind::kActivityBall) {
        break;
      }
      // Keep the CLIENT area at the design aspect ratio (194 : 120) while the user
      // drags an edge or a corner.
      //
      // Why: the hosted widget is a fixed 16:9 card whose close button sits 10px
      // outside it. Now that the window really is resizable (see WM_NCHITTEST), an
      // arbitrary aspect would have to be resolved by either (a) letterboxing =>
      // the extra band is TRANSPARENT and swallows clicks again (the exact complaint
      // this task is about) or (b) non-uniform scaling => the picture is stretched.
      // Locking the ratio keeps the Dart surface a pure UNIFORM scale, so the card
      // and the video keep their proportions at every size.
      auto* sizing = reinterpret_cast<RECT*>(lparam);
      if (sizing == nullptr) {
        break;
      }
      const double scale = ScaleForWindow(window);
      RECT ratio = {0, 0, static_cast<LONG>(kLiveWindowLogicalWidth * scale),
                    static_cast<LONG>(kLiveWindowLogicalHeight * scale)};
      DWORD style = static_cast<DWORD>(::GetWindowLongPtrW(window, GWL_STYLE));
      DWORD ex_style = static_cast<DWORD>(::GetWindowLongPtrW(window, GWL_EXSTYLE));
      if (!::AdjustWindowRectEx(&ratio, style, FALSE, ex_style)) {
        break;
      }
      // Frame overhead around the client area (the resize frame itself is not part
      // of the ratio).
      const LONG frame_x = (ratio.right - ratio.left) -
                           static_cast<LONG>(kLiveWindowLogicalWidth * scale);
      const LONG frame_y = (ratio.bottom - ratio.top) -
                           static_cast<LONG>(kLiveWindowLogicalHeight * scale);
      const double client_aspect = static_cast<double>(kLiveWindowLogicalWidth) /
                                   static_cast<double>(kLiveWindowLogicalHeight);
      const int edge = static_cast<int>(wparam);
      if (edge == WMSZ_LEFT || edge == WMSZ_RIGHT) {
        const LONG client_height = static_cast<LONG>(
            (sizing->right - sizing->left - frame_x) / client_aspect);
        if (edge == WMSZ_LEFT) {
          sizing->left = sizing->right - (static_cast<LONG>(
                                              client_height * client_aspect) +
                                          frame_x);
        } else {
          sizing->right = sizing->left + (static_cast<LONG>(
                                             client_height * client_aspect) +
                                         frame_x);
        }
        sizing->bottom = sizing->top + client_height + frame_y;
      } else if (edge == WMSZ_TOP || edge == WMSZ_BOTTOM) {
        const LONG client_width = static_cast<LONG>(
            (sizing->bottom - sizing->top - frame_y) * client_aspect);
        sizing->right = sizing->left + client_width + frame_x;
        if (edge == WMSZ_TOP) {
          sizing->top = sizing->bottom - (static_cast<LONG>(client_width /
                                                            client_aspect) +
                                          frame_y);
        } else {
          sizing->bottom = sizing->top + (static_cast<LONG>(client_width /
                                                            client_aspect) +
                                          frame_y);
        }
      } else {
        // Corner drag: the WIDTH dominates and the height follows it. (Following
        // the height instead would let a purely vertical mouse movement change
        // the width, which makes the corner feel like it is fighting the mouse.)
        const LONG client_width = sizing->right - sizing->left - frame_x;
        const LONG corrected_height =
            static_cast<LONG>(client_width / client_aspect) + frame_y;
        if (edge == WMSZ_TOPLEFT || edge == WMSZ_TOPRIGHT) {
          sizing->top = sizing->bottom - corrected_height;
        } else {
          sizing->bottom = sizing->top + corrected_height;
        }
      }
      return TRUE;
    }
    case WM_GETMINMAXINFO: {
      if (kind_ == AylaOverlayKind::kActivityBall) {
        break;
      }
      // Never let the resize loop shrink the window below the size the hosted
      // widget was laid out for: AylaLiveMiniPlayer's card is a fixed 168x94 and
      // its close button lives outside it, so anything smaller clips real content.
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (info == nullptr) {
        break;
      }
      const double scale = ScaleForWindow(window);
      RECT minimum = {0, 0, static_cast<LONG>(kLiveWindowLogicalWidth * scale),
                      static_cast<LONG>(kLiveWindowLogicalHeight * scale)};
      DWORD style = static_cast<DWORD>(::GetWindowLongPtrW(window, GWL_STYLE));
      DWORD ex_style = static_cast<DWORD>(::GetWindowLongPtrW(window, GWL_EXSTYLE));
      if (::AdjustWindowRectEx(&minimum, style, FALSE, ex_style)) {
        info->ptMinTrackSize.x = minimum.right - minimum.left;
        info->ptMinTrackSize.y = minimum.bottom - minimum.top;
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
      if (kind_ != AylaOverlayKind::kActivityBall && channel_ != nullptr &&
          wparam != SIZE_MINIMIZED) {
        // The user can now drag the window's edges (see WM_NCHITTEST). The Flutter
        // surface has to follow, otherwise the extra pixels stay TRANSPARENT and
        // the window goes back to "a big block of the desktop that eats clicks".
        // The Dart side scales the design-sized surface (194x120) up to this
        // client size, so the second engine is never asked to relayout a bigger
        // viewport - only to paint bigger.
        const double scale = ScaleForWindow(window);
        const int64_t logical_width =
            static_cast<int64_t>(static_cast<double>(LOWORD(lparam)) / scale);
        const int64_t logical_height =
            static_cast<int64_t>(static_cast<double>(HIWORD(lparam)) / scale);
        channel_->InvokeMethod(
            "clientSize",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                {flutter::EncodableValue("width"),
                 flutter::EncodableValue(logical_width)},
                {flutter::EncodableValue("height"),
                 flutter::EncodableValue(logical_height)},
            }));
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
