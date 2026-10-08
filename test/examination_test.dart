import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 组件探针的「一切正常」样例：一台默认打印机、没有故障外设、UEFI 启动。
const kCleanComponent = ComponentReport(
    printerCount: 1,
    defaultPrinter: 'Fax Printer',
    offlinePrinters: [],
    problemDevices: [],
    problemDeviceCount: 0,
    bootMode: 'UEFI');

/// 体检的判定钉在纯逻辑层：数据源整体注入，不依赖真机也不依赖 Rust 桥。
void main() {
  ExamineSource source({
    bool net = true,
    List<String> recycleBin = const ['0', '0.00 B'],
    List<StartupItem> startup = const [],
    int memUsed = 300,
    List<DiskInfo>? disks,
    ComponentReport component = kCleanComponent,
    NetworkOverrides overrides =
        const NetworkOverrides(hostsModified: false, manualProxy: false),
    List<Nic> nics = const [
      Nic(description: '以太网', hasIp: true, hasGateway: true)
    ],
    List<AppEntry>? incompatibleApps = const [],
    ComputerIdentity? identity,
    List<String>? logs,
  }) =>
      ExamineSource(
        netAvailable: () async => net,
        recycleBin: () async => recycleBin,
        startupList: () async => startup,
        memoryInfo: () async => MemoryInfo(used: memUsed, total: 1000),
        diskList: () async =>
            disks ?? [DiskInfo(letter: 'C', total: 100, free: 50)],
        componentProbe: () async => component,
        adapterList: () async => nics,
        networkOverrides: () async => overrides,
        incompatibleApps: () async => incompatibleApps,
        machineIdentity: identity == null ? null : () async => identity,
        logSink: logs?.add,
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

  test('一切正常时九项全绿，且不给任何跳转', () async {
    final items = await ExaminationRunner(source()).run();
    expect(items.map((e) => e.key), [
      'peripherals', 'printers', 'bootenv', 'network', 'memory', //
      'startup', 'litter', 'disk', 'app'
    ]);
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
      component: const ComponentReport(
          printerCount: 2,
          defaultPrinter: null,
          offlinePrinters: ['Microsoft Print to PDF'],
          problemDevices: ['USB Printing Support'],
          problemDeviceCount: 1,
          bootMode: 'UEFI'),
    )).run();

    expect(
        byKey(items, 'peripherals').detail, '1 个设备有故障码：USB Printing Support');
    expect(
        byKey(items, 'printers').detail, '2 台打印机，1 台离线：Microsoft Print to PDF');
    expect(byKey(items, 'bootenv').detail, 'UEFI');
    // 应用内没有能修外设/打印机的地方，就不摆一个跳不过去的按钮
    expect(byKey(items, 'peripherals').route, isNull);
    expect(byKey(items, 'peripherals').verdict, ExamineVerdict.needFix);
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

  test('hosts 被改写/开了手动代理要点名，而不是只说外网不通', () async {
    // 本机 hosts 里就有一行 `20.27.177.113 github.com`——这种"明明有网卡却
    // 上不去"最难自己查，只报"外网探测无响应"等于让用户干瞪眼。
    final hosts = await ExaminationRunner(source(
      overrides:
          const NetworkOverrides(hostsModified: true, manualProxy: false),
    )).run();
    final net = byKey(hosts, 'network');
    expect(net.verdict, ExamineVerdict.needFix);
    expect(net.detail, contains('hosts 被改写'));
    expect(net.route, '/app_setting_route');

    final proxy = await ExaminationRunner(source(
      overrides:
          const NetworkOverrides(hostsModified: false, manualProxy: true),
    )).run();
    expect(byKey(proxy, 'network').detail, contains('手动代理'));
  });

  test('多张带默认网关的网卡同时用时报「网卡数量异常」', () async {
    final items = await ExaminationRunner(source(nics: const [
      Nic(description: '以太网', hasIp: true, hasGateway: true),
      Nic(description: 'VPN 虚拟网卡', hasIp: true, hasGateway: true),
    ])).run();
    final net = byKey(items, 'network');
    expect(net.verdict, ExamineVerdict.needFix);
    expect(net.detail, '网卡数量异常：2 张网卡在用，若无法上网请检查并关闭VPN代理软件');
    expect(net.route, '/tool_box_dashboard/net_speed_test');
  });

  test('一张带网关的网卡不算异常；一张在用的都没有才提示检查连接', () async {
    final one = await ExaminationRunner(source(nics: const [
      Nic(description: '以太网', hasIp: true, hasGateway: true),
    ])).run();
    expect(byKey(one, 'network').verdict, ExamineVerdict.ok);

    // 有网卡但没配 IP 也算「没有在用」——WMI 里未连接的网卡也会占一行
    final none = await ExaminationRunner(source(
      nics: const [Nic(description: '以太网', hasIp: false, hasGateway: false)],
    )).run();
    expect(byKey(none, 'network').verdict, ExamineVerdict.needFix);
    expect(byKey(none, 'network').detail, '未检测到在用网卡，若无法上网请检查网络连接');
  });

  test('认得出被禁用的网卡时点名，并把「去处理」指到设置页', () async {
    // 被禁用的网卡在 WMI 里仍在、只是没有 IP——只报"检查网络连接"等于把出路
    // 推给用户自己翻设备管理器。
    final r = await ExaminationRunner(source(nics: const [
      Nic(
          description: '以太网',
          hasIp: false,
          hasGateway: false,
          netshName: '以太网'),
      Nic(
          description: 'USB 网卡',
          hasIp: false,
          hasGateway: false,
          netshName: 'USB 网卡'),
    ])).run();
    final net = byKey(r, 'network');
    expect(net.verdict, ExamineVerdict.needFix);
    expect(net.detail, contains('已禁用 以太网'));
    expect(net.detail, contains('2 张网卡'));
    expect(net.route, '/app_setting_route');
  });

  test('多张被禁用时只点名第一条并给条数，别把名单截断', () async {
    // 面板那一行是 maxLines: 1，名单一长就被省略号切掉——切掉的正是
    // 用户要照着去设置页找的名字。完整名单在设置页那一行摆着。
    final r = await ExaminationRunner(source(nics: const [
      Nic(description: 'a', hasIp: false, hasGateway: false, netshName: '以太网'),
      Nic(
          description: 'b',
          hasIp: false,
          hasGateway: false,
          netshName: 'USB 网卡'),
      Nic(description: 'c', hasIp: false, hasGateway: false, netshName: 'WLAN'),
    ])).run();
    final net = byKey(r, 'network');
    expect(net.detail, contains('以太网'));
    expect(net.detail, contains('3 张网卡'));
    expect(net.detail, isNot(contains('WLAN')),
        reason: '第三个名字放不进一行，与其被省略号截断不如不写');
  });

  test('netsh 名字读不到的网卡不算"已禁用"，不列出来也不假装能启用', () async {
    final r = await ExaminationRunner(source(nics: const [
      Nic(description: '以太网', hasIp: false, hasGateway: false),
    ])).run();
    final net = byKey(r, 'network');
    // 列出来也点不动，等于又给了一个假 affordance
    expect(net.detail, isNot(contains('已禁用')));
    expect(net.detail, '未检测到在用网卡，若无法上网请检查网络连接');
  });

  test('hosts/代理探针读不到时不说"没问题"，说"未能确认"', () async {
    // 原来 `networkOverrides()` 把抛异常的那项也塞成 false，于是"读不到"与
    // "确实干净"在界面上完全一样 —— 探针失败时白白少报一条最具体的线索。
    final r = await ExaminationRunner(ExamineSource(
      netAvailable: () async => true,
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
      adapterList: () async => const [
        Nic(description: '以太网', hasIp: true, hasGateway: true),
      ],
      networkOverrides: () async => const NetworkOverrides.unknown(),
      incompatibleApps: () async => const [],
    )).run();
    final net = byKey(r, 'network');
    expect(net.verdict, ExamineVerdict.needFix);
    expect(net.detail, contains('未能确认'));
    expect(net.detail, isNot(contains('没问题')));
  });

  test('探针真读到且都干净 → allChecked 为 true，可以正常往下走', () {
    const ov = NetworkOverrides(hostsModified: false, manualProxy: false);
    expect(ov.allChecked, isTrue, reason: '用这个构造器就代表确实读到过；读不到要用 unknown()');
    expect(const NetworkOverrides.unknown().allChecked, isFalse);
  });

  test('单项取数失败不拖垮整轮，且报出原因', () async {
    final runner = ExaminationRunner(ExamineSource(
      netAvailable: () async => true,
      recycleBin: () async => ['0', '0.00 B'],
      startupList: () async => [],
      memoryInfo: () async => MemoryInfo(used: 1, total: 2),
      diskList: () async => throw Exception('磁盘枚举失败'),
      componentProbe: () async => kCleanComponent,
      adapterList: () async =>
          const [Nic(description: '以太网', hasIp: true, hasGateway: true)],
      networkOverrides: () async =>
          const NetworkOverrides(hostsModified: false, manualProxy: false),
      incompatibleApps: () async => const [],
    ));
    final items = await runner.run();
    expect(items.length, 9);
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
    expect(seen, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  // 「云电脑类型为自研」(:549) 是组件体检的**日志**（与 :530/:537/:202 同一族），
  // 不是面板上的第十行：面板那五行是自带名字的检查项，多摆一行没有出处的条目
  // 是编的。所以判据是「仍然九项 + 出了这条日志」。
  group('云电脑类型只落日志，不占检查项', () {
    const selfDeveloped = ComputerIdentity(
        systemType: 'System', manufacturer: 'RDO', model: 'KVM');
    const publicCloud = ComputerIdentity(
        systemType: 'PC', manufacturer: 'QEMU', model: 'Standard PC');
    const unreadable =
        ComputerIdentity(systemType: '', manufacturer: '', model: '');

    test('认得出的自研机型记「组件】云电脑类型为自研」，且检查项仍是九项', () async {
      final logs = <String>[];
      final items =
          await ExaminationRunner(source(identity: selfDeveloped, logs: logs))
              .run();
      expect(items.length, 9);
      expect(items.map((e) => e.title), isNot(contains('云电脑类型')));
      expect(logs, contains('组件】云电脑类型为自研'));
    });

    test('公共云机型记「非自研」并带上认得出的机型，不冒充自研', () async {
      final logs = <String>[];
      await ExaminationRunner(source(identity: publicCloud, logs: logs)).run();
      expect(logs.where((l) => l.contains('为自研')), isEmpty);
      expect(logs.single, contains('QEMU'));
    });

    // 关键回归：厂商与型号都空时，若压进前两支，界面/日志就在说"这不是自研云电脑"，
    // 而真实情况是"查不到"——那是要上报给网关的判断，不能替它下结论。
    test('机型读不到时既不说自研也不说非自研，单说未取到', () async {
      final logs = <String>[];
      await ExaminationRunner(source(identity: unreadable, logs: logs)).run();
      expect(logs.single, contains('未取到'));
      expect(logs.single, isNot(contains('为自研')));
      expect(logs.single, isNot(contains('非自研')));
    });

    test('没注入机型数据源时一条日志都不出（默认构造不欠新查询）', () async {
      final logs = <String>[];
      final items = await ExaminationRunner(source(logs: logs)).run();
      expect(logs, isEmpty);
      expect(items.length, 9);
    });
  });

  test('identityRead：只空一边也算残缺，双空才算没读到', () {
    expect(
        const ComputerIdentity(systemType: 'PC', manufacturer: '', model: '')
            .identityRead,
        isFalse);
    expect(
        const ComputerIdentity(systemType: '', manufacturer: 'QEMU', model: '')
            .identityRead,
        isTrue);
    expect(
        const ComputerIdentity(systemType: 'PC', manufacturer: '  ', model: ' ')
            .identityRead,
        isFalse);
  });
}
