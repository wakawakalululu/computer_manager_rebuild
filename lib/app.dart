import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
// tray_manager 0.6 起改为 nativeapi 之上的原生 API：一个 TrayIcon 对象对应一个托盘图标，
// 菜单项各自带点击监听，不再有 trayManager 单例与 TrayListener 混入。
// nativeapi 也导出一个 Image（原生图片句柄），与 Flutter 的 Image 控件同名，这里 hide 掉，
// 托盘图片只用 ImageAsset 扩展取，不需要写出该类型名。
import 'package:tray_manager/tray_manager.dart' hide Image;
import 'package:window_manager/window_manager.dart';

import 'core/routes.dart';
import 'core/theme.dart';
import 'services/acceleration_tools_host.dart';
import 'services/agent_process.dart';
import 'services/click_report.dart';
import 'services/floating_window_host.dart';
import 'services/reminders.dart';
import 'services/rust_api.dart';
import 'services/tray_menu_host.dart';
import 'widgets/common.dart';

/// SmartDialog 弹窗的构建上下文位于 Router 子树之外，拿不到 GoRouter 的
/// InheritedWidget —— 用全局引用兜底导航，由 [_ManagerAppState] 生命周期维护。
GoRouter? _appRouter;

/// 「不再提示」记下以后，点关闭按钮不再问去向，直接收进托盘。
const String kNeverAskCloseWindow = 'never_closeWindow';

class ManagerApp extends StatefulWidget {
  const ManagerApp({super.key});

  @override
  State<ManagerApp> createState() => _ManagerAppState();
}

class _ManagerAppState extends State<ManagerApp> with WindowListener {
  late final GoRouter _router;

  /// 托盘对象必须长期持有：nativeapi 的 Dart 包装器一旦被 GC 就释放原生句柄，
  /// 图标和它的点击监听会一起消失。
  TrayIcon? _trayIcon;

  @override
  void initState() {
    super.initState();
    _router = buildRouter();
    _appRouter = _router;
    windowManager.addListener(this);
    _bindTrayHost();
    _initTray();
    // 上次会话若开着悬浮窗，本次启动直接恢复
    unawaited(FloatingWindowHost.instance.restoreIfEnabled());
    // 常驻采集 agent：守护服务在跑就让位，否则本进程充当会话内守护
    unawaited(ResidentAgentGuard.instance.start());
    // 托盘菜单子窗口的动作要从子引擎回传给主引擎，通道只有主窗口能注册
    unawaited(_registerMainWindowChannel());
  }

  /// 托盘菜单宿主的槽位与自愈路径在这里注入：只有本 State 持有 TrayIcon。
  void _bindTrayHost() {
    final host = TrayMenuHost.instance;
    host.slotProvider = _traySlot;
    host.rebuildTray = _rebuildTray;
  }

  /// 托盘图标槽位（物理像素）。取不到（图标被系统收起/句柄失效）返回空矩形，
  /// 由宿主走「重建托盘」自愈。
  Rect _traySlot() {
    final trayIcon = _trayIcon;
    if (trayIcon == null) return Rect.zero;
    return trayIcon.getBounds();
  }

  /// 托盘初始化 —— nativeapi 一侧全是同步调用；图标失败（如原生层不可用）
  /// 不允许崩掉主进程。
  void _initTray() {
    try {
      final trayIcon = TrayIcon.create();
      if (trayIcon == null) return;
      _trayIcon = trayIcon;
      trayIcon.setVisible(true);
      final image = ImageAsset.fromAsset('assets/branding/tray_icon.png');
      if (image != null) trayIcon.icon = image;
      trayIcon.setTooltip('PC Manager');
      // 右键不挂原生 Menu：参考实现的托盘菜单是按槽位贴边的无边框**子窗口**
      // （见 services/tray_menu_host.dart），原生菜单会把手势吃掉。
      trayIcon.setContextMenuTrigger(ContextMenuTrigger.none);

      trayIcon.addListener((event) {
        switch (event) {
          case TrayIconClickedEvent():
            unawaited(windowManager.show());
          case TrayIconRightClickedEvent():
            unawaited(TrayMenuHost.instance.open());
          default:
            break;
        }
      });

      // 落一行实况到 gui_log：bounds 非空即说明 shell 真的分配到了图标位置。
      // 托盘在自动化里不好截图（Win11 默认把新图标收进溢出浮层），日志比像素可靠。
      final b = _traySlot();
      unawaited(RustApi.instance.logInfo('托盘就绪 visible=${trayIcon.isVisible()} '
          'bounds=${b.isEmpty ? "空" : "${b.left.round()},${b.top.round()} ${b.width.round()}x${b.height.round()}"} '
          'icon=${image == null ? "缺失" : "assets/branding/tray_icon.png"} '
          'menu=子窗口'));
    } catch (e) {
      // 托盘初始化失败仅降级为无托盘，主界面照常可用；但必须留痕，
      // 否则现场无从判断“图标没出现”是没配好还是原生层挂了。
      unawaited(RustApi.instance.logError('托盘初始化失败: $e'));
    }
  }

