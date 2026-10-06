import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/acceleration_tools.dart';
import '../services/click_report.dart';
import '../services/rust_api.dart';

/// 悬浮窗子进程分支 —— 还原参考实现 desktop_multi_window 悬浮窗。
///
/// 参考实现证据：主窗口按固定节奏推送 `{"command":"send_data","data":{"usedMemory":...,
/// "totalMemory":...}}`（见 rust_lib::api::gui_log 的“处理主窗口命令”日志）。
/// 因此子窗口**不自行采集**，只接收主窗口推送并渲染；采集与推送在
/// `services/floating_window_host.dart`。
///
/// desktop_multi_window 0.3.1 的 Windows 实现给子引擎的入口参数固定为
/// `["multi_window", <windowId>, <arguments>]`（multi_window_manager 侧
/// `set_dart_entrypoint_arguments`），故以 `arguments == 'floating_window'` 识别角色。
///
/// 注意：**子引擎里只能用 desktop_multi_window 自身**。插件创建子窗口时只为它
/// 注册了自己的 channel（multi_window_manager.cc），window_manager 等插件在该
/// 引擎没有 registrar，调用会 MissingPluginException；窗口尺寸/无边框/置顶由
/// `windows/runner/floating_window_style.cpp` 在原生创建回调里设定。
Future<void> mainFloatingWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = RustApi.instance;
  final windowId = args.length > 1 ? args[1] : '';

  // 子窗口的异常默认只进 OutputDebugString，release 下等于静默失败；
  // 这里统一落到 gui_log，保证悬浮窗任何一步失败都有痕迹。
  FlutterError.onError = (details) =>
      unawaited(api.logError('悬浮窗框架异常: ${details.exceptionAsString()}'));

  await api.logInfo('悬浮窗子进程已启动 windowId=$windowId');

  final controller = WindowController.fromWindowId(windowId);

  // 接收主窗口推送的数据
  final data = FloatingData.placeholder();
  var logged = false;
  Future<dynamic> handlePush(MethodCall call) async {
    switch (call.method) {
      case 'send_data':
        final m = call.arguments as Map;
        data.update(
          usedMemory: int.tryParse('${m['usedMemory']}') ?? data.used.value,
          totalMemory: int.tryParse('${m['totalMemory']}') ?? data.total.value,
          cpuUsage: double.tryParse('${m['cpuUsage']}') ?? data.cpu.value,
          maxDiskRatio:
              double.tryParse('${m['maxDiskRatio']}') ?? data.maxDisk.value,
        );
        if (!logged) {
          logged = true;
          // 与参考实现同款日志行（证据：rust_lib::api::gui_log “处理主窗口命令”）
          unawaited(api.logInfo('处理主窗口命令 send_data'));
        }
    }
    return null;
  }

  // 插件在 MultiWindowManager::Create 里**先**创建子引擎（Dart main 立即开跑）、
  // **后**注册 native 插件，AOT 下子进程会抢跑，表现为 registerMethodHandler
  // MissingPluginException（JIT 的 debug 因启动慢而侥幸躲过）。注册重试到可用为止。
  var ready = false;
  for (var attempt = 0; attempt < 40 && !ready; attempt++) {
    try {
      await controller.setWindowMethodHandler(handlePush);
      ready = true;
    } on MissingPluginException {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
  if (ready) {
    await api.logInfo('悬浮窗 channel 已就绪');
  } else {
    await api.logError('悬浮窗 channel 注册超时（native 插件未注册）');
  }

  runApp(_FloatingApp(data: data));
}

class _FloatingApp extends StatelessWidget {
  const _FloatingApp({required this.data});
  final FloatingData data;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
          backgroundColor: _kPanelColor, body: FloatingWindowBody(data: data)),
    );
  }
}

/// 原生侧把窗口改成了无边框小面板，Flutter 不支持窗口级透明，
/// 因此面板底色直接铺满（圆角只在视觉上保留为整块深色）。
const Color _kPanelColor = Color(0xF0141A22);

/// 主窗口推送的数据落点；推送到达时 notifyListeners 触发重建。
class FloatingData extends ChangeNotifier {
  final ValueNotifier<int> used;
  final ValueNotifier<int> total;
  final ValueNotifier<double> cpu;

  /// 最满那块盘的占用率，决定展开卡里「深度清理」是不是可操作项
  final ValueNotifier<double> maxDisk;

  FloatingData._(this.used, this.total, this.cpu, this.maxDisk);

  factory FloatingData.placeholder() => FloatingData._(
      ValueNotifier(0), ValueNotifier(0), ValueNotifier(0), ValueNotifier(0));

  void update(
      {required int usedMemory,
      required int totalMemory,
      required double cpuUsage,
      double maxDiskRatio = 0}) {
    used.value = usedMemory;
    total.value = totalMemory;
    cpu.value = cpuUsage;
    maxDisk.value = maxDiskRatio;
    notifyListeners();
  }
}

/// 悬浮球本体。在参考实现那侧它是「加速球」：
/// `zh_strings.txt:473`「实时查看内存使用率，点击即可一键释放内存。」——
/// 点它是释放内存，不是唤回主窗口；成功与失败的文案也是自带的
///（`:278`「加速完成」、`:305`「内存优化错误！」）。
/// `:255`「关闭悬浮球」说明球能自己关掉，这里挂在右键上。
class FloatingWindowBody extends StatefulWidget {
  const FloatingWindowBody(
      {super.key, required this.data, this.accelerate, this.hide, this.onTool});

