#ifndef RUNNER_LIVE_WINDOW_H_
#define RUNNER_LIVE_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>



// ---------------------------------------------------------------------------
// Detached overlay window: an independent, borderless, always-on-top top-level
// window that hosts a SECOND Flutter engine and paints ONE of the app's
// existing overlay widgets OUTSIDE the application window.
//
// Two flavours share this one class (they only differ in window style, size,
// position and what the second engine builds):
//
//   * AylaOverlayKind::kLiveMini     - the live mini player (AylaLiveMiniPlayer).
//                                      Opaque black-backed 16:9 window.
//   * AylaOverlayKind::kActivityBall - the session activity floating ball group
//                                      (AylaSessionActivityIndicator). Layered /
//                                      per-pixel transparent window: only the
//                                      pills are visible, the rest shows the
//                                      desktop behind it.
//
// Why a second engine (and not a plain child window):
//   * The user requirement is "the overlay must leave the app": it has to stay
//     visible while the main window is minimised / covered / behind other apps,
//     and it must not show up in Alt-Tab or the taskbar.
//   * A second top-level HWND alone is enough for the OS-level part, but the
//     content has to keep RENDERING while the main window is not painting, so
//     it gets its own engine + its own drawing surface.
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
//   channel "ayla/desktop_window" (MAIN engine side, this file's CreateChannel)
//     openLiveWindow {channelId,title,playUrl} -> bool      (kLiveMini)
//     closeLiveWindow                          -> void
//     showBall {payload}                       -> "shown" | "failed"
//     updateBall {payload}                     -> bool
//     hideBall                                 -> void
//     setWindowFullscreen {fullscreen}         -> void      (main window, not
//                                                             the overlay)
//   engine -> Dart callbacks: onLiveWindowClosed, onBallTap, onBallClosed
//
// Dart entrypoint: aylaLiveWindowMain (declared in lib/main.dart, decorated
// with @pragma('vm:entry-point') because a custom entrypoint must live in the
// same library as main()).
// ---------------------------------------------------------------------------

/// Which of the two app overlays this host is showing outside the app window.
enum class AylaOverlayKind {
  /// Detached live mini player (owns its own media_kit player).
  kLiveMini = 0,

  /// Detached session-activity floating ball group (transparent, no video).
  kActivityBall = 1,
};

/// Owns ONE (single, replaceable) detached overlay window of a given kind.
///
/// Lives as long as the main window; the overlay window itself is created on
/// demand by [Show] / [ShowBall] and destroyed by [Close].
class AylaLiveWindowHost {
 public:
  explicit AylaLiveWindowHost(HWND owner_window, AylaOverlayKind kind);
  ~AylaLiveWindowHost();

  AylaLiveWindowHost(const AylaLiveWindowHost&) = delete;
  AylaLiveWindowHost& operator=(const AylaLiveWindowHost&) = delete;

  /// Creates + shows the live mini window and starts playing |play_url|.
  ///
  /// Re-opening while a window already exists REPLACES it (the session moved on
  /// to another channel and the URL it was playing is now stale).
  /// Returns false when the engine or the window could not be created; the
  /// caller must then fall back to the in-app mini player.
  bool Show(const std::string& channel_id,
            const std::string& title,
            const std::string& play_url);

  /// Creates + shows the floating-ball window with |payload_json| (the
  /// serialised AylaOverlayPayload), or just forwards the new payload when the
  /// window is already up (idempotent - the main engine pushes on every change
  /// of the session set).
  bool ShowBall(const std::string& payload_json);

  /// Pushes a new payload to an ALREADY OPEN ball window.
  ///
  /// Returns false when nothing is open (the caller then re-creates it via
  /// [ShowBall]); never creates a window on its own.
  bool UpdateBall(const std::string& payload_json);

  /// Closes the window WITHOUT blocking and WITHOUT notifying Dart.
  ///
  /// This is what the platform-channel handler must use: destroying a second
  /// Flutter engine synchronously from inside another engine's channel callback
  /// is asking for trouble, so the actual teardown is posted to the (same
  /// thread's) message loop instead.
  void RequestClose();

  /// Closes the window (idempotent; no-op when nothing is open).
  ///
  /// [notify] = post the "closed" message to the main window afterwards. It is
  /// false when the close was itself requested BY Dart (the Dart side already
  /// knows) and true when the user closed the window natively.
  void Close(bool notify);

