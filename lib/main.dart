import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'pages/settings_page.dart';
import 'services/rust_api.dart';
import 'src/rust/frb_generated.dart';
import 'windows/acceleration_tools_window.dart';
import 'windows/floating_window.dart';
import 'windows/tray_menu_window.dart';

/// 窗口尺寸按**实测屏幕**算，不写死一个数。
///
/// 原来恒定 1020×700：本机屏幕 1802×1013 塞得下，但 1366×768 那类小屏
/// （云电脑、老笔记本很常见）高 700 + 标题栏就放不下，底部被切掉——而这正是
/// 参考实现用 `GetSystemMetrics`（`…StructsMonitorInfoGetMonitorSize` /
///
/// `…GetMonitorWorkSize`）去问系统的原因。规则：撑满工作区的 88%，
/// 同时不小于 [minW]×[minH]；屏幕本身更小时就取屏幕尺寸本身——宁可窗口贴边，
/// 也不能让 Flutter 报溢出。
Size windowSizeForScreen({
  required Size screen,
  Size preferred = const Size(1020, 700),
  double fill = 0.88,
  Size minSize = const Size(640, 480),
}) {
  // 逐轴独立决定，三步都只往屏幕内收：
  // 1) 不超过屏幕（硬上限——超出就是底部/右侧被切）
  // 2) 不低于 minSize（太小就没法用了；屏幕自己更小时让位于第 1 条）
  // 3) 在前两条之内，屏幕装得下 preferred 就用 preferred，装不下就按比例撑满
  double axis(double screenV, double want, double minV) {
    final cap = screenV;
    final lo = minV > cap ? cap : minV;
    final hi = want > cap ? cap : want;
    if (hi >= lo) return hi;
    // preferred 与 minSize 都比屏幕大：按比例取屏幕的一部分，至少留一点边
    final scaled = (cap * fill).roundToDouble();
    return scaled < lo ? lo : scaled;
  }

  return Size(axis(screen.width, preferred.width, minSize.width),
      axis(screen.height, preferred.height, minSize.height));
}

/// 两次取尺寸的结果该用哪一个。工作区有效就用工作区，否则退回主屏，
/// 都没有就用 [fallback]。
///
/// 单独拆出来是为了能在**不加载 dll** 的前提下钉住优先级——这条顺序是行为，
/// 不是实现细节：工作区是扣掉任务栏后窗口真正能放的那一片，优先级排错
/// 只会让底边压回任务栏。
Size? pickScreenSize({Size? workArea, Size? primary, Size? fallback}) {
  if (workArea != null && workArea.width > 0 && workArea.height > 0) {
    return workArea;
  }
  if (primary != null && primary.width > 0 && primary.height > 0) {
    return primary;
  }
  return fallback;
}

/// 问系统要**窗口能用的那片屏幕**；问不到就退回 [fallback]，绝不因为拿不到就
/// 开不出窗口。
///
/// 先问主显示器的工作区（已扣掉任务栏等停靠区），失败再退回主屏分辨率
/// （整块屏幕）。原先只有后者：任务栏常年贴底时窗口高度按整屏算，底边正好压在
/// 任务栏上——本机实测整屏 1013 高、真实工作区 973 高，差的那 40 像素就是任务栏。
///
/// 注意工作区只覆盖**主显示器**（`SPI_GETWORKAREA` 的口径），不是全部显示器合起来
/// 那一片；多屏各自的区域这里没枚举。
Future<Size> resolveWindowSize({Size fallback = const Size(1020, 700)}) async {
  Size? work;
  Size? primary;
  try {
    final r = await RustApi.instance.primaryWorkArea();
    work = Size(r.width, r.height);
  } catch (_) {
    // 多显示器工作区读不到（老系统没这组 SM_ 指标）不是致命，往下退
  }
  try {
    final sc = await RustApi.instance.primaryScreenSize();
    primary = Size(sc.width, sc.height);
  } catch (_) {
    // 问不到屏幕就照旧用原来的尺寸：开不出窗口比尺寸不合适更糟
  }
  final picked =
      pickScreenSize(workArea: work, primary: primary, fallback: fallback);
  return picked == null ? fallback : windowSizeForScreen(screen: picked);
}

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

  // 先确保 logs\ 目录存在，**再**装 log 桥：桥一装上就开始写日志，
  // 目录建不出来的话每条日志都会静默失败。
  await RustApi.instance.initBackendDirs();

  // 把 Rust 侧的 log::info!/warn!/error! 接上落盘。**每个子进程都要装**
  // （子引擎各自一份全局 logger），而失败不该拦住启动——日志是辅助，
  // 缺了它程序照样能跑，只是诊断信息少一些。
  unawaited(RustApi.instance.initLogBridge().catchError((_) {}));

  if (args.length >= 3 && args[0] == 'multi_window') {
    switch (args[2]) {
      case 'floating_window':
        await mainFloatingWindow(args);
      case 'tray_menu':
        await mainTrayMenuWindow(args);
      case 'acceleration_tools':
        await mainAccelerationToolsWindow(args);
    }
    return;
  }

  await WindowsSingleInstance.ensureSingleInstance(
      args, 'cm_computer_manager_single');
  await windowManager.ensureInitialized();

  final opts = WindowOptions(
    size: await resolveWindowSize(),
    minimumSize: const Size(640, 480),
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

  // 「阻止云电脑息屏」是系统级效果，只活一次进程。原来**没有任何地方在启动时重放它**，
  // 于是用户开过一次、重启后设置页显示"开"而系统上没生效。
  // **只在主进程做**：悬浮窗/托盘菜单是独立子进程，各持一份 wakelock 没必要也难查。
  unawaited(restoreWakeLock().catchError((_) => false));

  runApp(const ManagerApp());
}
