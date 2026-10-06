import 'dart:ui' show Rect;

import 'package:computer_manager/services/tray_menu_host.dart';
import 'package:flutter_test/flutter_test.dart';

/// 托盘菜单宿主的流程：槽位来源、定位时机、「重建托盘」自愈、失败兜底。
/// 真实窗口要用 desktop_multi_window + 原生通道，这里全部走注入的替身。

class _FakeWindow implements TrayMenuWindow {
  _FakeWindow({this.applied = const {}});

  /// 原生 place 指令回传的窗口矩形，宿主原样落到 gui_log
  final Map<Object?, Object?> applied;
  final List<Rect> slots = [];
  var showCount = 0;
  var setSlotFailures = 0;

  @override
  Future<Map<Object?, Object?>> setSlot(Rect slot) async {
    if (setSlotFailures > 0) {
      setSlotFailures--;
      throw StateError('子窗口无响应');
    }
    slots.add(slot);
    return applied;
  }

  @override
  Future<void> show() async => showCount++;
}

void main() {
  test('槽位为空先走「重建托盘」自愈，自愈成功就正常开菜单', () async {
    final logs = <String>[];
    final windows = <_FakeWindow>[];
    final slots = <Rect>[Rect.zero, const Rect.fromLTWH(2008, 1390, 40, 50)];
    var rebuilt = 0;

    final host = TrayMenuHost(
      createWindow: () async {
        final window = _FakeWindow(
            applied: const {'x': 1810, 'y': 1314, 'width': 238, 'scale': 1.25});
        windows.add(window);
        return window;
      },
      log: logs.add,
      logError: logs.add,
      onUnplaceable: () async {},
    );
    host.slotProvider = () => slots.isEmpty ? Rect.zero : slots.removeAt(0);
    host.rebuildTray = () async => rebuilt++;

    await host.open();

    expect(rebuilt, 1);
    expect(logs, contains('更新托盘菜单位置失败，重建托盘'));
    expect(logs, contains('托盘菜单控制器不存在，开始创建新窗口'));
    expect(windows, hasLength(1));
    expect(windows.single.slots, [const Rect.fromLTWH(2008, 1390, 40, 50)]);
    expect(windows.single.showCount, 1);
    expect(logs.last,
        '托盘菜单窗口属性设置成功 1810,1314 238xnull scale=1.25 槽位=2008,1390 40x50');
  });

  test('重建托盘后仍无槽位：不开菜单，走唤回主界面兜底', () async {
    final logs = <String>[];
    var created = 0;
    var fallback = 0;

    final host = TrayMenuHost(
      createWindow: () async {
        created++;
        return _FakeWindow();
      },
      log: logs.add,
      logError: logs.add,
      onUnplaceable: () async => fallback++,
    );
    host.slotProvider = () => Rect.zero;
    host.rebuildTray = () async {};

    await host.open();

    expect(created, 0);
    expect(fallback, 1);
    expect(logs, contains('重建托盘图标后仍无槽位，放弃菜单窗口'));
  });

  test('同一个菜单窗口只创建一次，后续右键只更新槽位', () async {
    final windows = <_FakeWindow>[];

    final host = TrayMenuHost(
      createWindow: () async {
        final window = _FakeWindow();
        windows.add(window);
        return window;
      },
      log: (_) {},
      logError: (_) {},
      onUnplaceable: () async {},
    );
    host.slotProvider = () => const Rect.fromLTWH(100, 200, 30, 30);

    await host.open();
    await host.open();

    expect(windows, hasLength(1));
    expect(windows.single.slots, hasLength(2));
    expect(windows.single.showCount, 2);
  });

  test('定位失败时不 show，连续失败后丢弃窗口重建', () async {
    final logs = <String>[];
    final windows = <_FakeWindow>[];

    final host = TrayMenuHost(
      createWindow: () async {
        final window = _FakeWindow()..setSlotFailures = 99;
        windows.add(window);
        return window;
      },
      log: logs.add,
      logError: logs.add,
      onUnplaceable: () async {},
    );
    host.slotProvider = () => const Rect.fromLTWH(100, 200, 30, 30);

    for (var i = 0; i < 4; i++) {
      await host.open();
    }

    // 前 3 次复用同一个坏窗口，第 4 次才重新创建
    expect(windows, hasLength(2));
    expect(windows.every((window) => window.showCount == 0), isTrue);
    expect(logs, contains('托盘菜单窗口连续 3 次打开失败，丢弃后重建'));
  });
}
