#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
//
// ---------------------------------------------------------------------------
// AYLA CUSTOM FRAME (2026-11-04)
//
// User requirement: "把 windows 窗口原生顶部标题栏去掉，改成 Ayla 专属的美观的
// 融入的标题栏" - the native caption is gone and Ayla draws its own caption bar in
// Flutter (lib/widgets/shell/title_bar.dart), which also owns the three window
// buttons (minimise / windowed / close).
//
// How the frame is removed (keep these pieces together, they only work as a set):
//
//   1. WM_NCCALCSIZE -> 0: the client area IS the whole window rect (no caption,
//      no border). While maximised Windows still sizes the window larger than the
//      work area by the invisible frame thickness, so the client rect is pinned to
//      rcWork - otherwise the edges of the UI are pushed off screen.
//   2. Both WM_NCCALCSIZE and WM_NCHITTEST are answered in
//      FlutterWindow::MessageHandler *before* the engine sees them: the engine
//      fans them out to the registered top-level proc delegates, and
//      window_manager's delegate also implements WM_NCCALCSIZE (its "frameless"
//      path inflates the client rect by the frame thickness, which would make the
//      Flutter view larger than the window).
//   3. Startup is maximised (SetStartMaximized): Show() uses SW_SHOWMAXIMIZED so
//      the window never flashes through its restore rect.
//
// Two consequences that live on the Dart side, on purpose:
//
//   * **Dragging** is Flutter-driven (window_manager.startDragging -> SC_MOVE), so
//     the bar's geometry has exactly one owner. Returning HTCAPTION for a guessed
//     band here would duplicate that geometry and swallow clicks meant for the
//     window buttons.
//   * **Mouse-resize edges** are also Flutter-driven (lib/widgets/shell/title_bar.dart
//     -> AylaResizeEdges): the Flutter view is a WS_CHILD window covering the whole
//     client area, and a child window proc answers HTCLIENT for every point on it,
//     which ends the hit-test search - so the WM_NCHITTEST band above is never
//     consulted for ordinary presses over the view. See HitTestFrame's comment.
// ---------------------------------------------------------------------------
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Ayla: the window is shown maximised (user requirement "Ayla 启动默认最大化").
  // Must be called before Show(); Show() then uses SW_SHOWMAXIMIZED instead of
  // SW_SHOWNORMAL so the window never flashes through its restore rect.
  void SetStartMaximized(bool start_maximized);

  // Ayla: make the WINDOWED (restore) size proportional to the maximised size and
  // smaller than it - user requirement "最大化到窗口化时…要和最大化时等比，窗口小一些".
  //
  // Call it right after Create() and before the message loop. Implementation runs
  // on the first WM_SIZE / activation, because the maximised size is only known
  // after the window is actually maximised.
  void SetMaximizeThenShrinkRestore();

  // Ayla custom frame: 1px hairline + drop shadow + rounded corners while the
  // window is in its WINDOWED state (see the .cpp for why each piece is needed
  // once WM_NCCALCSIZE returns 0). Maximised and fullscreen windows are square
  // by design - Windows itself does the same for every normal app.
  //
  // Called from WM_SIZE (the one message that fires for every state change,
  // including the ones window_manager performs with SetWindowPos).
  void SyncWindowFrameDecoration(HWND window);

  // Ayla proportional restore (see SetMaximizeThenShrinkRestore).
  void ApplyProportionalRestore(HWND window);

  // Marks the window as being in (exclusive, cover-the-monitor) fullscreen.
  //
  // Why the base window needs to know: WM_DPICHANGED below unconditionally
  // repositions the window to the rectangle Windows suggests, which is the
  // *windowed* frame for the new DPI. Dragging a fullscreen window onto a
  // monitor with a different scale factor therefore snaps it back out of
  // fullscreen. With this flag set, that repositioning is skipped.
  //
  // window_manager (the plugin that owns the actual fullscreen HWND state)
  // calls into this through FlutterWindow::OnFullscreenChanged.
  void SetFullscreen(bool is_fullscreen);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  // Ayla custom frame: answers WM_NCCALCSIZE (no caption / no border).
  //
  // Called from FlutterWindow::MessageHandler **before** it forwards the message
  // to the engine. That order is load-bearing: window_manager's top-level window
  // proc delegate also implements WM_NCCALCSIZE and, while its internal
  // "frameless" flag is set (i.e. in live fullscreen), it expands the client rect
  // by the frame thickness - which would make the Flutter view larger than the
  // window.
  //
  // Returns true when the message was consumed.
  bool HandleNcCalcSize(UINT const message,
                        HWND window,
                        WPARAM const wparam,
                        LPARAM const lparam,
                        LRESULT* result) const;

  // Ayla custom frame: answers WM_NCHITTEST with the resize border codes.
  // Always returns a hit-test code (HTCLIENT when the point is inside the
  // resize band's complement).
  LRESULT HitTestFrame(HWND window, LPARAM const lparam) const;


 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // True while the window covers a whole monitor without a frame (see
  // SetFullscreen above).
  bool is_fullscreen_ = false;

  // Last windowed/maximised state pushed to DWM (avoids re-sending the same
  // attribute on every WM_SIZE). < 0 = never applied yet.
  int frame_decorated_ = -1;

  // See SetMaximizeThenShrinkRestore().
  bool shrink_restore_pending_ = false;

  // Ayla: show the window maximised on the first Show() (see SetStartMaximized).
  bool start_maximized_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
