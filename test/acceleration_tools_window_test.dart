import 'package:computer_manager/services/acceleration_tools.dart';
import 'package:computer_manager/windows/acceleration_tools_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 加速工具卡的内容与尺寸契约：原生按 accelToolsLogicalSize 开窗口，
/// Flutter 撑不开窗口，所以布局必须与该尺寸严格一致（超出就是真机上的裁切）。
void main() {
  Future<void> pumpCard(WidgetTester tester, List<AccelTool> tools,
      {required void Function(AccelTool) onTool}) async {
    final size = accelToolsLogicalSize(tools.length);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: size.width,
        height: size.height,
        child: Material(
            child: AccelToolsBody(tools: tools, onTool: onTool)),
      ),
    ));
  }

  test('卡片高度按条目数长，一条不留也要容得下空态', () {
    expect(accelToolsLogicalSize(1).height, accelToolsLogicalSize(0).height);
    expect(accelToolsLogicalSize(3).height - accelToolsLogicalSize(1).height,
        kToolsRowHeight * 2);
  });

  testWidgets('三条都列出来，点谁就把谁交回宿主', (tester) async {
    final tapped = <AccelTool>[];
    final tools = accelerationTools(memoryRatio: 0.93, maxDiskRatio: 0.96);
    await pumpCard(tester, tools, onTool: tapped.add);

    expect(find.text('加速工具'), findsOneWidget);
    expect(find.text('一键加速'), findsOneWidget);
    expect(find.text('查看进程'), findsOneWidget);
    expect(find.text('深度清理'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '布局溢出说明尺寸算错了');

    await tester.tap(find.text('深度清理'));
    expect(tapped.single.route, '/disk_clean_dashboard/deep_clean_scan');
  });

  testWidgets('无可执行项时显示空态而不是空白卡', (tester) async {
    await pumpCard(tester, const [], onTool: (_) {});
    expect(find.text(accelToolsEmptyMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
