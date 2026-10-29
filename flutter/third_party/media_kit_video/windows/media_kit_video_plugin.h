// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#ifndef MEDIA_KIT_VIDEO_PLUGIN_H_
#define MEDIA_KIT_VIDEO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <Windows.h>
#include <functional>
#include <queue>
#include <mutex>
#include <unordered_map>

#include "video_output_manager.h"

namespace media_kit_video {

class MediaKitVideoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  MediaKitVideoPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~MediaKitVideoPlugin();

  MediaKitVideoPlugin(const MediaKitVideoPlugin&) = delete;
  MediaKitVideoPlugin& operator=(const MediaKitVideoPlugin&) = delete;

 private:
  static constexpr UINT kMainThreadTaskMessage = WM_USER + 1001;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void RunOnMainThread(std::function<void()> task);
  static LRESULT CALLBACK WindowProcDelegate(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
  void ProcessMainThreadTasks();
  
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_ =
      nullptr;
  std::unique_ptr<VideoOutputManager> video_output_manager_ = nullptr;
  HWND flutter_window_ = nullptr;
  WNDPROC original_window_proc_ = nullptr;
  std::queue<std::function<void()>> main_thread_tasks_;
  std::mutex main_thread_tasks_mutex_;

  // [AYLA PATCH] Multi-engine registry (see .../media_kit_video/README-AYLA.md).
  //
  // Upstream 2.0.1 keeps a single process-wide `static MediaKitVideoPlugin*
  // instance_`. As soon as the process hosts more than one Flutter engine
  // (Ayla's always-on-top detached live window runs a second engine), the
  // second registration overwrote it => |WindowProcDelegate| dispatched
  // kMainThreadTaskMessage and the saved WNDPROC to the WRONG engine, and the
  // *main* window's VideoController.create() hung forever (media-kit#1383).
  // Now each instance is keyed by the HWND whose WNDPROC it hooked and the
  // delegate resolves the owner from the |hwnd| it was actually called with.
  static std::unordered_map<HWND, MediaKitVideoPlugin*> instances_;
};

}  // namespace media_kit_video

#endif  // MEDIA_KIT_VIDEO_PLUGIN_H_
