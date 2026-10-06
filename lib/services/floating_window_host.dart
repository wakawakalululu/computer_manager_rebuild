import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rust_api.dart';

/// 悬浮窗宿主（主窗口侧）—— 负责创建子窗口并按固定节奏推送采集数据。
///
/// 对齐参考实现模型：采集在主窗口进程完成，子窗口只渲染（证据见
/// windows/floating_window.dart 顶部注释）。推送节奏 2s，与首页体检轮询一致。
///
/// 开关偏好持久化在此处（而非页面）：手动开关、启动恢复、子窗口丢失三条路径
/// 都会经过宿主，写在一起的偏好不会与 isRunning 真实状态漂移。
class FloatingWindowHost {
  FloatingWindowHost._();
  static final instance = FloatingWindowHost._();

  static const _argument = 'floating_window';
  static const _period = Duration(seconds: 2);

  /// 偏好键：与设置页其余开关一致，落 SharedPreferences
  static const prefKey = 'floatingWindow';

  WindowController? _controller;
  Timer? _timer;
  int _pushFailures = 0;

  /// 子窗口引擎刚创建时，它的 window channel 可能还没注册完成，此时推送会得到
  /// CHANNEL_UNREGISTERED。这类失败会在后续周期自愈，因此只有连续失败到达上限
  /// 才判定窗口不可用。
  static const _maxPushFailures = 5;

  bool get isRunning => _timer != null;

  /// 启动时恢复上次的悬浮窗开关（与参考实现重启后保持悬浮窗状态一致）。
  ///
  /// 恢复失败不影响主窗口，但必须留痕：这里是 unawaited 调用的，异常不会冒泡。
  Future<void> restoreIfEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(prefKey) ?? false)) return;
    try {
      await open();
    } catch (e) {
      await RustApi.instance.logError('悬浮窗启动恢复失败: $e');
    }
  }

  /// 打开悬浮窗；已打开时幂等。
  ///
  /// 子窗口只能由宿主 show/hide（desktop_multi_window 的 WindowController 没有
  /// close，子引擎里也没有 window_manager 可用），因此首次创建后复用同一个窗口，
  /// 避免每次开关都泄漏一个窗口。
  Future<bool> open() async {
    if (isRunning) return true;
    final controller = _controller ??= await WindowController.create(
      const WindowConfiguration(arguments: _argument, hiddenAtLaunch: true),
    );
    await controller.show();
    _timer = Timer.periodic(_period, (_) => _push());
    _pushFailures = 0;
    await _setPref(true);
    unawaited(_push());
    return true;
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _setPref(false);
    try {
      await _controller?.hide();
    } catch (_) {
      // 窗口已被用户关闭（如退出进程），隐藏失败可忽略
    }
  }

  Future<void> _setPref(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
  }

  Future<void> _push() async {
    final controller = _controller;
    if (controller == null || !isRunning) return;
    try {
      final mem = await RustApi.instance.readMemory2();
      final cpu = await RustApi.instance.readCupInfo();
      final disks = await RustApi.instance.getDiskInfoList();
      // 球上的「加速工具」展开态要知道最满的盘有多满，才能决定这条是不是可操作项
      final maxDiskRatio = disks.isEmpty
          ? 0.0
          : disks.map((d) => d.ratio).reduce((a, b) => a > b ? a : b);
      await controller.invokeMethod<void>('send_data', {
        'usedMemory': mem.used.toString(),
        'totalMemory': mem.total.toString(),
        'cpuUsage': cpu.usage.toStringAsFixed(0),
        'maxDiskRatio': maxDiskRatio.toStringAsFixed(4),
      });
      _pushFailures = 0;
    } catch (e) {
      // 子窗口引擎尚未注册 channel 属正常启动竞态，下一周期重试即可
      if (++_pushFailures < _maxPushFailures) return;
      // 持续失败才判定窗口不可用：停掉节奏并落盘关闭偏好，
      // 避免向死窗口持续写数据、下次启动又拉起一个用户已关掉的窗口
      _timer?.cancel();
      _timer = null;
      _controller = null;
      unawaited(_setPref(false));
      unawaited(RustApi.instance.logError('悬浮窗推送失败: $e'));
    }
  }
}
