import 'dart:async';
import 'dart:ui' show Rect;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';

import 'rust_api.dart';

/// 托盘菜单窗口的操作接口 —— 把 desktop_multi_window 的交互收在一处，
/// 宿主流程（槽位、自愈、日志）可脱离真实窗口做单元测试。
abstract class TrayMenuWindow {
  /// 推送托盘图标槽位（物理像素），等子窗口完成定位后返回原生实际应用的窗口矩形。
  Future<Map<Object?, Object?>> setSlot(Rect slot);

  Future<void> show();
}

typedef TrayMenuWindowFactory = Future<TrayMenuWindow> Function();

/// 真实实现：desktop_multi_window 子窗口 + 子引擎里的 `cm/window_native` 定位。
class MultiWindowTrayMenu implements TrayMenuWindow {
  MultiWindowTrayMenu(this._controller);

  /// 子窗口入口参数（`lib/main.dart` 按它分派到 `mainTrayMenuWindow`）
  static const argument = 'tray_menu';

  static Future<TrayMenuWindow> create() async => MultiWindowTrayMenu(
        await WindowController.create(
            WindowConfiguration(arguments: argument, hiddenAtLaunch: true)),
      );

  final WindowController _controller;

  /// 子引擎刚创建时它的 window channel 可能还没注册完（插件先建引擎、后注册
  /// 插件），这类失败会在重试内自愈；耗尽重试才判定窗口不可用。
  static const _maxAttempts = 20;

  @override
  Future<Map<Object?, Object?>> setSlot(Rect slot) async {
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        final applied = await _controller.invokeMethod<Map<Object?, Object?>>(
          'set_slot',
          {
            'x': slot.left,
            'y': slot.top,
            'width': slot.width,
            'height': slot.height,
          },
        );
        return applied ?? const {};
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    throw StateError('托盘菜单子窗口无响应: $lastError');
  }

  @override
  Future<void> show() => _controller.show();
}

/// 托盘菜单宿主（主窗口侧）。
///
/// 与参考实现一致的行为：右键托盘 → 按 `TrayIcon.getBounds()` 的槽位贴边显示
/// 无边框菜单子窗口；槽位取不到走「重建托盘」自愈；失败落 gui_log，
/// 便于现场判断是托盘没了还是子窗口没起来。
///
/// 子窗口只能由主窗口 isolate 创建（`WindowController.create` 走当前引擎的
/// 插件），所以宿主常驻主窗口，由 `lib/app.dart` 注入槽位来源与重建动作。
class TrayMenuHost {
  TrayMenuHost({
    TrayMenuWindowFactory? createWindow,
    void Function(String message)? log,
    void Function(String message)? logError,
    Future<void> Function()? onUnplaceable,
  })  : _createWindow = createWindow ?? MultiWindowTrayMenu.create,
        _log = log ?? ((m) => unawaited(RustApi.instance.logInfo(m))),
        _logError =
            logError ?? ((m) => unawaited(RustApi.instance.logError(m))),
        onUnplaceable = onUnplaceable ?? (() => windowManager.show());

  /// 主窗口常驻的单例；测试里直接构造实例并注入替身。
  static final instance = TrayMenuHost();

  /// 连续失败到达这个数量就放弃当前窗口，下次重新创建一个。
  /// 子窗口没有标题栏与系统菜单，正常不会被用户关掉，因此真正常见的是
  /// channel 一直注册不上（子引擎挂了），留着它只会永远打不开菜单。
  static const _maxOpenFailures = 3;

  final TrayMenuWindowFactory _createWindow;
  final void Function(String message) _log;
  final void Function(String message) _logError;

  /// 兜底动作：菜单摆不出来时做什么（默认唤回主界面，不让用户点了没反应）
  final Future<void> Function() onUnplaceable;

  /// 托盘图标槽位来源（物理像素），由 app.dart 注入
  Rect Function() slotProvider = () => Rect.zero;

  /// 重建托盘图标，由 app.dart 注入
  Future<void> Function() rebuildTray = () async {};

  TrayMenuWindow? _window;
  int _failures = 0;

  bool get isOpen => _window != null;

  Future<void> open() async {
    _log('开始创建托盘菜单窗口');
    var slot = slotProvider();
    if (slot.isEmpty) {
      // 参考实现的自愈路径：托盘句柄还在但取不到图标槽位（图标被系统收起或重排），
      // 先重建托盘再取一次。
      _log('更新托盘菜单位置失败，重建托盘');
      await rebuildTray();
      slot = slotProvider();
    }
    if (slot.isEmpty) {
      _log('重建托盘图标后仍无槽位，放弃菜单窗口');
      await onUnplaceable();
      return;
    }

    try {
      final window = _window ??= await _createWindowWithLog();
      final applied = await window.setSlot(slot);
      // 定位成功后才 show：hiddenAtLaunch 下窗口一直是隐藏的，
      // 先摆好位置再显示，不会看到插件默认创建的 800x600 闪一下。
      await window.show();
      _failures = 0;
      _log('托盘菜单窗口属性设置成功 '
          '${applied['x']},${applied['y']} ${applied['width']}x${applied['height']} '
          'scale=${applied['scale']} 槽位=${slot.left.round()},${slot.top.round()} '
          '${slot.width.round()}x${slot.height.round()}');
    } catch (e) {
      _logError('托盘菜单窗口打开失败: $e');
      if (++_failures >= _maxOpenFailures) {
        _window = null;
        _failures = 0;
        _logError('托盘菜单窗口连续 $_maxOpenFailures 次打开失败，丢弃后重建');
      }
      await onUnplaceable();
    }
  }

  Future<TrayMenuWindow> _createWindowWithLog() async {
    _log('托盘菜单控制器不存在，开始创建新窗口');
    return _createWindow();
  }
}
