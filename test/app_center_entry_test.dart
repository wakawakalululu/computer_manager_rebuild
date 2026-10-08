import 'package:computer_manager/pages/tool_box_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「应用中心」这张卡的四种说法，以及最重要的一条判据：
/// **未安装时什么都不做**——不拉起、也不打开任何网址。
///
/// 背景：Rust 侧原来在客户端不存在时会 `explorer.exe <占位官网>`，
/// 那个网址是净室分支自己填的（值上还挂着 TODO(占位)），界面上又完全看不见。
/// 现在那条分支已经删掉，这条判据由下面第一、第二个用例钉住。
void main() {
  Future<void> tapCard(WidgetTester tester,
      {required Future<bool?> Function() probe,
      Future<bool> Function()? launch}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ToolBoxDashboardPage(probe: probe, launch: launch))));
    await tester.pump();
    await tester.tap(find.text('应用中心'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('未安装：说"未安装认证客户端"，并且不去拉起', (tester) async {
    var launched = 0;
    await tapCard(tester, probe: () async => false, launch: () async {
          launched++;
          return true;
        });
    expect(find.text('未安装认证客户端'), findsOneWidget);
    expect(launched, 0, reason: '未安装还去拉起＝把失败藏起来');
  });

  testWidgets('探测失败：说"无法确认"，不许并进"未安装"', (tester) async {
    await tapCard(tester, probe: () async => null, launch: () async => true);
    expect(find.text('无法确认认证客户端是否安装'), findsOneWidget);
    expect(find.text('未安装认证客户端'), findsNothing);
  });

  testWidgets('已装且起来了才说"已启动"', (tester) async {
    await tapCard(tester, probe: () async => true, launch: () async => true);
    expect(find.text('已启动认证客户端'), findsOneWidget);
  });

  testWidgets('已装但没起来：不冒充成功', (tester) async {
    await tapCard(tester, probe: () async => true, launch: () async => false);
    expect(find.text('认证客户端未能启动'), findsOneWidget);
    expect(find.text('已启动认证客户端'), findsNothing);
  });

  testWidgets('拉起抛异常：报因，不静默', (tester) async {
    await tapCard(tester,
        probe: () async => true,
        launch: () async => throw Exception('路径不存在'));
    expect(find.textContaining('启动认证客户端失败'), findsOneWidget);
  });
}