  bool IsOpen() const { return controller_ != nullptr; }

  AylaOverlayKind kind() const { return kind_; }

  HWND owner_window() const { return owner_window_; }

  /// Pending "the user clicked the ball" information (written by the second
  /// engine's channel handler, read by the main window when it receives
  /// kDetachedBallTapMessage - same thread, so no locking is needed).
  bool TakePendingBallTap(std::string* kind, std::string* source_route) {
    if (!ball_tap_pending_) {
      return false;
    }
    ball_tap_pending_ = false;
    if (kind != nullptr) {
      *kind = ball_tap_kind_;
    }
    if (source_route != nullptr) {
      *source_route = ball_tap_route_;
    }
    return true;
  }

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

  /// One tick of the floating ball's click-through evaluation (see the .cpp).
  ///
  /// Toggles WS_EX_TRANSPARENT based on whether the cursor is over the ball
  /// group: that is the only way a click can reach a window belonging to
  /// ANOTHER PROCESS (HTTRANSPARENT stays inside this thread).
  /// Flips the click-through state of the floating-ball window.
  void SetBallInteractive(bool interactive);

  /// Polls the cursor against [ball_hit_rects_] and calls SetBallInteractive.
  void TickHitRects();


  /// Creates the MethodChannel used for engine -> Dart notifications and for
  /// the Dart -> engine commands of the overlay itself.
  void CreateChannel();

  /// Creates the top-level popup window + the second engine + the view.
  ///
  /// [entrypoint_args] is the single JSON string handed to
  /// `aylaLiveWindowMain`. [logical_width] / [logical_height] are in Flutter
  /// logical pixels and get DPI-scaled here (the Dart side must therefore see
  /// exactly these logical sizes).
  /// [fill_work_area_height] = ignore |logical_height| and make the window as
  /// tall as the monitor's work area (used by the floating ball: see the long
  /// comment at kBallWindowMinHeight in live_window.cpp for why).
  bool CreateWindowAndEngine(const std::string& entrypoint_args,
                             int logical_width,
                             int logical_height,
                             bool transparent,
                             bool align_top_right,
                             bool fill_work_area_height = false);

  /// Sends one string argument to the second engine (nullptr when closed).
  void ForwardToEngine(const char* method, const std::string& payload);

  HWND owner_window_ = nullptr;
  HWND window_handle_ = nullptr;
  AylaOverlayKind kind_ = AylaOverlayKind::kLiveMini;

  /// What the current window is playing (sent to the engine on "ready").
  std::string play_url_;
  std::string title_;

  /// Latest floating-ball payload (sent to the engine on "ready").
  std::string overlay_payload_;

  /// Client width of the window in Flutter LOGICAL pixels (WM_NCHITTEST needs
  /// it to compute the group's left edge).
  int logical_width_ = 0;

  /// Where the ball/handle group currently sits inside the (full-height)
  /// floating-ball window, in Flutter LOGICAL pixels from the window's top.
  ///
  /// The Dart side reports it on every drag via the "setBallGroupTop" channel
  /// call; WM_NCHITTEST uses it to decide which pixels are the group (real,
  /// clickable) and which are the empty transparent rest of the window
  /// (HTTRANSPARENT => clicks fall through to whatever is underneath).
  ///
  /// 80 = the widget's WIDE档 default top (shell.css:462 `top: 80px`). The Dart
  /// side forces the wide档 on the overlay (see hostViewportWidth), so this is
  /// the correct initial value until Dart reports its own on the first drag.
  double ball_group_top_ = 80.0;

  /// Visible button rects measured by Flutter (logical px, view coords).
  std::vector<RECT> ball_hit_rects_;

  /// Current click-through state (true = accepting mouse input).
  bool ball_interactive_ = true;


  /// Pending "user clicked the ball" (see TakePendingBallTap).
  bool ball_tap_pending_ = false;
  std::string ball_tap_kind_;
  std::string ball_tap_route_;

  /// True while a close that the Dart side ALREADY knows about is in flight
  /// (closeLiveWindow / session teardown) => do not notify the main window.
  ///
  /// Every other close path (user closing it natively) must notify, otherwise
  /// the main window keeps its own player suspended and the session looks
  /// frozen.
  bool suppress_closed_notification_ = false;

  // Order matters: the channel holds the engine's messenger, so it must be
  // destroyed BEFORE the controller (which owns the engine).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};

#endif  // RUNNER_LIVE_WINDOW_H_