  final FloatingData data;

  /// 加速与关球都可注入：子引擎里只有 desktop_multi_window 自己，
  /// 单测才能把「上报」「动作」两件事分开。
  final Future<int> Function()? accelerate;
  final Future<void> Function()? hide;

  /// 展开卡里点了某一条（单测用它代替真窗口动作）
  final void Function(AccelTool tool)? onTool;

  @override
  State<FloatingWindowBody> createState() => _FloatingWindowBodyState();
}

class _FloatingWindowBodyState extends State<FloatingWindowBody> {
  bool _busy = false;
  String? _flash;
  Timer? _flashTimer;

  /// 展开态：球自己的「加速工具」卡。子窗口不能改尺寸（desktop_multi_window 的
  /// WindowController 只有 show/hide），所以卡是画在球这 200x104 里的紧凑版。
  bool _expanded = false;

  Future<void> _runTool(AccelTool tool) async {
    if (widget.onTool != null) return widget.onTool!(tool);
    if (tool.route != null) {
      await _openRouteInMainWindow(tool.route!);
      return;
    }
    await _onTap();
  }

  /// 展开卡只列真能执行的条目（参考实现「隐藏不可操作项」的字面实现）
  List<AccelTool> _tools(FloatingData data) => accelerationTools(
        memoryRatio:
            data.total.value == 0 ? 0 : data.used.value / data.total.value,
        maxDiskRatio: data.maxDisk.value,
      );

  Widget _card(List<AccelTool> tools) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('加速工具',
            style: TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 2),
        if (tools.isEmpty)
          const Text(accelToolsEmptyMessage,
              style: TextStyle(color: Colors.white54, fontSize: 11))
        else
          for (final t in tools)
            InkWell(
              onTap: () => unawaited(_runTool(t)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(t.label,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
      ],
    );
  }

  /// 点一次球后的提示，两秒后回到占用读数
  void _flashFor(String text) {
    _flashTimer?.cancel();
    setState(() => _flash = text);
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  Future<void> _onTap() async {
    if (_busy) return; // 释放过程中不叠第二次
    reportClick('click_ball');
    setState(() => _busy = true);
    try {
      await (widget.accelerate ??
          RustApi.instance.processesMemoryOptimization)();
      _flashFor('加速完成');
    } catch (e) {
      _warn('悬浮球加速失败: $e');
      _flashFor('内存优化错误！');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onSecondaryTap() {
    unawaited((widget.hide ?? _hideBallViaMainEngine)());
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.data,
      builder: (_, __) {
        final data = widget.data;
        final ratio =
            data.total.value == 0 ? 0.0 : data.used.value / data.total.value;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          // 展开用长按而不是双击：GestureDetector 一旦同时挂 onTap 与 onDoubleTap，
          // 每次单击都要先等 300ms 的双击判定窗口，主动作「点一下就释放内存」会变钝。
          onLongPress: () => setState(() => _expanded = !_expanded),
          onSecondaryTap: _onSecondaryTap,
          child: Container(
            color: _kPanelColor,
            padding: const EdgeInsets.all(10),
            child: _expanded
                ? _card(_tools(data))
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        const Text('CPU / 内存',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(
                          data.total.value == 0
                              ? '-- / --'
                              : '${data.cpu.value.toStringAsFixed(0)}% / ${(ratio * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _flash ??
                              (data.total.value == 0
                                  ? '等待主窗口推送…'
                                  : '${(data.used.value >> 30)}G / ${(data.total.value >> 30)}G'),
                          style: TextStyle(
                              color: _flash == null
                                  ? Colors.white54
                                  : Colors.white,
                              fontSize: 10),
                        ),
                      ]),
          ),
        );
      },
    );
  }
}

/// 留痕不能反过来打断球：子引擎里桥可能还没就绪（或单测里根本没有桥），
/// 记不上日志就把异常抛回用户点击的动作上，是本末倒置。
void _warn(String message) {
  try {
    unawaited(RustApi.instance.logWarn(message));
  } catch (_) {}
}

/// 展开卡里的跳转条目：子引擎没有路由，只能把「去哪个页面」告诉主引擎，
/// 由它唤回主窗口并导航过去。
Future<void> _openRouteInMainWindow(String route) async {
  try {
    final windows = await WindowController.getAll();
    final main = windows.where((w) => w.arguments.isEmpty).toList();
    if (main.isEmpty) {
      _warn('加速工具跳转 $route：找不到主窗口引擎（${windows.length} 个子窗口）');
      return;
    }
    await main.first.invokeMethod<void>('open_route', {'route': route});
  } catch (e) {
    _warn('加速工具跳转 $route 失败: $e');
  }
}

/// 关球要由宿主做（子窗口只能 hide/show，且关掉后要把偏好写成关，
/// 否则下次启动又会恢复出来）。子引擎没有 window_manager 的 registrar，
/// 只能走 desktop_multi_window 自己的通道通知主引擎。
Future<void> _hideBallViaMainEngine() async {
  try {
    final windows = await WindowController.getAll();
    final main = windows.where((w) => w.arguments.isEmpty).toList();
    if (main.isEmpty) {
      _warn('关闭悬浮球：找不到主窗口引擎（${windows.length} 个子窗口）');
      return;
    }
    await main.first.invokeMethod<void>('hide_ball');
  } catch (e) {
    _warn('关闭悬浮球失败: $e');
  }
}
