#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "audio_default_device.h"
#include "flutter/generated_plugin_registrant.h"

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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
