#ifndef CHILD_WINDOW_STYLE_H_
#define CHILD_WINDOW_STYLE_H_

// desktop_multi_window 在 Windows 侧创建子窗口时把尺寸写死为 800x600@(10,10)、
// 带默认标题栏，并且**只给子引擎注册插件自身的 channel**（见
// multi_window_manager.cc: Create → Win32Window::Create(title, {10,10}, {800,600})
// → InternalMultiWindowPluginRegisterWithRegistrar）。
// 因此子窗口无法使用 window_manager / screen_retriever 等插件做窗口控制
// （child engine 里没有它们的 registrar，调用会 MissingPluginException）。
//
// 子窗口的窗口能力只能在原生侧补齐，本文件做三件事：
//  1. 统一去掉标题栏/边框，置顶且不占任务栏与 Alt+Tab；
//  2. 默认按悬浮面板尺寸摆放到工作区右上角（子窗口不用通道时即保持参考实现悬浮窗外观）；
//  3. 注册 cm/window_native 通道 —— 子引擎用它下达 place 指令，由原生侧按
//     托盘槽位（物理像素）+ 目标显示器 DPI/工作区定位自己（托盘菜单窗口，见
//     lib/windows/tray_menu_window.dart），并可要求“失焦即隐藏”。
//     通道只走 C API（FlutterDesktopPluginRegistrarGetMessenger/SetCallback），
//     消息体是 Dart StringCodec 的裸 UTF-8 文本，字段以 '|' 分隔；标准 codec 与
//     PluginRegistrar 的实现在 flutter_wrapper_plugin 里，runner 没有链它。
//
// |flutter_view_controller| 是插件传给回调的 flutter::FlutterViewController*。
void OnChildWindowCreated(void* flutter_view_controller);

#endif  // CHILD_WINDOW_STYLE_H_
