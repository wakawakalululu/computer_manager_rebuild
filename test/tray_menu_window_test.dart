import 'package:computer_manager/windows/tray_menu_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 托盘菜单窗口的内容：条目、动作回传，以及「逻辑尺寸 == 实际布局」这条
/// 契约 —— 子窗口的物理尺寸由原生按 trayMenuLogicalSize() 乘 DPI 决定，
/// Flutter 撑不开窗口，布局一旦超出这个尺寸就会被裁掉而不是把窗口顶大。
void main() {
  Future<void> pumpMenu(WidgetTester tester, Size box,
      Future<void> Function(TrayMenuAction) onAction) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: TrayMenuBody(onAction: onAction),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('按约定尺寸渲染出全部条目，不溢出', (tester) async {
    final actions = <String>[];
    await pumpMenu(tester, trayMenuLogicalSize(),
        (action) async => actions.add(action.id));

    expect(tester.takeException(), isNull);
    for (final action in TrayMenuAction.values) {
      expect(find.text(action.label), findsOneWidget);
    }
    expect(
        TrayMenuAction.values.map((a) => a.id).toList(), ['showMain', 'quit']);
  });

  testWidgets('点击条目把动作原样回传', (tester) async {
    final actions = <String>[];
    await pumpMenu(tester, trayMenuLogicalSize(),
        (action) async => actions.add(action.id));

    await tester.tap(find.byKey(const ValueKey('tray-menu-quit')));
    await tester.pump();

    expect(actions, ['quit']);
  });

  testWidgets('尺寸比布局小会溢出（说明尺寸必须与条目数同步）', (tester) async {
    await pumpMenu(
        tester,
        Size(trayMenuLogicalSize().width,
            trayMenuLogicalSize().height - kRowHeight),
        (action) async {});

    expect(tester.takeException(), isA<FlutterError>());
  });
}
