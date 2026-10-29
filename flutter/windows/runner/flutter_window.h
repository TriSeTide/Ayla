#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "live_window.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // MethodChannel "ayla/audio_default_device": exposes the OS default audio
  // endpoints so the app can follow the user's system device choice instead of
  // WebRTC's built-in "default communication device".
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_device_channel_;

  // MethodChannel "ayla/desktop_window" (Dart side:
  // lib/core/platform/detached_live.dart): opens / closes the detached
  // always-on-top live window that lives in a SECOND Flutter engine.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_window_channel_;

  // Owner of that second window+engine. Created lazily on first open and kept
  // alive for the lifetime of the main window; the window itself is created and
  // destroyed on demand by AylaLiveWindowHost::Show / Close.
  std::unique_ptr<AylaLiveWindowHost> live_window_host_;

  // Which window's Win11 corner rounding we have switched off, if any.
  // See FlutterWindow::SyncFullscreenWindowState (win32 corner rounding leaves
  // the desktop colour visible in the four corners of a fullscreen window).
  HWND donotround_hwnd_ = nullptr;
  bool donotround_applied_ = false;

  // Called from the message pump on WM_SIZE: decides "is this window covering
  // its whole monitor right now" and propagates that to Win32Window +
  // DWM corner rounding. Idempotent.
  void SyncFullscreenWindowState(HWND window);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