  /// 「重建托盘」自愈：资源管理器重启、显示器拔插之后，旧句柄上的
  /// getBounds 会一直是空矩形，菜单窗口就没法贴边 —— 重走一遍创建流程。
  Future<void> _rebuildTray() async {
    await RustApi.instance.logInfo('重建托盘');
    _trayIcon?.dispose();
    _trayIcon = null;
    _initTray();
    await RustApi.instance
        .logInfo('重建托盘图标 ${_trayIcon?.isVisible() == true ? "成功" : "失败"}');
  }

  /// 主引擎侧接收托盘菜单子窗口的动作。
  ///
  /// desktop_multi_window 在子引擎里只注册了自己的插件，动作只能靠
  /// window controller 通道跨 isolate 转发；注册失败只降级为“菜单点了没反应”，
  /// 但必须留痕，否则现场无从判断是子窗口没发还是主窗口没收。
  Future<void> _registerMainWindowChannel() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((call) async {
        // 球上长按：把球的屏幕矩形 + 当前占用变成一张贴着球摆的「加速工具」卡
        if (call.method == 'show_tools') {
          final m = Map<Object?, Object?>.from(call.arguments as Map);
          final used = int.tryParse('${m['usedMemory']}') ?? 0;
          final total = int.tryParse('${m['totalMemory']}') ?? 0;
          await AccelToolsHost.instance.openFor(
            ball: Rect.fromLTWH(
                (m['x'] as num).toDouble(),
                (m['y'] as num).toDouble(),
                (m['width'] as num).toDouble(),
                (m['height'] as num).toDouble()),
            memoryRatio: total == 0 ? 0 : used / total,
            maxDiskRatio: (m['maxDiskRatio'] as num?)?.toDouble() ?? 0,
          );
          return null;
        }
        // 工具卡里选中一条：能就地做的就做，需要页面的就唤回主窗口再跳
        if (call.method == 'tool_action') {
          final m = Map<Object?, Object?>.from(call.arguments as Map);
          final route = m['route'] as String?;
          if (route == null) {
            final trimmed =
                await RustApi.instance.processesMemoryOptimization();
            unawaited(
                RustApi.instance.logInfo('加速工具一键加速：整理 $trimmed 个进程的内存占用'));
            return null;
          }
          await windowManager.show();
          await windowManager.focus();
          _appRouter?.push(route);
          return null;
        }
        // 球上右键：宿主负责关掉子窗口并把偏好写成关（否则下次启动又恢复回来）
        if (call.method == 'hide_ball') {
          await FloatingWindowHost.instance.close();
          unawaited(RustApi.instance.logInfo('悬浮球已由球上关闭'));
          return null;
        }
        if (call.method != 'tray_action') return null;
        final action = (call.arguments as Map)['action'];
        switch (action) {
          case 'open':
            await windowManager.show();
            await windowManager.focus();
          case 'settings':
            // 「设置」这条要先唤回主窗再跳过去：菜单是从托盘点的，
            // 窗口可能正藏在托盘里，只导航不显示等于没反应。
            await windowManager.show();
            await windowManager.focus();
            _appRouter?.go('/app_setting_route');
          case 'hideWindow':
            await windowManager.hide();
          case 'closeBall':
            await FloatingWindowHost.instance.close();
            unawaited(RustApi.instance.logInfo('悬浮球已由托盘菜单关闭'));
          case 'quit':
            await windowManager.destroy();
          default:
            unawaited(RustApi.instance.logWarn('未知托盘菜单动作 $action'));
        }
        return null;
      });
      unawaited(RustApi.instance
          .logInfo('托盘菜单动作通道已注册 windowId=${controller.windowId}'));
    } catch (e) {
      unawaited(RustApi.instance.logError('托盘菜单动作通道注册失败: $e'));
    }
  }

  // ── WindowListener（window_manager 0.4.x：方法均为 void 签名）──────

  @override
  void onWindowClose() {
    unawaited(_handleCloseRequest());
  }

  /// 点关闭按钮先问一句去向（参考实现自带「是否要关闭窗口」/「是否最小化」与成对的
  /// 「最小化」「关闭」）。原来是无条件藏进托盘，等于替用户做了决定。
  /// 选过「不再提示」以后按默认动作直接收进托盘——托盘和常驻采集都还在，不会失联。
  Future<void> _handleCloseRequest() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kNeverAskCloseWindow) ?? false) {
      await windowManager.hide();
      return;
    }
    unawaited(SmartDialog.show(
      // 这个确认没有"点空白处算了"的语义：四个去向都得自己选，
      // 遮罩可点会让上面那条 await 的分支变成悬空的。
      clickMaskDismiss: false,
      builder: (_) => CloseWindowCard(
        // 传"此刻有没有任务在跑"，而不是传那句话的快照：弹窗开着的时候
        // 扫描跑完了，提醒要跟着收回去，不能让用户对着一句假话点关闭。
        liveRunningTask: true,
        onMinimize: () {
          SmartDialog.dismiss();
          unawaited(windowManager.hide());
        },
        onClose: () {
          SmartDialog.dismiss();
          unawaited(windowManager.destroy());
        },
        onCancel: () => SmartDialog.dismiss(),
        onNever: () {
          unawaited(prefs.setBool(kNeverAskCloseWindow, true));
          SmartDialog.dismiss();
          unawaited(windowManager.hide());
        },
      ),
    ));
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _trayIcon?.dispose();
    _trayIcon = null;
    // 只停巡检，不回收已常驻的 agent（见 ResidentAgentGuard 类注释）
    ResidentAgentGuard.instance.stop();
    if (identical(_appRouter, _router)) _appRouter = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'PC Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: _router,
      builder: FlutterSmartDialog.init(),
    );
  }
}

