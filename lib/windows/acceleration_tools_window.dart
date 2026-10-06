import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/acceleration_tools.dart';
import '../services/rust_api.dart';

/// 加速工具卡（子引擎分支）—— 参考实现的 `_AccelerationToolsCardItemState`。
///
/// 分工与托盘菜单窗口同一套路：球只负责把自己的屏幕矩形和当前占用数据交给主引擎，
/// 主引擎创建/复用这张卡并把槽位推过来；卡片自己走原生 `place` 贴到球旁边
///（子引擎里没有 window_manager / screen_retriever 的 registrar，尺寸与位置只能
/// 在原生侧定，见 `windows/runner/child_window_style.cpp`）。
///
/// 条目由 [accelerationTools] 按实测占用算出来：只列真能执行的项，
/// 一条都没有时显示空态而不是摆一张假卡。
Future<void> mainAccelerationToolsWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = RustApi.instance;
  final windowId = args.length > 1 ? args[1] : '';

  FlutterError.onError = (details) =>
      unawaited(api.logError('加速工具卡框架异常: ${details.exceptionAsString()}'));

  final controller = WindowController.fromWindowId(windowId);

  /// 条目走 ValueNotifier：`set_slot` 到达时子引擎的 widget 树往往已经建好了，
  /// 不 notifyListeners 的话窗口按新条目数开了、内容却停在旧列表上
  /// （第一次实机就是这样：日志算出 2 条，屏幕上仍是空态）。
  final items = ValueNotifier<List<AccelTool>>(const []);

  Future<dynamic> handlePush(MethodCall call) async {
    if (call.method != 'set_slot') return null;
    final m = Map<Object?, Object?>.from(call.arguments as Map);
    items.value = (m['tools'] as List)
        .cast<Map<Object?, Object?>>()
        .map((t) => AccelTool(
            id: '${t['id']}',
            label: '${t['label']}',
            route: t['route'] as String?))
        .toList();
    final size = accelToolsLogicalSize(items.value.length);
    try {
      final request = 'place|${_px(m['x'])}|${_px(m['y'])}'
          '|${_px(m['width'])}|${_px(m['height'])}'
          '|${size.width.round()}|${size.height.round()}'
          // 卡片语义：点到别处就收起
          '|1|PC Manager · 加速工具';
      final reply = await _nativeChannel.send(request);
      if (reply == null) throw StateError('原生侧无应答');
      final applied = _parsePlaced(reply);
      await api.logInfo('加速工具卡已定位 '
          '${applied['x']},${applied['y']} ${applied['width']}x${applied['height']}');
      return applied;
    } catch (e) {
      await api.logError('加速工具卡定位失败: $e');
      rethrow;
    }
  }

  // 与悬浮窗/托盘菜单同样的启动竞态：插件先建子引擎、后注册插件，
  // AOT 下会抢跑成 MissingPluginException，重试到可用为止。
  var ready = false;
  for (var attempt = 0; attempt < 40 && !ready; attempt++) {
    try {
      await controller.setWindowMethodHandler(handlePush);
      ready = true;
    } on MissingPluginException {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
  await api.logInfo(
      ready ? '加速工具卡 channel 已就绪' : '加速工具卡 channel 注册超时（native 插件未注册）');

  runApp(_AccelToolsApp(controller: controller, items: items));
}

/// 卡片尺寸：标题一行 + 每条一行；原生按这个逻辑尺寸乘目标显示器 DPI 开窗口，
/// 所以它必须与 `AccelToolsBody` 的布局严格一致（有测试按这个尺寸验溢出）。
const double kToolsWidth = 190;
const double kToolsTitleHeight = 28;
const double kToolsRowHeight = 32;
const double kToolsVerticalPadding = 6;

Size accelToolsLogicalSize(int itemCount) => Size(
    kToolsWidth,
    kToolsTitleHeight +
        kToolsRowHeight * (itemCount == 0 ? 1 : itemCount) +
        kToolsVerticalPadding * 2);

const _nativeChannel =
    BasicMessageChannel<String>('cm/window_native', StringCodec());

int _px(Object? value) => (value as num).round();

Map<Object?, Object?> _parsePlaced(String reply) {
  final fields = reply.split('|');
  if (fields.first != 'placed' || fields.length < 6) {
    throw StateError('原生定位失败: $reply');
  }
  return <Object?, Object?>{
    'x': int.parse(fields[1]),
    'y': int.parse(fields[2]),
    'width': int.parse(fields[3]),
    'height': int.parse(fields[4]),
    'scale': double.parse(fields[5]),
  };
}

class _AccelToolsApp extends StatelessWidget {
  const _AccelToolsApp({required this.controller, required this.items});

  final WindowController controller;
  final ValueNotifier<List<AccelTool>> items;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: const Color(0xF0141A22),
        body: ListenableBuilder(
          listenable: items,
          builder: (_, __) => AccelToolsBody(
            tools: items.value,
            onTool: (tool) =>
                unawaited(_dispatch(controller, tool, items.value.length)),
          ),
        ),
      ),
    );
  }
}

/// 卡片内容。动作一律回传给主引擎执行（子窗口里没有路由也没有 Rust 侧的写操作）。
class AccelToolsBody extends StatelessWidget {
  const AccelToolsBody({super.key, required this.tools, required this.onTool});

  final List<AccelTool> tools;
  final void Function(AccelTool tool) onTool;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kToolsVerticalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: kToolsTitleHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('加速工具',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ),
          ),
          if (tools.isEmpty)
            SizedBox(
              height: kToolsRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(accelToolsEmptyMessage,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ),
            )
          else
            for (final t in tools)
              InkWell(
                onTap: () => onTool(t),
                child: SizedBox(
                  height: kToolsRowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(t.label,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 把选中的条目送到主引擎，再由自己收起。
Future<void> _dispatch(
    WindowController controller, AccelTool tool, int itemCount) async {
  final api = RustApi.instance;
  try {
    final windows = await WindowController.getAll();
    final main = windows.where((w) => w.arguments.isEmpty).toList();
    if (main.isEmpty) {
      throw StateError('找不到主窗口引擎（${windows.length} 个子窗口）');
    }
    await main.first.invokeMethod<void>(
        'tool_action', {'id': tool.id, 'route': tool.route});
    await api.logInfo('加速工具动作 ${tool.id}');
  } catch (e) {
    await api.logError('加速工具动作失败 ${tool.id}: $e');
  }
  try {
    await controller.hide();
  } catch (_) {
    // 主窗口被关掉时子引擎可能已经没了，收起失败无所谓
  }
}
