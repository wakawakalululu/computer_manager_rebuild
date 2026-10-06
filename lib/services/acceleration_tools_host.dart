import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'acceleration_tools.dart';
import 'rust_api.dart';

/// 加速工具卡窗口的操作接口 —— 把 desktop_multi_window 的交互收在一处，
/// 宿主流程（槽位、条目、日志）可脱离真实窗口做单元测试。
abstract class AccelToolsWindow {
  /// 推槽位（球的屏幕矩形，物理像素）与条目清单，等子窗口原生定位后回实际矩形。
  Future<Map<Object?, Object?>> setSlot(
      {required Rect ball, required List<AccelTool> tools});

  Future<void> show();
}

typedef AccelToolsWindowFactory = Future<AccelToolsWindow> Function();

/// 真实实现：desktop_multi_window 子窗口 + 子引擎里的 `cm/window_native` 定位。
class MultiWindowAccelTools implements AccelToolsWindow {
  MultiWindowAccelTools(this._controller);

  static const argument = 'acceleration_tools';

  static Future<AccelToolsWindow> create() async => MultiWindowAccelTools(
        await WindowController.create(
            WindowConfiguration(arguments: argument, hiddenAtLaunch: true)),
      );

  final WindowController _controller;

  static const _maxAttempts = 20;

  @override
  Future<Map<Object?, Object?>> setSlot(
      {required Rect ball, required List<AccelTool> tools}) async {
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        final applied = await _controller
            .invokeMethod<Map<Object?, Object?>>('set_slot', {
          'x': ball.left,
          'y': ball.top,
          'width': ball.width,
          'height': ball.height,
          'tools': [
            for (final t in tools) {'id': t.id, 'label': t.label, 'route': t.route}
          ],
        });
        return applied ?? const {};
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    throw StateError('加速工具卡子窗口无响应: $lastError');
  }

  @override
  Future<void> show() => _controller.show();
}

/// 加速工具卡宿主（主窗口侧）。
///
/// 球只能报出自己的矩形和占用数据，卡片的创建与定位都由这里做：
/// 子窗口只能由主窗口 isolate 创建（`WindowController.create` 走当前引擎的插件）。
class AccelToolsHost {
  AccelToolsHost({
    AccelToolsWindowFactory? createWindow,
    void Function(String message)? log,
    void Function(String message)? logError,
  })  : _createWindow = createWindow ?? MultiWindowAccelTools.create,
        _log = log ?? ((m) => unawaited(RustApi.instance.logInfo(m))),
        _logError =
            logError ?? ((m) => unawaited(RustApi.instance.logError(m)));

  static final instance = AccelToolsHost();

  /// 连续失败到这个数量就丢弃当前窗口重建（同托盘菜单宿主的判断）。
  static const _maxOpenFailures = 3;

  final AccelToolsWindowFactory _createWindow;
  final void Function(String message) _log;
  final void Function(String message) _logError;

  AccelToolsWindow? _window;
  int _failures = 0;

  bool get isOpen => _window != null;

  /// 卡片最多能占的高度（条目全开时）；宿主按条目数算，日志里好核对。
  static Size cardSize(int itemCount) => Size(
      190, 28 + 32 * (itemCount == 0 ? 1 : itemCount) + 6 * 2);

  /// 按实测占用开卡。条目在这里算，宿主与测试共用同一份规则。
  Future<void> openFor({
    required Rect ball,
    required double memoryRatio,
    required double maxDiskRatio,
  }) async {
    final tools = accelerationTools(
        memoryRatio: memoryRatio, maxDiskRatio: maxDiskRatio);
    _log('打开加速工具卡 内存=${(memoryRatio * 100).round()}% '
        '最满盘=${(maxDiskRatio * 100).round()}% 可执行项=${tools.length}');
    try {
      final window = _window ??= await _createWindow();
      final applied = await window.setSlot(ball: ball, tools: tools);
      await window.show();
      _failures = 0;
      _log('加速工具卡已就绪 ${applied['x']},${applied['y']} '
          '${applied['width']}x${applied['height']} 需要高度='
          '${cardSize(tools.length).height.round()}');
    } catch (e) {
      _logError('加速工具卡打开失败: $e');
      if (++_failures >= _maxOpenFailures) {
        _window = null;
        _failures = 0;
        _logError('加速工具卡连续 $_maxOpenFailures 次打开失败，丢弃后重建');
      }
    }
  }
}
