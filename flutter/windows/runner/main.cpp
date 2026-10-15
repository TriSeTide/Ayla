#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

// ---------------------------------------------------------------------------
// Rendering backend selection (Impeller vs Skia).  [2026-10-16]
//
// Why this is set here:
//   * `flutter build windows` has NO `--enable-impeller` option (only `run` does).
//   * `flutter run` forwards it as an engine command-line flag
//     (`flutter_tools/.../desktop_device.dart`: addFlag('enable-impeller=false')),
//     but the Windows runner passes ALL command-line arguments to
//     `set_dart_entrypoint_arguments` (i.e. to the Dart entrypoint) -> passing
//     `--enable-impeller=false` to a release exe does NOT work
//     (verified: the log still prints "Using the Impeller rendering backend").
//   * The supported way is `DartProject::set_impeller_switch()`
//     (see `ImpellerSwitch` in dart_project.h).
//
// Evidence for preferring Skia on this project (user report, 2026-10-16):
//   the in-repo frame probe (lib/main.dart `_installJankProbe`) shows the
//   bottleneck is on the RASTER side -- 3591 jank frames with build=2.0ms avg
//   vs raster=17.0ms avg, and raster > build in 99% of frames. Raster is the
//   GPU stage, which is exactly where the two backends differ. The user also
//   measured `flutter run -d windows --profile --no-enable-impeller` as
//   noticeably smoother than the Impeller default.
//
// Two independent controls:
//   1. Compile time: CMake option AYLA_IMPELLER (default OFF = Skia).
//      Build an Impeller variant with `cmake -DAYLA_IMPELLER=ON`.
//   2. Run time: `--enable-impeller` / `--no-enable-impeller` on the command
//      line overrides the compile-time default, so a single exe can A/B test.
//
// Appearance note: Impeller and Skia may differ by a pixel or two on blur
// edges / text subpixel antialiasing in extreme cases. Switching to Skia also
// silences Impeller's `Contents::SetInheritedOpacity should never be called`
// validation spam (this project uses backdrop blur heavily).
//
// NOTE: keep this comment ASCII-only. MSVC compiles this file under code page
// 936 here, and non-ASCII comments were mis-parsed (C4819 -> C2220 -> C1020).
// ---------------------------------------------------------------------------
#ifndef AYLA_IMPELLER
#define AYLA_IMPELLER 0
#endif

// ---------------------------------------------------------------------------
// GPU preference (opt into the discrete GPU on hybrid-graphics machines).
//
// `DartProject::GpuPreference` defaults to `NoPreference` (dart_project.h:191),
// which on a laptop with both an iGPU and a dGPU usually resolves to the
// integrated one (power saving). The raster stage of this app is the measured
// bottleneck, so preferring the high-performance adapter is worth trying.
//
// Set AYLA_GPU_PREFERENCE to 0 (no preference / engine default), 1 (low power)
// or 2 (high performance). CMake option AYLA_HIGH_PERF_GPU (default ON) maps to 2.
// Falls back to a low-power GPU automatically if no dGPU is present
// (see the enum docs), so this is safe on single-GPU machines.
//
// NOTE: keep ASCII-only (MSVC code page 936 mis-parses non-ASCII comments).
// ---------------------------------------------------------------------------
#ifndef AYLA_GPU_PREFERENCE
#define AYLA_GPU_PREFERENCE 2
#endif
int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Parse our own backend flags; everything else still goes to the Dart
  // entrypoint unchanged. Flag names match flutter_tools' desktop_device.dart.
  bool impeller = AYLA_IMPELLER != 0;
  bool impeller_overridden = false;
  std::vector<std::string> dart_arguments;
  dart_arguments.reserve(command_line_arguments.size());
  for (const std::string& arg : command_line_arguments) {
    if (arg == "--no-enable-impeller") {
      impeller = false;
      impeller_overridden = true;
      continue;
    }
    if (arg == "--enable-impeller") {
      impeller = true;
      impeller_overridden = true;
      continue;
    }
    dart_arguments.push_back(arg);
  }
  (void)impeller_overridden;

  project.set_impeller_switch(impeller ? flutter::ImpellerSwitch::Enabled
                                       : flutter::ImpellerSwitch::Disabled);

#if AYLA_GPU_PREFERENCE == 1
  project.set_gpu_preference(flutter::GpuPreference::LowPowerPreference);
#elif AYLA_GPU_PREFERENCE == 2
  project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);
#else
  project.set_gpu_preference(flutter::GpuPreference::NoPreference);
#endif

  project.set_dart_entrypoint_arguments(std::move(dart_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ayla_flutter", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
