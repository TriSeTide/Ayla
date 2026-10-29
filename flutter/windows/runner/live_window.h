#ifndef RUNNER_LIVE_WINDOW_H_
#define RUNNER_LIVE_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// ---------------------------------------------------------------------------
// Detached live window: an independent, borderless, always-on-top top-level
// window that plays a HLS url in a SECOND Flutter engine.
//
// Why a second engine (and not a plain child window):
//   * The user requirement is "the mini player must leave the app": it has to
//     stay visible while the main window is minimised / covered / behind other
//     apps, and it must not show up in Alt-Tab or the taskbar.
//   * A second top-level HWND alone is enough for the OS-level part, but the
//     video has to keep RENDERING while the main window is not painting, so it
//     gets its own engine + its own drawing surface.
//
// Why media_kit_video had to be vendored first (see
// third_party/media_kit_video/README-AYLA.md):
//   media_kit_video 2.0.1 kept a process-wide `static MediaKitVideoPlugin*
//   instance_`. Registering the plugin for the second engine overwrote the
//   pointer that the FIRST engine's window procedure used, so the main window's
//   VideoController.create() hung forever (= main window live playback went
//   black as soon as this window existed). The vendored copy keys the registry
//   by HWND instead.
//
// Contract (Dart side: lib/core/platform/detached_live.dart):
//   channel "ayla/desktop_window"
//     openLiveWindow {channelId,title,playUrl} -> bool
//     closeLiveWindow                          -> void
//     showBall {...}                           -> "unsupported"
//     hideBall                                 -> void
//   engine -> Dart callbacks: onLiveWindowClosed, onBallTap, onBallClosed
//
// Dart entrypoint: aylaLiveWindowMain (declared in lib/main.dart, decorated
// with @pragma('vm:entry-point') because a custom entrypoint must live in the
// same library as main()).
// ---------------------------------------------------------------------------

/// Owns the (single, replaceable) detached live window.
///
/// Lives as long as the main window; the live window itself is created on
/// demand by [Show] and destroyed by [Close].
class AylaLiveWindowHost {
 public:
  explicit AylaLiveWindowHost(HWND owner_window);
  ~AylaLiveWindowHost();

  AylaLiveWindowHost(const AylaLiveWindowHost&) = delete;
  AylaLiveWindowHost& operator=(const AylaLiveWindowHost&) = delete;

  /// Creates + shows the live window and starts playing |play_url|.
  ///
  /// Re-opening while a window already exists REPLACES it (the session moved on
  /// to another channel and the URL it was playing is now stale).
  /// Returns false when the engine or the window could not be created; the
  /// caller must then fall back to the in-app mini player.
  bool Show(const std::string& channel_id,
            const std::string& title,
            const std::string& play_url);

  /// Closes the window WITHOUT blocking and WITHOUT notifying Dart.
  ///
  /// This is what the platform-channel handler must use: destroying a second
  /// Flutter engine synchronously from inside another engine's channel callback
  /// is asking for trouble, so the actual teardown is posted to the (same
  /// thread's) message loop instead.
  void RequestClose();

  /// Closes the live window (idempotent; no-op when nothing is open).
  ///
  /// [notify] = run the "onLiveWindowClosed" Dart callback afterwards. It is
  /// false when the close was itself requested BY Dart (the Dart side already
  /// knows) and true when the user closed the window natively.
  void Close(bool notify);

  bool IsOpen() const { return controller_ != nullptr; }

  HWND owner_window() const { return owner_window_; }

 private:
  static LRESULT CALLBACK WndProc(HWND window,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam);

  LRESULT HandleMessage(HWND window,
                        UINT message,
                        WPARAM wparam,
                        LPARAM lparam);

  /// Tears down engine/view/channel. Safe to call from WM_DESTROY and from
  /// the destructor.
  void TearDown();

  /// Creates the MethodChannel used for engine -> Dart notifications.
  void CreateChannel();

  HWND owner_window_ = nullptr;
  HWND window_handle_ = nullptr;

  /// What the current window is playing (sent to the engine on "ready").
  std::string play_url_;
  std::string title_;

  /// True while a close that the Dart side ALREADY knows about is in flight
  /// (closeLiveWindow / session teardown) => do not send onLiveWindowClosed.
  ///
  /// Every other close path (X button in the window, click-the-video, user
  /// closing it natively) must notify, otherwise the main window keeps its own
  /// player suspended and the session looks frozen.
  bool suppress_closed_notification_ = false;

  // Order matters: the channel holds the engine's messenger, so it must be
  // destroyed BEFORE the controller (which owns the engine).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};

#endif  // RUNNER_LIVE_WINDOW_H_
