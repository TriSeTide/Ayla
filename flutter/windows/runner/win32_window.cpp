#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM (WM_NCHITTEST)

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// ---------------------------------------------------------------------------
// Ayla custom frame (see win32_window.h). ASCII only: MSVC compiles this project
// under code page 936 here and non-ASCII comments were mis-parsed before.
// ---------------------------------------------------------------------------

/// Thickness of the invisible grip band along each window edge, in *logical*
/// pixels (scaled by DPI where it is used). 4 px at 100% is the smallest band
/// that still feels like a Windows resize edge.
constexpr int kResizeBorderDip = 4;

// ---- DWM attributes used by SyncWindowFrameDecoration ---------------------
//
// Redefined under #ifndef because this project builds against whatever SDK the
// machine has installed; the numeric values are stable Win32 ABI.


#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

/// DWMWCP_ROUND (2): round the window corners.
constexpr int kDwmWindowCornerRound = 2;
/// DWMWCP_DONOTROUND (1): square corners (maximised / fullscreen).
constexpr int kDwmWindowCornerDoNotRound = 1;

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  // Ayla: first show is maximised by default (see SetStartMaximized). Using
  // SW_SHOWMAXIMIZED here instead of Show() -> Maximize() keeps the window from
  // flashing through its 1280x720 restore rect on startup.
  return ShowWindow(window_handle_,
                    start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  // The Ayla custom frame is answered by FlutterWindow::MessageHandler *before*
  // the engine sees these messages (see win32_window.h); nothing to do here.
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      // Fullscreen hand-off (see SetFullscreen): the suggested rectangle is the
      // *windowed* frame for the new scale factor, so applying it would yank a
      // fullscreen window off the monitor it is covering (the owner, i.e.
      // window_manager, is the one that resizes for fullscreen). Just let the
      // child view follow the new size and consume the message.
      if (is_fullscreen_) {
        RECT rect = GetClientArea();
        if (child_content_ != nullptr) {
          MoveWindow(child_content_, rect.left, rect.top,
                     rect.right - rect.left, rect.bottom - rect.top, TRUE);
        }
        return 0;
      }

      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // Every windowed/maximised/fullscreen transition ends up here (both the
      // user's Win+Up and window_manager's SetWindowPos produce WM_SIZE), which
      // makes it the one place that can keep the DWM decoration in sync.
      SyncWindowFrameDecoration(hwnd);
      // First WM_SIZE while maximised is the earliest point the maximised
      // geometry exists -> that is where the proportional restore size is
      // derived from (no-op afterwards).
      ApplyProportionalRestore(hwnd);
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetFullscreen(bool is_fullscreen) {
  is_fullscreen_ = is_fullscreen;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::SetStartMaximized(bool start_maximized) {
  start_maximized_ = start_maximized;
}

// ---------------------------------------------------------------------------
// Ayla custom frame - WM_NCCALCSIZE
//
// Return 0 with rgrc[0] left untouched: the client area becomes the entire
// window rectangle, so Windows draws no caption and no border. Two cases need
// care:
//
//  * Maximised windows are sized by Windows to rcWork inflated by the (now
//    invisible) frame thickness on every side. Leaving rgrc[0] alone would push
//    the bottom/right of the UI off screen and leave an equally thick gap at the
//    top/left, so the offending edges are compensated.
//  * The engine resizes the Flutter view from the *client* rect (WM_SIZE) the
//    moment we return 0, so a shrunk client rect means a shrunk Flutter view.
//    That is why the compensation above must happen in the same message that
//    Windows uses to (re)compute the frame, and why this handler runs for
//    WM_NCCALCSIZE messages that carry no wparam as well.
//
// window-fullscreen hand-off: when window_manager puts the window in fullscreen
// it strips WS_THICKFRAME and covers the monitor; the client rect is then the
// whole rect already and nothing is compensated.
// ---------------------------------------------------------------------------
bool Win32Window::HandleNcCalcSize(UINT const message,
                                   HWND window,
                                   WPARAM const wparam,
                                   LPARAM const lparam,
                                   LRESULT* result) const {
  if (message != WM_NCCALCSIZE || window == nullptr || lparam == 0) {
    return false;
  }

  // WM_NCCALCSIZE arrives in two flavours: wparam == TRUE carries the proposed
  // rectangles (NCCALCSIZE_PARAMS), wparam == FALSE carries the new window rect
  // (RECT). Both must be answered, otherwise Windows paints a caption for one
  // frame at specific moments (e.g. right after un-maximising).
  RECT* rect = nullptr;
  if (wparam != 0) {
    auto params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    rect = &params->rgrc[0];
  } else {
    rect = reinterpret_cast<RECT*>(lparam);
  }

  // Fullscreen (covers a monitor, frame already gone): nothing to compensate.
  if (is_fullscreen_) {
    *result = 0;
    return true;
  }

  // This build has no custom caption drawn by *native* code, so the only thing
  // to do is make sure a maximised window's client area does not overflow the
  // monitor.
  if (::IsZoomed(window)) {
    const HMONITOR monitor =
        MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{};
    info.cbSize = sizeof(MONITORINFO);
    if (::GetMonitorInfo(monitor, &info) != 0) {
      rect->left = info.rcWork.left;
      rect->top = info.rcWork.top;
      rect->right = info.rcWork.right;
      rect->bottom = info.rcWork.bottom;
    }
  }

  *result = 0;
  return true;
}

// ---------------------------------------------------------------------------
// Ayla custom frame - WM_NCHITTEST
//
// With the caption gone there is no non-client area left, so Windows would never
// offer a resize edge. The band along each edge is answered by hand; everything
// else is HTCLIENT (the Flutter title bar pulls/drags the window through
// window_manager / SC_MOVE and owns the button geometry).
//
// ⚠️ WHERE THIS CAN AND CANNOT FIRE (read from the engine, not guessed):
//
//   `HostWindow::HandleMessage` (host_window.cc) dispatches WM_NCHITTEST to the
//   registered top-level proc delegates, so this handler IS on the real message
//   path - but only while Windows asks the top-level window. The Flutter view is
//   a WS_CHILD window covering the whole client area (`SetChildContent` in
//   host_window.cc), and a child window proc answers HTCLIENT for every point on
//   its surface; HTCLIENT ends the hit-test search, so for presses over the view
//   this handler is never consulted.
//
//   ⇒ Mouse-resize edges are therefore NOT implemented here. They live in Dart
//   (`lib/widgets/shell/title_bar.dart`, `AylaResizeEdges`), where the pointer
//   events actually arrive. This native band still covers the cases Windows does
//   route here - a press on a window that is not the active window, and any
//   point outside the view - so the frame stays consistent for every caller.
// ---------------------------------------------------------------------------
LRESULT Win32Window::HitTestFrame(HWND window, LPARAM const lparam) const {
  if (window == nullptr) {
    return HTCLIENT;
  }
  // Never offer resize handles in fullscreen (window_manager owns that state),
  // and a maximised window is already filling the work area.
  if (is_fullscreen_ || ::IsZoomed(window)) {
    return HTCLIENT;
  }

  POINT local = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  // The caller may pass screen or client coordinates:
  //  - WM_NCHITTEST carries SCREEN coordinates;
  //  - the WM_NCLBUTTONDOWN / WM_MOUSEMOVE relay below carries CLIENT ones
  //    (they come from the child, whose client frame is the top-level client
  //    frame). Screen coordinates of an on-screen window are far larger than the
  //    client rect, so the two are told apart without a flag and without
  //    ScreenToClient on an already-client point (which would double-shift).
  RECT client{};
  if (::GetClientRect(window, &client) == 0) {
    return HTCLIENT;
  }
  if (local.x < 0 || local.y < 0 || local.x >= client.right ||
      local.y >= client.bottom) {
    POINT screen = {local.x, local.y};
    if (::ScreenToClient(window, &screen) == 0) {
      return HTCLIENT;
    }
    local = screen;
  }

  // Band thickness = what Windows itself reserves for a resizable window:
  // SM_CXSIZEFRAME + SM_CXPADDEDBORDER. Asking GetSystemMetricsForDpi keeps it
  // correct per monitor instead of hardcoding a logical value.
  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  LONG band = 0;
  if (dpi > 0) {
    band = ::GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
           ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  }
  if (band <= 0) {
    band = ::GetSystemMetrics(SM_CXSIZEFRAME) +
           ::GetSystemMetrics(SM_CXPADDEDBORDER);
  }
  if (band <= 0) {
    const double scale = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
    band = static_cast<LONG>(kResizeBorderDip * scale);
  }

  const bool left = local.x < band;
  const bool right = local.x >= client.right - band;
  const bool top = local.y < band;
  const bool bottom = local.y >= client.bottom - band;

  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}




// ---------------------------------------------------------------------------
// Ayla custom frame - windowed decoration (rounded corners + shadow + hairline)
//
// Why this cannot be left to CSS/Flutter: the Flutter view is a rectangular
// child window that fills the WHOLE client area, so anything drawn in Dart can
// never reach outside its own rect. A rounded corner therefore has to come from
// DWM (the compositor rounds the real window and clips the view with it), and
// the shadow has to come from DWM too (it draws it outside the window rect).
//
// What is used, and what is deliberately NOT used:
//
//  * DWMWA_WINDOW_CORNER_PREFERENCE = ROUND (Win11 22000+): the only piece that
//    makes the corners round. Safe in isolation - it just clips the window.
//    Reset to DONOTROUND when maximised/fullscreen.
//  * DWMWA_NCRENDERING_POLICY: **never touched**. Both ENABLED and DISABLED make
//    Windows draw the classic Win7 frame + system caption buttons back; the only
//    good state is the default (unset). See the comment inside the function -
//    this caused two shipped regressions.
//  * DWMWA_BORDER_COLOR: the window's own edge. Measured to work on Win11 and to
//    colour ONLY the edge (no system chrome), so it replaces the Dart-side outline
//    that used to be drawn inside the app - that one could never line up with the
//    window's rounded corner (user report).
//  * The drop shadow comes from DWM automatically once the window is round (the
//    user confirmed it is present), so nothing extra is needed for it.
//
// Everything here is idempotent and cheap to call on every WM_SIZE.
// ---------------------------------------------------------------------------
void Win32Window::SyncWindowFrameDecoration(HWND window) {
  if (window == nullptr) {
    return;
  }

  // Maximised and fullscreen windows fill the work area: rounded corners there
  // would show desktop colour in the screen corners.
  const bool windowed = !is_fullscreen_ && ::IsZoomed(window) == FALSE;
  const int wanted = windowed ? 1 : 0;
  if (frame_decorated_ == wanted) {
    return;
  }

  // 1. Rounded (or not) corners. Safe on its own: this only clips the window.
  const int preference =
      windowed ? kDwmWindowCornerRound : kDwmWindowCornerDoNotRound;
  const HRESULT corner_hr = ::DwmSetWindowAttribute(
      window, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference));

  // 2. DWMWA_NCRENDERING_POLICY 绝对不要碰 —— 这是两次事故的共同根因。
  //
  //    2026-11-04 用户两次实报「怎么搬出来了 win7 的窗口边框」/「还是有啊」，
  //    两次都是我在这里调了这个属性：
  //      · 设 DWMNCRP_ENABLED(2) → DWM 认为要渲染非客户区 ⇒ 补画经典边框 +
  //        右上角三个系统 caption 按钮，盖住自绘的三键；
  //      · 设 DWMNCRP_DISABLED(1) → DWM 退出非客户区渲染 ⇒ 交回**经典窗口样式**
  //        绘制，于是 DefWindowProc 把 Win7 那套立体边框和标题栏整个画出来。
  //    两种取值都会让窗口退回经典外观；唯一正常的状态是**不设置**（默认
  //    USEWINDOWSTYLE）。第一轮没有边框，正是因为这里什么都没设。
  //
  //    根因是同一个：本窗口的非客户区已被 WM_NCCALCSIZE 取消，「让 DWM 管 NC」
  //    与「不让 DWM 管 NC」都会让 Windows 用另一种方式把 NC 画回来。
  //
  // 3. 窗口边线（用户实报「窗口边线是黑色」，问能不能改 —— 能）。
  //
  //    `DWMWA_BORDER_COLOR` 在 Win11 22000+ 上有效，且**只改颜色、不恢复任何
  //    系统 chrome**：本项目用一次性探针实测确认过（frameless 三件套 + ROUND +
  //    BORDER，五个窗口并排截图比对；三个颜色调用全部返回 S_OK，黑边/冰蓝边/无边的
  //    差异肉眼可辨，且边线自动贴合 ROUND 的圆角）。
  //
  //    ⚠️ 它**不是** DWMWA_NCRENDERING_POLICY 那一类：那个属性会让 Windows 把
  //    经典 Win7 边框和系统 caption 按钮整套画回来（两次实报的根因，已彻底移除）。
  //
  //    颜色取 `--ice-300`（#BDD4E9）：与侧栏/输入框边线同色，是「玻璃卡边缘」
  //    既有的表达；黑色默认边在浅色极光上过于生硬。
  //    COLORREF 是 0x00BBGGRR，所以 RGB(r,g,b) 的参数顺序就是 r,g,b。
  //
  //    最大化 / 全屏时写 DWMWA_COLOR_NONE(0xFFFFFFFE)，交回系统默认（否则屏幕
  //    边缘会出现一圈本不该有的冰蓝线）。
  const COLORREF ice300 = RGB(0xBD, 0xD4, 0xE9);
  const COLORREF no_border = static_cast<COLORREF>(0xFFFFFFFE);
  const COLORREF border = windowed ? ice300 : no_border;
  ::DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border, sizeof(border));
  // Only remember success for the corner attribute: on Windows 10 it does not
  // exist, and pretending it applied would keep us from retrying.
  if (SUCCEEDED(corner_hr)) {
    frame_decorated_ = wanted;
  }
}


