cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "child_window_style.cpp"
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
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
# runner 里的子窗口定位要用 GetDpiForMonitor（Win8.1+）与 MonitorFromPoint，
# 而模板默认的 _WIN32_WINNT=0x0600 会让 SDK 头文件把这些声明屏蔽掉。
# 清单里 supportedOS 已经只声明 Windows 10/11，这里把目标版本对齐到 0x0A00。
target_compile_definitions(${BINARY_NAME} PRIVATE "_WIN32_WINNT=0x0A00" "WINVER=0x0A00")

# runner 源码含中文注释与中文字符串（悬浮窗标题）。MSVC 默认按系统代码页(936)
# 读取源文件，在 /W4 /WX 下 C4819 会直接变成编译错误；显式按 UTF-8 处理源码与
# 执行字符集，中文窄字符串即为 UTF-8，由 Utf16() 转成宽字符。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# 子窗口按托盘槽位定位时要用 GetDpiForMonitor 换算逻辑/物理像素（child_window_style.cpp）
target_link_libraries(${BINARY_NAME} PRIVATE "shcore.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
