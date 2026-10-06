import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/rust_api.dart';

/// 托盘菜单窗口（子引擎分支）—— 还原参考实现的「托盘菜单窗口」。
///
/// 参考实现证据：`classes.txt` 里有 `_TrayMenuComponentState`，`zh_strings.txt`
/// 里有「开始创建托盘菜单窗口」「托盘菜单控制器不存在，开始创建新窗口」
/// 「托盘菜单窗口属性设置成功」「更新托盘菜单位置失败」「重建托盘」，
/// 即点托盘后**按托盘图标槽位定位的无边框子窗口**（与悬浮窗同一套
/// desktop_multi_window 机制），而不是原生右键菜单。
///
/// 分工：主窗口侧（`services/tray_menu_host.dart`）取 `TrayIcon.getBounds()`
/// 槽位并推给这里；这里把槽位转交原生 `cm/window_native` 通道，由原生按目标
/// 显示器 DPI 换算尺寸、贴着槽位上沿摆放并夹取到工作区（子引擎里没有
/// window_manager / screen_retriever 的 registrar，窗口尺寸/无边框/置顶只能
/// 在原生侧做，见 `windows/runner/child_window_style.h`）。
///
/// 菜单项点击后把动作回传给主窗口引擎（`getAll()` 里 arguments 为空的那个就是
/// 主窗口），再由自己 `hide()`；点到窗口之外由原生侧失焦收起。
Future<void> mainTrayMenuWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = RustApi.instance;
  final windowId = args.length > 1 ? args[1] : '';

  // 子引擎的异常默认只进 OutputDebugString，release 下等于静默失败
  FlutterError.onError = (details) =>
      unawaited(api.logError('托盘菜单框架异常: ${details.exceptionAsString()}'));

  await api.logInfo('托盘菜单子进程已启动 windowId=$windowId');

  final controller = WindowController.fromWindowId(windowId);

  Future<dynamic> handlePush(MethodCall call) async {
    if (call.method != 'set_slot') return null;
    final slot = Map<Object?, Object?>.from(call.arguments as Map);
    final size = trayMenuLogicalSize();
    try {
      // 文本协议见 windows/runner/child_window_style.cpp —— runner 没有链接
      // flutter_wrapper_plugin，标准 codec 在那里，所以原生侧只收 StringCodec。
      final request = 'place|${_px(slot['x'])}|${_px(slot['y'])}'
          '|${_px(slot['width'])}|${_px(slot['height'])}'
          '|${size.width.round()}|${size.height.round()}'
          // 菜单语义：点到别处就收起
          '|1|PC Manager · 托盘菜单';
      final reply = await _nativeChannel.send(request);
      if (reply == null) throw StateError('原生侧无应答');
      final applied = _parsePlaced(reply);
      await api.logInfo('托盘菜单已定位 '
          '${applied['x']},${applied['y']} ${applied['width']}x${applied['height']} '
          'scale=${applied['scale']} 失焦收起=${applied['hideOnDeactivate']}');
      return applied;
    } catch (e) {
      await api.logError('托盘菜单定位失败: $e');
      rethrow;
    }
  }

  // 与悬浮窗同样的启动竞态：插件先建子引擎（Dart main 立即开跑）、后注册插件，
  // AOT 下这里会抢跑得到 MissingPluginException，重试到可用为止。
  var ready = false;
  for (var attempt = 0; attempt < 40 && !ready; attempt++) {
    try {
      await controller.setWindowMethodHandler(handlePush);
      ready = true;
    } on MissingPluginException {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }
  await api
      .logInfo(ready ? '托盘菜单 channel 已就绪' : '托盘菜单 channel 注册超时（native 插件未注册）');

  runApp(_TrayMenuApp(controller: controller));
}

/// 与原生侧约定的逻辑尺寸：窗口物理尺寸由原生按这个尺寸乘目标显示器 DPI 决定，
/// Flutter 侧撑不开窗口，所以它必须与 `TrayMenuBody` 的布局严格一致
/// （`test/tray_menu_window_test.dart` 按这个尺寸排版验溢出）。
const double kMenuWidth = 190;
const double kRowHeight = 32;
const double kVerticalPadding = 6;

Size trayMenuLogicalSize() => Size(kMenuWidth,
    kRowHeight * TrayMenuAction.values.length + kVerticalPadding * 2);

const _nativeChannel =
    BasicMessageChannel<String>('cm/window_native', StringCodec());

int _px(Object? value) => (value as num).round();

/// 解析原生侧 place 的应答：`placed|X|Y|宽|高|缩放|失焦收起`，失败为 `err|原因`。
/// 键名与 `TrayMenuHost` 的日志约定一致。
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
    'hideOnDeactivate': fields.length > 6 && fields[6] == '1',
  };
}

/// 菜单条目。动作都由子引擎回传给主引擎执行 —— 子窗口里没有窗口插件可用，
/// 唤回主界面/退出进程只能由主窗口那边做。
enum TrayMenuAction {
  showMain('showMain', '显示主界面'),
  quit('quit', '退出');

  const TrayMenuAction(this.id, this.label);
  final String id;
  final String label;
}

class _TrayMenuApp extends StatelessWidget {
  const _TrayMenuApp({required this.controller});
  final WindowController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: _kMenuBackground,
        body: TrayMenuBody(onAction: (action) => _dispatch(controller, action)),
      ),
    );
  }
}

const Color _kMenuBackground = Color(0xFF1C222B);

class TrayMenuBody extends StatelessWidget {
  const TrayMenuBody({super.key, required this.onAction});

  /// 动作出口：真实实现是 `_dispatch`（转发主引擎 + 收起菜单），
  /// 注入出来是为了让条目与尺寸能在 widget test 里核对。
  final Future<void> Function(TrayMenuAction action) onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kMenuBackground,
      padding: const EdgeInsets.symmetric(vertical: kVerticalPadding),
      child: Column(
        children: [
          for (final action in TrayMenuAction.values)
            InkWell(
              key: ValueKey('tray-menu-${action.id}'),
              onTap: () => unawaited(onAction(action)),
              child: SizedBox(
                height: kRowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(action.label,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把动作送到主引擎，再由自己收起。
Future<void> _dispatch(
    WindowController controller, TrayMenuAction action) async {
  final api = RustApi.instance;
  try {
    await _notifyMainWindow(action);
    await api.logInfo('托盘菜单动作 ${action.id}');
  } catch (e) {
    await api.logError('托盘菜单动作失败 ${action.id}: $e');
  }
  try {
    // 动作已经送到，先收起菜单；主窗口若被唤回会自己置前
    await controller.hide();
  } catch (_) {
    // 退出动作会让进程结束，此时隐藏失败无所谓
  }
}

/// 子引擎 → 主引擎：desktop_multi_window 的 window controller 通道按
/// `arguments` 区分角色，主窗口的 arguments 为空。
Future<void> _notifyMainWindow(TrayMenuAction action) async {
  final windows = await WindowController.getAll();
  final main = windows.where((w) => w.arguments.isEmpty).toList();
  if (main.isEmpty) {
    throw StateError('找不到主窗口引擎（${windows.length} 个子窗口）');
  }
  await main.first.invokeMethod<void>('tray_action', {'action': action.id});
}
