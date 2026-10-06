import 'dart:async';

import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/widgets/examination_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页上的体检面板：正在检查 → 逐项结论 → 就地给修复入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ExamineSource fakeSource({
    bool net = true,
    List<StartupItem>? startup,
    String service = 'UNKNOWN',
  }) =>
      ExamineSource(
        netAvailable: () async => net,
        recycleBin: () async => ['7381966', '7.04 MB'],
        startupList: () async =>
            startup ??
            [StartupItem(name: 'a', location: 'HKCU', enabled: true)],
        memoryInfo: () async => MemoryInfo(used: 930, total: 1000),
        diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 4)],
        serviceStatus: (_) async => service,
        incompatibleApps: () async => const [],
      );

  /// 面板挂在首页路由上，「去处理」是 context.go，所以测试环境必须有 GoRouter。
  Future<void> openPanel(WidgetTester tester, ExaminationRunner runner,
      {VoidCallback? onCollapse}) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      routerConfig: GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ExaminationPanel(
                  runner: runner, onCollapse: onCollapse ?? () {}),
            ),
          ),
        ),
        GoRoute(
          path: '/app_setting_route',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('已跳到常驻组件页'))),
        ),
      ]),
    ));
  }

  test('上次体检时间：没记录时是 null，写过就原样读回', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await readLastExaminationAt(), isNull);
    await writeLastExaminationAt(1767000000000);
    expect(await readLastExaminationAt(), 1767000000000);
  });

  testWidgets('六项全部列出来，标题与实测结论都在', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();

    for (final title in ['常驻组件', '网络', '内存', '开机启动项', '回收站', '磁盘空间', '应用兼容性']) {
      expect(find.text(title), findsOneWidget, reason: '$title 没有渲染出来');
    }
    expect(find.text('占用 93%，后台进程可释放'), findsOneWidget);
    expect(find.text('C 盘已用 96%'), findsOneWidget);
    expect(find.text('占用 7.04 MB'), findsOneWidget);
    expect(find.text('正在检查…'), findsNothing);
  });

  testWidgets('跑完前是「正在检查…」，不抢跑结论', (tester) async {
    // 卡住网络这一项，让整轮停在半途：真数据源跑得太快，不挡一下就测不出「还没跑完」这一态。
    final gate = Completer<bool>();
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () => gate.future,
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => <StartupItem>[],
          memoryInfo: () async => MemoryInfo(used: 1, total: 2),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          serviceStatus: (_) async => 'RUNNING',
          incompatibleApps: () async => const [],
        )));
    await tester.pump();
    expect(find.text('正在检查…'), findsWidgets);
    expect(find.text('共 7 项'), findsNothing);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('共 7 项，均已优化'), findsOneWidget);
    expect(find.text('可优化'), findsNothing);
  });

  testWidgets('兼容性清单没配时如实报「未配置」，不冒充「均已优化」', (tester) async {
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () async => true,
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => <StartupItem>[],
          memoryInfo: () async => MemoryInfo(used: 1, total: 2),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          serviceStatus: (_) async => 'RUNNING',
          incompatibleApps: () async => null,
        )));
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('未配置不兼容应用清单，未做判定'), findsOneWidget);
    expect(find.text('共 7 项，1 项未配置'), findsOneWidget);
    expect(find.text('均已优化'), findsNothing);
  });

  testWidgets('行内动作与「去处理」都跳进对应二级页', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();
    expect(find.text('已跳到常驻组件页'), findsOneWidget);
  });

  testWidgets('徽标用参考实现自带的「可优化」「已优化」，跑完记下体检时间', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();
    expect(find.text('可优化'), findsNWidgets(4));
    expect(find.text('已优化'), findsNWidgets(3)); // 网络、启动项、应用兼容性
    // 跑完才写时间：中途取数失败的一轮也算跑过，但不能报成「上次体检时间」。
    final recorded =
        (await SharedPreferences.getInstance()).getInt(lastExaminationKey);
    expect(recorded, isNotNull);
    expect(DateTime.now().millisecondsSinceEpoch - recorded!,
        lessThan(const Duration(minutes: 1).inMilliseconds));
    expect(find.textContaining('上次体检时间：'), findsOneWidget);
  });

  testWidgets('跑完给一个「收起」的出口', (tester) async {
    var collapsed = 0;
    await openPanel(tester, ExaminationRunner(fakeSource()),
        onCollapse: () => collapsed++);
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    expect(collapsed, 1);
  });
}