// ---------------------------------------------------------------------------
// Ayla - proportional restore size
// ---------------------------------------------------------------------------
// User requirement: "最大化到窗口化时，默认窗口比例不对，要和最大化时等比，窗口小一些".
//
// Why the maximised size has to be measured instead of assumed: the maximised
// window is rcWork of whatever monitor it lands on, minus nothing (a maximised
// window has no frame: WM_NCCALCSIZE already collapsed it). So on a 1920x1080
// screen with a 48px taskbar the maximised window is 1920x1032 (1.86:1), while
// a hardcoded 1440x900 is 1.60:1 - visibly "wrong ratio" when you restore.
// Deriving from the real maximum keeps the two in the same shape on every
// monitor, DPI and taskbar configuration, without a table of screen sizes.
//
// 0.8 was picked because the user asked for "a bit smaller" (窗口小一些) while
// keeping enough room for the three-column wide layout. Measured on this machine
// (1920x1080 with taskbar): maximised 1938x1048 -> restore 1550x838, ratio
// delta 0.0004 (i.e. equal to 4 decimal places) and centred in the work area.
//
// It is applied to the window's *style* geometry, i.e. it becomes what Windows
// restores to on un-maximise AND what the first Show() would use. Nothing else
// in the app needs to know about it.
namespace {

/// Restore size = 80% of the maximised size, per axis.
constexpr double kRestoreScale = 0.8;

}  // namespace

