import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';
import 'windows/floating_window.dart';
import 'windows/tray_menu_window.dart';

/// 入口 —— 还原参考实现启动模型：
///  * 子引擎入口参数 `["multi_window", <windowId>, "floating_window"]`
///    → desktop_multi_window 悬浮窗分支（插件在 C++ 侧固定注入这三个参数）
///  * 第三段为 `tray_menu` → 托盘菜单窗口分支（按托盘槽位贴边的无边框子窗）
///  * `/silent` 参数 → 开机静默启动，仅进托盘（HKLM Run 同款参数）
///  * 单实例：windows_single_instance
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 加载 rust_lib.dll 并注册 frb 分发器（悬浮窗子进程同样需要）
  await RustLib.init();

  if (args.length >= 3 && args[0] == 'multi_window') {
    switch (args[2]) {
      case 'floating_window':
        await mainFloatingWindow(args);
      case 'tray_menu':
        await mainTrayMenuWindow(args);
    }
    return;
  }

  await WindowsSingleInstance.ensureSingleInstance(
      args, 'cm_computer_manager_single');
  await windowManager.ensureInitialized();

  const opts = WindowOptions(
    size: Size(1020, 700),
    minimumSize: Size(960, 640),
    center: true,
    title: 'PC Manager',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    if (args.contains('/silent')) await windowManager.hide();
    // 拦截系统关闭按钮 —— onWindowClose 由 app.dart 的 WindowListener
    // 接管为隐藏到托盘（关窗不退出，与参考实现一致）。
    await windowManager.setPreventClose(true);
  });

  runApp(const ManagerApp());
}
