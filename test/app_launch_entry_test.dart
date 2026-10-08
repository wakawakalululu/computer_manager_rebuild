import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「启动」入口只在**真的能启动**时出现。
///
/// 判据钉在 `AppEntry.launchTarget` 那个字段上——它是 Rust 侧 `app_launch_target`
/// 算出来的"确实存在的 `.exe` 全路径"，不是从 `DisplayIcon` 猜的。
/// 实测本机 31 个带图标的已装应用里 24 个能推出 exe、7 个指向 `.ico`
/// （`uninstallerIcon.ico`、`devenv.ico` 这类卸载器/资源图标）——把 `.ico` 交给
/// `ShellExecuteW` 会弹「选择打开方式」，那不是"启动应用"。
/// 所以那 7 条**不该**有这个按钮：给了就是假 affordance。
void main() {
  AppEntry app(String name, {String? launch}) => AppEntry(
        name: name,
        version: '',
        publisher: 'p',
        uninstallKey: 'k\\$name',
        displayIcon: '',
        launchTarget: launch,
      );

  Future<void> pump(WidgetTester tester, List<AppEntry> apps) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AppManageDashboardPage(appsOverride: apps))));
    await tester.pump();
  }

  testWidgets('有启动目标时给出「启动」，且与「卸载」并存', (tester) async {
    await pump(tester, [app('A', launch: r'C:\Program Files\a\a.exe')]);
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('卸载'), findsOneWidget);
  });

  testWidgets('推不出启动目标时**不**给「启动」（.ico 那一类）', (tester) async {
    await pump(tester, [app('B')]);
    expect(find.text('启动'), findsNothing,
        reason: 'launchTarget 为 null 时给按钮＝点了弹「选择打开方式」');
    // 卸载那条路仍然在：不能因为没有启动目标就把整行的动作都吞掉
    expect(find.text('卸载'), findsOneWidget);
  });

  testWidgets('同一列表里两类应用各按各的判据给按钮', (tester) async {
    await pump(tester, [
      app('可启动', launch: r'C:\x\y.exe'),
      app('只有图标'),
    ]);
    // 只有一条「启动」——不是两条（不是每行都无脑给）
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('卸载'), findsNWidgets(2));
  });

  testWidgets('空列表（读失败态）不摆任何动作按钮', (tester) async {
    await pump(tester, []);
    expect(find.text('启动'), findsNothing);
    expect(find.text('卸载'), findsNothing);
  });
}
