cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# ---- 渲染后端开关（2026-10-16）---------------------------------------------
# AYLA_IMPELLER=OFF（默认）⇒ 用 Skia（用户在 Windows release 实测更流畅：
# 工程掉帧探针显示瓶颈在 raster 侧，而 Impeller 是 GPU 光栅化后端）。
# 想构建 Impeller 版：cmake 时传 -DAYLA_IMPELLER=ON，或在 build/windows/x64 下
# 重跑 cmake。命令行 `--enable-impeller` / `--no-enable-impeller` 可运行时覆盖。
# 详细依据见 runner/main.cpp 顶部注释。
option(AYLA_IMPELLER "Build with the Impeller rendering backend" OFF)
# Prefer the high-performance (discrete) GPU. 2 = high performance, 1 = low power,
# 0 = engine default. See runner/main.cpp for the rationale.
set(AYLA_GPU_PREFERENCE "2" CACHE STRING "GPU preference: 0=none, 1=low power, 2=high performance")
target_compile_definitions(${BINARY_NAME} PRIVATE "AYLA_GPU_PREFERENCE=${AYLA_GPU_PREFERENCE}")
if(AYLA_IMPELLER)
  target_compile_definitions(${BINARY_NAME} PRIVATE "AYLA_IMPELLER=1")
else()
  target_compile_definitions(${BINARY_NAME} PRIVATE "AYLA_IMPELLER=0")
endif()

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
