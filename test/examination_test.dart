import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 体检的判定钉在纯逻辑层：数据源整体注入，不依赖真机也不依赖 Rust 桥。
void main() {
  ExamineSource source({
    bool net = true,
    List<String> recycleBin = const ['0', '0.00 B'],
    List<StartupItem> startup = const [],
    int memUsed = 300,
    List<DiskInfo>? disks,
    String service = 'RUNNING',
    List<AppEntry>? incompatibleApps = const [],
  }) =>
      ExamineSource(
        netAvailable: () async => net,
        recycleBin: () async => recycleBin,
        startupList: () async => startup,
        memoryInfo: () async => MemoryInfo(used: memUsed, total: 1000),
        diskList: () async =>
            disks ?? [DiskInfo(letter: 'C', total: 100, free: 50)],
        serviceStatus: (_) async => service,
        incompatibleApps: () async => incompatibleApps,
      );

  AppEntry installedApp(String name) => AppEntry(
      name: name,
      version: '',
      publisher: 'p',
      uninstallKey: 'k\\$name',
      displayIcon: '');

  List<StartupItem> startupItems(int n) => [
        for (var i = 0; i < n; i++)
          StartupItem(name: 'item$i', location: 'HKCU', enabled: true)
      ];

  ExamineItem byKey(List<ExamineItem> items, String key) =>
      items.firstWhere((e) => e.key == key);

  test('一切正常时七项全绿，且不给任何跳转', () async {
    final items = await ExaminationRunner(source()).run();
    expect(items.map((e) => e.key),
        ['component', 'network', 'memory', 'startup', 'litter', 'disk', 'app']);
    expect(items.every((e) => e.verdict == ExamineVerdict.ok), isTrue);
    expect(items.where((e) => e.route != null), isEmpty);
    // 应用那一项干净时说的是参考实现那句原话
    expect(byKey(items, 'app').detail, '已安装应用兼容云电脑环境');
  });

  test('兼容性清单没配时是「未配置」，不算通过也不算待处理', () async {
    final items = await ExaminationRunner(source(incompatibleApps: null)).run();
    final app = byKey(items, 'app');
    expect(app.verdict, ExamineVerdict.skipped);
    expect(examineBadge(app), '未配置');
    expect(app.needsAction, isFalse);
    expect(app.route, isNull);
    expect(app.detail, '未配置不兼容应用清单，未做判定');
  });

  test('命中不兼容清单时给出去应用页的跳转', () async {
    final items = await ExaminationRunner(
            source(incompatibleApps: [installedApp('Git'), installedApp('X')]))
        .run();
    final app = byKey(items, 'app');
    expect(app.verdict, ExamineVerdict.needFix);
    expect(app.detail, '2 个应用可能存在兼容性问题');
    expect(app.route, '/app_manage_dashboard');
    expect(app.actionLabel, '去处理');
  });

  test('待处理项的结论是实测值，不是模板话', () async {
    final items = await ExaminationRunner(source(
      net: false,
      recycleBin: ['7381966', '7.04 MB'],
      startup: startupItems(8),
      memUsed: 930,
      disks: [DiskInfo(letter: 'C', total: 100, free: 4)],
      service: 'UNKNOWN',
    )).run();

    expect(byKey(items, 'component').detail, '未检测到守护服务');
    expect(byKey(items, 'network').detail, '外网探测无响应');
    expect(byKey(items, 'memory').detail, '占用 93%，后台进程可释放');
    expect(byKey(items, 'startup').detail, '8 项开机自启，可关掉不常用的');
    expect(byKey(items, 'litter').detail, '占用 7.04 MB');
    expect(byKey(items, 'disk').detail, 'C 盘已用 96%');
    expect(byKey(items, 'litter').route, '/disk_clean_dashboard');
    expect(
        byKey(items, 'startup').route, '/app_manage_dashboard/startup_manage');
  });

  test('回收站按字节判空：展示串是「0.00 B」不代表有东西', () async {
    final empty = await ExaminationRunner(source()).run();
    expect(byKey(empty, 'litter').verdict, ExamineVerdict.ok);

    final full =
        await ExaminationRunner(source(recycleBin: ['512', '512.00 B'])).run();
    expect(byKey(full, 'litter').needsAction, isTrue);
    expect(byKey(full, 'litter').detail, '占用 512.00 B');
  });

  test('启动项阈值两侧：6 项不提，7 项才提', () async {
    final six = await ExaminationRunner(source(startup: startupItems(6))).run();
    expect(byKey(six, 'startup').verdict, ExamineVerdict.ok);
    expect(byKey(six, 'startup').detail, '6 项开机自启');

    final seven =
        await ExaminationRunner(source(startup: startupItems(7))).run();
    expect(byKey(seven, 'startup').needsAction, isTrue);
  });

  test('已停用的自启项不计入待优化', () async {
    final items = await ExaminationRunner(source(
      startup: [
        for (var i = 0; i < 9; i++)
          StartupItem(name: 'off$i', location: 'HKCU', enabled: false)
      ],
    )).run();
    expect(byKey(items, 'startup').verdict, ExamineVerdict.ok);
    expect(byKey(items, 'startup').detail, '没有开机自启项');
  });

  test('单项取数失败不拖垮整轮，且报出原因', () async {
    final runner = ExaminationRunner(ExamineSource(
      netAvailable: () async => true,
      recycleBin: () async => ['0', '0.00 B'],
      startupList: () async => [],
      memoryInfo: () async => MemoryInfo(used: 1, total: 2),
      diskList: () async => throw Exception('磁盘枚举失败'),
      serviceStatus: (_) async => 'RUNNING',
      incompatibleApps: () async => const [],
    ));
    final items = await runner.run();
    expect(items.length, 7);
    final disk = byKey(items, 'disk');
    expect(disk.verdict, ExamineVerdict.failed);
    expect(disk.detail, '未取得数据：磁盘枚举失败');
    expect(byKey(items, 'network').verdict, ExamineVerdict.ok);
  });

  test('进度回调逐行点亮，顺序与列表一致', () async {
    final seen = <int>[];
    await ExaminationRunner(source()).run(onProgress: (done) {
      seen.add(done.length);
      // 每次回调只能比上一次多一项，且都是已完成项
      expect(done.last.verdict, isNot(ExamineVerdict.failed));
    });
    expect(seen, [1, 2, 3, 4, 5, 6, 7]);
  });
}
