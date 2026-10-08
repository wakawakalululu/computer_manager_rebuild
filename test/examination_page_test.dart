import 'dart:async';

import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/widgets/examination_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 组件探针的「一切正常」样例（与 examination_test.dart 里同名常量同形）。
const kCleanComponent = ComponentReport(
    printerCount: 1,
    defaultPrinter: 'Fax Printer',
    offlinePrinters: [],
    problemDevices: [],
    problemDeviceCount: 0,
    bootMode: 'UEFI');

/// 单张带网关的网卡：也就是「一切正常」的网卡样例。
const kOneGatedNic = [
  Nic(description: '以太网', hasIp: true, hasGateway: true),
];

/// 首页上的体检面板：正在检测 → 逐项结论 → 就地给修复入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ExamineSource fakeSource({
    bool net = true,
    List<StartupItem>? startup,
  }) =>
      ExamineSource(
        netAvailable: () async => net,
        recycleBin: () async => ['7381966', '7.04 MB'],
        startupList: () async =>
            startup ??
            [StartupItem(name: 'a', location: 'HKCU', enabled: true)],
        memoryInfo: () async => MemoryInfo(used: 930, total: 1000),
        diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 4)],
        componentProbe: () async => kCleanComponent,
        adapterList: () async => kOneGatedNic,
        networkOverrides: () async =>
            const NetworkOverrides(hostsModified: false, manualProxy: false),
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
          path: '/disk_clean_dashboard',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('已跳到清理页'))),
        ),
        GoRoute(
          path: '/tool_box_dashboard/net_speed_test',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('已跳到网速实测页'))),
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

  testWidgets('九项全部列出来，标题与实测结论都在', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();

    for (final title in [
      '外设检测', '打印机配置', '启动环境', '网卡状态', '内存', //
      '开机启动项', '回收站', '磁盘检查', '应用兼容性'
    ]) {
      expect(find.text(title), findsOneWidget, reason: '$title 没有渲染出来');
    }
    expect(find.text('占用 93%，后台进程可释放'), findsOneWidget);
    expect(find.text('C 盘已用 96%'), findsOneWidget);
    expect(find.text('占用 7.04 MB'), findsOneWidget);
    expect(find.text('正在检测…'), findsNothing);
  });

  testWidgets('跑完前是「正在检测…」，不抢跑结论', (tester) async {
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
          componentProbe: () async => kCleanComponent,
          adapterList: () async => kOneGatedNic,
          networkOverrides: () async =>
              const NetworkOverrides(hostsModified: false, manualProxy: false),
          incompatibleApps: () async => const [],
        )));
    await tester.pump();
    expect(find.text('正在检测…'), findsWidgets);
    expect(find.text('共 9 项'), findsNothing);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('共 9 项，检测已最优'), findsOneWidget);
    expect(find.text('可优化'), findsNothing);
  });

  testWidgets('兼容性清单没配时如实报「未配置」，不冒充「检测已最优」', (tester) async {
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () async => true,
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => <StartupItem>[],
          memoryInfo: () async => MemoryInfo(used: 1, total: 2),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          componentProbe: () async => kCleanComponent,
          adapterList: () async => kOneGatedNic,
          networkOverrides: () async =>
              const NetworkOverrides(hostsModified: false, manualProxy: false),
          incompatibleApps: () async => null,
        )));
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('未配置不兼容应用清单，未做判定'), findsOneWidget);
    expect(find.text('共 9 项，1 项未配置'), findsOneWidget);
    expect(find.text('检测已最优'), findsNothing);
  });

  testWidgets('行内动作与「去处理」都跳进对应二级页', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();
    // 回收站与磁盘两项都给「去清理」，这里取第一个（回收站那条）
    await tester.tap(find.text('去清理').first);
    await tester.pumpAndSettle();
    expect(find.text('已跳到清理页'), findsOneWidget);
  });

  testWidgets('网卡数量异常的行内动作跳到网速实测页', (tester) async {
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () async => true,
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => const [],
          memoryInfo: () async => MemoryInfo(used: 1, total: 2),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          componentProbe: () async => kCleanComponent,
          adapterList: () async => const [
            Nic(description: '以太网', hasIp: true, hasGateway: true),
            Nic(description: 'VPN 虚拟网卡', hasIp: true, hasGateway: true),
          ],
          networkOverrides: () async =>
              const NetworkOverrides(hostsModified: false, manualProxy: false),
          incompatibleApps: () async => const [],
        )));
    await tester.pumpAndSettle();
    expect(find.text('网卡数量异常：2 张网卡在用，若无法上网请检查并关闭VPN代理软件'), findsOneWidget);
    await tester.tap(find.text('看实测'));
    await tester.pumpAndSettle();
    expect(find.text('已跳到网速实测页'), findsOneWidget);
  });

  testWidgets('待处理项都没有二级页可去时，不给「去处理」（外设检测就是这种）', (tester) async {
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () async => true,
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => const [],
          memoryInfo: () async => MemoryInfo(used: 930, total: 1000),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          componentProbe: () async => const ComponentReport(
              printerCount: 1,
              defaultPrinter: 'Fax Printer',
              offlinePrinters: [],
              problemDevices: ['QEMU DVD-ROM ATA Device'],
              problemDeviceCount: 1,
              bootMode: 'Legacy BIOS'),
          adapterList: () async => kOneGatedNic,
          networkOverrides: () async =>
              const NetworkOverrides(hostsModified: false, manualProxy: false),
          incompatibleApps: () async => const [],
        )));
    await tester.pumpAndSettle();
    // 内存与外设检测都可优化，但只有内存有二级页可去：CTA 必须跳到能跳的那个
    expect(find.text('共 9 项，2 项可优化'), findsOneWidget);
    expect(find.text('去处理：外设检测'), findsNothing);
    expect(find.text('去处理：内存'), findsOneWidget);
    expect(find.textContaining('1 个设备有故障码：QEMU DVD-ROM ATA Device'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('徽标用参考实现自带的「可优化」「已优化」，跑完记下体检时间', (tester) async {
    await openPanel(tester, ExaminationRunner(fakeSource()));
    await tester.pumpAndSettle();
    expect(find.text('可优化'), findsNWidgets(3)); // 内存、回收站、磁盘检查
    expect(find.text('已优化'), findsNWidgets(6)); // 外设/打印机/启动环境/网卡/启动项/应用兼容性
    // 跑完才写时间：中途取数失败的一轮也算跑过，但不能报成「上次体检时间」。
    final recorded =
        (await SharedPreferences.getInstance()).getInt(lastExaminationKey);
    expect(recorded, isNotNull);
    expect(DateTime.now().millisecondsSinceEpoch - recorded!,
        lessThan(const Duration(minutes: 1).inMilliseconds));
    expect(find.textContaining('上次体检时间：'), findsOneWidget);
  });

  testWidgets('某项探针抛异常时不能说「检测已最优」', (tester) async {
    // _guard 把探针异常转成 ExamineVerdict.failed（"未取到"）——它既不是 ok
    // 也不是"可优化"。原来汇总只分 pending / skipped 两种，于是
    // "3 项没取到"会一路落到「检测已最优」那句，把没测到的项冒充测过的结论。
    await openPanel(
        tester,
        ExaminationRunner(ExamineSource(
          netAvailable: () async => throw StateError('探不到'),
          recycleBin: () async => ['0', '0.00 B'],
          startupList: () async => const [],
          memoryInfo: () async => MemoryInfo(used: 100, total: 1000),
          diskList: () async => [DiskInfo(letter: 'C', total: 100, free: 50)],
          componentProbe: () async => const ComponentReport(
              printerCount: 1,
              defaultPrinter: 'Fax',
              offlinePrinters: [],
              problemDevices: [],
              problemDeviceCount: 0,
              bootMode: 'UEFI'),
          adapterList: () async =>
              const [Nic(description: '以太网', hasIp: true, hasGateway: true)],
          networkOverrides: () async =>
              const NetworkOverrides(hostsModified: false, manualProxy: false),
          incompatibleApps: () async => const [],
        )));
    await tester.pumpAndSettle();

    expect(find.textContaining('检测已最优'), findsNothing,
        reason: '有项目没测到时，"检测已最优"是凭空结论');
    // 行徽章与汇总行都会出现「未取到」，所以按**汇总那句**来断言
    expect(find.text('共 9 项，0 项可优化，1 项未取到'), findsOneWidget);
  });

  testWidgets('跑完给一个「收起」的出口', (tester) async {
    var collapsed = 0;
    await openPanel(tester, ExaminationRunner(fakeSource()),
        onCollapse: () => collapsed++);
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    expect(collapsed, 1);
  });

  group('「去处理」那一行要说明还剩几项', () {
    ExamineItem fix(String title, {String? route}) => ExamineItem(
          key: title,
          title: title,
          verdict: ExamineVerdict.needFix,
          detail: '需要处理',
          route: route ?? '/app_setting_route',
          actionLabel: '去处理',
        );

    test('一项时还是点名那一项', () {
      expect(repairEntryLabel([fix('内存')]), '去处理：内存');
    });

    test('多项时摆出条数，不再只显示第一项', () {
      // 原来固定写「去处理：<第一项>」，用户修完回来才发现还有下一项，
      // 像在猜还剩多少——那不是"还有几项"的证据
      final label = repairEntryLabel([fix('内存'), fix('网卡状态'), fix('回收站')]);
      expect(label, '一键修复（3 项待处理）');
      expect(label, contains('3'));
    });

    test('没有可跳的项时不给这一行（null）', () {
      expect(repairEntryLabel([]), isNull);
    });
  });
}
