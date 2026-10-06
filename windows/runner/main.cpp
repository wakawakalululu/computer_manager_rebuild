#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

// desktop_multi_window 提供的“子窗口已创建”回调（插件 DLL 导出）
#include <desktop_multi_window/desktop_multi_window_plugin.h>

#include "child_window_style.h"
#include "flutter_window.h"
#include "utils.h"

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

  // 子窗口由 desktop_multi_window 以固定 800x600 + 默认标题栏创建，且子引擎内
  // 没有 window_manager 等插件的 registrar，样式与定位只能在原生侧做。
  // 回调对每一类子窗口（悬浮窗 / 托盘菜单窗）通用，角色差异由子引擎通过
  // cm/window_native 通道自己声明，见 child_window_style.h。
  DesktopMultiWindowSetWindowCreatedCallback(&OnChildWindowCreated);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"computer_manager", origin, size)) {
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