/// 阈值告警弹窗 —— 1:1 还原参考实现埋点行为（click_* 事件名照抄）：
///  CPU 超阈值   → click_CPU_window_ProcessManagement（跳进程管理）
///  内存超阈值   → click_RAM_window_expedite（一键加速）
///  系统盘告急   → click_SystemDisk_window_deepclean（深度清理）
///  应用兼容弹窗 → click_AppCompatibility_window_uninstall
///  均含 click_*_cancel / click_*_never（never 落到「设置—高负载提示」里的开关）
class ThresholdPopups {
  ThresholdPopups._();

  /// 跑主动作并把结果/失败摆出来。返回 null = 这个动作没什么好说的。
  static Future<void> _runAndReport(Future<String?> Function() body) async {
    String message;
    try {
      message = await body() ?? '';
    } catch (e) {
      message = '操作失败：${bridgeErrorText(e)}';
    }
    if (message.isEmpty) return;
    // 弹窗已经 dismiss 了，这里紧跟着 showToast（与 onNever 那条同样的坑：
    // 同一帧里 dismiss + showToast 会把提示一起带走，所以要等 dismiss 完成）
    await SmartDialog.dismiss();
    SmartDialog.showToast(message);
  }

  static Future<void> maybeShow({
    required String key,
    required String title,
    required String body,
    required String actionLabel,

    /// 主动作的事件 id（`expedite` / `deepclean` / `ProcessManagement`）。
    /// 按钮文案是中文而事件名是英文标识，不能拿文案拼事件名。
    required String actionId,
    VoidCallback? action,
    String? route,

    /// 动作做完要回报什么。参考实现的弹窗点完会说话（「完成加速」`:60`、
    /// 「加速完成」`:278`），我们原来 `action();` 一句就完事——**返回值丢了、抛错也没人接**：
    /// 用户点了看不到结果，失败了界面上一丝痕迹都没有。
    /// 不传 = 这个动作自己会说（例如它会弹自己的页面/提示），这里就不重复报。
    final Future<String?> Function()? report,
  }) async {
    if (!claimReminder(key)) return; // 入口即认领，防止轮询刷新期间重复排队弹窗
    if (await isReminderMuted(key)) return;

    await SmartDialog.show(builder: (_) {
      return ThresholdPopupCard(
        title: title,
        body: body,
        actionLabel: actionLabel,
        onAction: () {
          reportClick(clickEventFor(key, actionId));
          final reporter = report;
          if (reporter != null) {
            // 结果/失败都要说出来：原来 `action();` 之后就没有下文了
            unawaited(_runAndReport(reporter));
          } else {
            action?.call();
          }
          SmartDialog.dismiss();
          // 弹窗上下文不在 Router 子树内（SmartDialog 覆盖层），
          // 走全局路由引用完成跳转。
          if (route != null) unawaited(_appRouter?.push(route));
        },
        onCancel: () {
          reportClick(clickEventFor(key, 'cancel'));
          SmartDialog.dismiss();
        },
        onNever: () async {
          reportClick(clickEventFor(key, 'never'));
          await setReminderMuted(key, muted: true);
          // 必须先等弹窗关闭动画结束再弹提示：同一帧里 dismiss + showToast，
          // 提示会被这次关闭动作一起带走（实机上量到的是「点了没反应」）。
          await SmartDialog.dismiss();
          // :466 这句是参考实现自己写的落点说明，照着它才该在设置页留重新开启的入口。
          SmartDialog.showToast(kReminderMutedNotice);
        },
      );
    });
  }
}