void Win32Window::SetMaximizeThenShrinkRestore() {
  shrink_restore_pending_ = true;
}

/// Move the window's restore rect to [kRestoreScale] of the maximised rect.
///
/// Called once, from the first WM_SIZE after the window was maximised - the
/// earliest moment the maximised geometry exists.
///
/// ⚠️ The maximised size is taken with `GetWindowRect`, **not** by sending
/// `WM_GETMINMAXINFO` to ask for `ptMaxSize`: measured on this machine, that
/// returns `0x0` when sent explicitly (the system only fills it in on the copy it
/// sends itself), which silently produced a 170x47 restore window in the probe.
/// The rect of an already-maximised window *is* the answer, and it also accounts
/// for the monitor, its DPI and the taskbar without any extra queries.
void Win32Window::ApplyProportionalRestore(HWND window) {
  if (!shrink_restore_pending_ || window == nullptr) {
    return;
  }
  // Need the maximised geometry to derive from: WM_SIZE can arrive before the
  // maximised state is observable.
  if (::IsZoomed(window) == FALSE) {
    return;
  }

  RECT maximized{};
  if (::GetWindowRect(window, &maximized) == 0) {
    return;
  }
  const LONG max_w = maximized.right - maximized.left;
  const LONG max_h = maximized.bottom - maximized.top;
  if (max_w <= 0 || max_h <= 0) {
    return;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (::GetWindowPlacement(window, &placement) == FALSE) {
    return;
  }

  const LONG new_w = static_cast<LONG>(max_w * kRestoreScale);
  const LONG new_h = static_cast<LONG>(max_h * kRestoreScale);
  if (new_w <= 0 || new_h <= 0) {
    return;
  }

  // Centre it in the work area: a restore that lands half off-screen (or behind
  // the taskbar) is the other half of "the default size looks wrong".
  const HMONITOR monitor =
      ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (::GetMonitorInfo(monitor, &mi) == 0) {
    return;
  }
  const LONG left = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - new_w) / 2;
  const LONG top = mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - new_h) / 2;
  RECT& normal = placement.rcNormalPosition;
  normal.left = left;
  normal.top = top;
  normal.right = left + new_w;
  normal.bottom = top + new_h;
  // Keep `showCmd` as "maximised": SetWindowPlacement applies that command, and
  // we only want the geometry remembered, not an immediate restore.
  placement.showCmd = SW_SHOWMAXIMIZED;
  if (::SetWindowPlacement(window, &placement) == FALSE) {
    return;
  }
  // Only stop trying once it actually took effect; otherwise retry next WM_SIZE.
  shrink_restore_pending_ = false;
}
void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}