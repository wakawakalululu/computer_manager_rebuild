import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_compatibility.dart';
import 'rust_api.dart';

/// 体检单项结论。
enum ExamineVerdict { ok, needFix, failed, skipped }

class ExamineItem {
  const ExamineItem({
    required this.key,
    required this.title,
    required this.verdict,
    required this.detail,
    this.route,
    this.actionLabel,
  });

  final String key;
  final String title;
  final ExamineVerdict verdict;

  /// 实测出来的一句话结论，界面上原样显示，不再套「检测完成」这类模板话
  final String detail;

  /// 需要处理时直达的二级页；为空表示这项没有可跳转的详情
  final String? route;

  /// 跳转按钮的文案（「去清理」「去管理」）
  final String? actionLabel;

  bool get needsAction => verdict == ExamineVerdict.needFix;
}

/// 常驻守护服务名，与 keep_alive 安装时一致。
const keepAliveService = 'CmKeepAlive';

/// 自启项超过这个数才提「可优化」：参考实现只说「可优化开机启动项」没给阈值，
/// 而几乎每台机器都有若干条自启，取 0 会让这一项永远是红的。
const startupSuggestThreshold = 6;

/// 上次体检时间的偏好键。camelCase，与 `feedbackAgreeUploadLog` 一致。
const lastExaminationKey = 'lastExaminationAt';

/// 结论徽标。措辞取参考实现文案表自带的「可优化」「已优化」
///（`specs/zh_strings.txt:82`、`:572`），不自己另造「待处理/正常」。
/// `skipped` 是「没配判定标准，这一项根本没检查」，不能说成「已优化」。
String examineBadge(ExamineItem item) => switch (item.verdict) {
      ExamineVerdict.ok => '已优化',
      ExamineVerdict.needFix => '可优化',
      ExamineVerdict.failed => '未取到',
      ExamineVerdict.skipped => '未配置',
    };

/// 读上次体检时间（毫秒）。没记录过时返回 null。
Future<int?> readLastExaminationAt() async =>
    (await SharedPreferences.getInstance()).getInt(lastExaminationKey);

/// 记一次体检完成的时间。
Future<void> writeLastExaminationAt(int millis) async =>
    (await SharedPreferences.getInstance()).setInt(lastExaminationKey, millis);

/// 面板状态栏那一行。参考实现首页状态栏就写着「上次体检时间」
///（`specs/zh_strings.txt:282`），从没跑过时不拿假时间糊上去。
String formatLastExamination(int? millis) => millis == null
    ? '首次体检，检查过程不改动任何文件'
    : '上次体检时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(millis))} · 检查不改动文件';

/// 体检数据源。默认全部走 Rust 桥；单测注入假实现，避免为了跑通流程依赖真机。
class ExamineSource {
  ExamineSource({
    required this.netAvailable,
    required this.recycleBin,
    required this.startupList,
    required this.memoryInfo,
    required this.diskList,
    required this.componentProbe,
    required this.adapterList,
    required this.networkOverrides,
    required this.incompatibleApps,
    this.machineIdentity,
    this.logSink,
  });

  final void Function(String msg)? logSink;

  /// 写一行体检日志。默认落到 Rust 日志桥；单测注入收集器，免得为了断言一行日志
  /// 去加载 dll。
  void logLine(String msg) => (logSink ?? RustApi.instance.logInfo)(msg);

  /// 机型身份（Win32_ComputerSystem）。**可空**：不注入就不查，调用方不必为一条
  /// 参考实现只写进日志的结论去改已有构造。
  final Future<ComputerIdentity> Function()? machineIdentity;

  factory ExamineSource.fromBridge() => ExamineSource(
        netAvailable: RustApi.instance.netAvailable,
        recycleBin: RustApi.instance.getRecycleBin,
        startupList: RustApi.instance.readStartupList,
        memoryInfo: RustApi.instance.readMemory2,
        diskList: RustApi.instance.getDiskInfoList,
        componentProbe: RustApi.instance.componentProbe,
        adapterList: RustApi.instance.adapterList,
        networkOverrides: RustApi.instance.networkOverrides,
        machineIdentity: RustApi.instance.computerIdentity,
        incompatibleApps: () async {
          final patterns = await loadIncompatiblePatterns();
          // null 表示「没配判定标准」，与「配了且一个都不命中」是两回事
          if (patterns.isEmpty) return null;
          return findIncompatibleApps(
              await RustApi.instance.checkApp2(), patterns);
        },
      );

  final Future<bool> Function() netAvailable;

  /// `[字节数, 人类可读]`，判空用字节那一位
  final Future<List<String>> Function() recycleBin;
  final Future<List<StartupItem>> Function() startupList;
  final Future<MemoryInfo> Function() memoryInfo;
  final Future<List<DiskInfo>> Function() diskList;

  /// 打印机 / 故障外设 / 启动环境的实测探针
  final Future<ComponentReport> Function() componentProbe;

  /// 网卡摘要，判「网卡数量异常」
  final Future<List<Nic>> Function() adapterList;

  /// hosts 是否被塞过非默认行 + 是否开了手动代理。
  /// 这两项是"明明有网卡却上不去"最难自己查出来的原因（`:119`「若无法上网，
  /// 请检查」指向的正是这类），所以体检要能点名，而不是只说"外网不通"。
  final Future<NetworkOverrides> Function() networkOverrides;

  /// 命中不兼容清单的应用；`null` = 清单没配，这一项不做判定
  final Future<List<AppEntry>?> Function() incompatibleApps;
}

/// 全面体检：逐项实测，逐项出结论。
///
/// 只做「检查」。修复动作一律不在这里执行——参考实现的体检页也是给出「修复方法」
/// 并跳进对应二级页，删除类动作在那里还要过一次二次确认。
class ExaminationRunner {
  ExaminationRunner(this._source);

  final ExamineSource _source;

  /// 面板先按这份名单把行画出来（跑一项亮一项），顺序必须与 [run] 一致。
  /// 五个条目名全部自带：「外设检测」`:478`、「打印机配置」`:310`、「启动环境」`:164`、
  /// 「网卡状态」`:529`、「磁盘检查」`:233`——参考实现的「组件体检」就是按这几项分的
  /// （日志「组件】开始进行组件体检」`:537`、控件 `_ExaminationAnimatedComponentItemCard`
  /// 是"每项一张卡"，不是一个总卡）。
  static const plan = [
    '外设检测',
    '打印机配置',
    '启动环境',
    '网卡状态',
    '内存',
    '开机启动项',
    '回收站',
    '磁盘检查',
    '应用兼容性',
  ];

  /// 顺序跑完全部检查项，每完成一项回调一次，界面据此把「正在检测…」逐行点亮。
  ///
  /// 组件探针一轮只取一次：`component_probe()` 背后是两条 WMI 查询，
  /// 三个组件条目各查一次会把体检拖慢三倍。取不到时三条一起报「未取到」+原因。
  Future<List<ExamineItem>> run(
      {void Function(List<ExamineItem> done)? onProgress}) async {
    final done = <ExamineItem>[];
    ComponentReport? probe;
    Object? probeError;
    try {
      probe = await _source.componentProbe();
    } catch (e) {
      probeError = e;
    }
    await _reportMachineType();
    for (final check in <Future<ExamineItem> Function()>[
      () => _peripherals(probe, probeError),
      () => _printers(probe, probeError),
      () => _bootEnv(probe, probeError),
      _network,
      _memory,
      _startup,
      _recycleBin,
      _disk,
      _app,
    ]) {
      done.add(await check());
      onProgress?.call(done);
    }
    return done;
  }

  /// 记一条「组件】云电脑类型为自研」(`:549`)。参考实现把它写在组件体检的日志里
  ///（`:530` 全面体检 / `:537` 开始进行组件体检 / `:202` 组件有修复项），
  /// **不是体检面板上的第十行**——那五行是自带名字的「外设检测」「打印机配置」
  /// 「启动环境」「网卡状态」「磁盘检查」，多摆一行没有出处的条目反而是编的。
  ///
  /// 三种读法各说各的：读到自研 / 读到不是自研 / 没读到。三者压成前两者就等于
  /// 把"查不到"报成一种云电脑类型，而这是要上报给网关的判断。
  Future<void> _reportMachineType() async {
    final read = _source.machineIdentity;
    if (read == null) return;
    try {
      final id = await read();
      if (!id.identityRead) {
        _source.logLine('组件】云电脑类型未取到（机型厂商与型号均为空）');
      } else if (id.looksLikeCloudMachine) {
        _source.logLine('组件】云电脑类型为自研');
      } else {
        _source.logLine('组件】云电脑类型非自研（${id.manufacturer} ${id.model}）');
      }
    } catch (e) {
      await RustApi.instance.logWarn('查询云电脑类型失败: $e');
    }
  }

  /// 探针取不到时三条组件项共用的结论。
  ExamineItem _probeMissing(String key, String title, Object? err) =>
      ExamineItem(
          key: key,
          title: title,
          verdict: ExamineVerdict.failed,
          detail: '未取得数据：'
              '${err == null ? '组件探针没有返回' : bridgeErrorText(err)}');

  Future<ExamineItem> _guard(
      String key, String title, Future<ExamineItem> Function() body) async {
    try {
      return await body();
    } catch (e) {
      // 单项取不到数不能整轮报废：报出是哪项、为什么。
      return ExamineItem(
          key: key,
          title: title,
          verdict: ExamineVerdict.failed,
          detail: '未取得数据：${bridgeErrorText(e)}');
    }
  }

  /// 「外设检测」：WMI 的 `ConfigManagerErrorCode` 非 0 就是在报故障的设备。
  /// 应用内没有能修外设的地方，所以不给跳转按钮（不摆假 affordance）。
  Future<ExamineItem> _peripherals(ComponentReport? p, Object? err) async {
    if (p == null) return _probeMissing('peripherals', '外设检测', err);
    if (p.problemDeviceCount == 0) {
      return _ok('peripherals', '外设检测', '未发现带故障码的设备');
    }
    return ExamineItem(
        key: 'peripherals',
        title: '外设检测',
        verdict: ExamineVerdict.needFix,
        detail: '${p.problemDeviceCount} 个设备有故障码：'
            '${p.problemDevices.take(2).join('、')}');
  }

  /// 「打印机配置」：台数 + 默认打印机；有离线的算待处理。
  Future<ExamineItem> _printers(ComponentReport? p, Object? err) async {
    if (p == null) return _probeMissing('printers', '打印机配置', err);
    if (p.offlinePrinters.isNotEmpty) {
      return ExamineItem(
          key: 'printers',
          title: '打印机配置',
          verdict: ExamineVerdict.needFix,
          detail: '${p.printerCount} 台打印机，'
              '${p.offlinePrinters.length} 台离线：'
              '${p.offlinePrinters.take(2).join('、')}');
    }
    return _ok(
        'printers',
        '打印机配置',
        p.printerCount == 0
            ? '未检测到打印机'
            : '${p.printerCount} 台打印机，默认 ${p.defaultPrinter ?? '未设置'}');
  }

  /// 「启动环境」：UEFI / Legacy BIOS。这一项是环境事实，没有"可优化"一说。
  Future<ExamineItem> _bootEnv(ComponentReport? p, Object? err) async {
    if (p == null) return _probeMissing('bootenv', '启动环境', err);
    if (p.bootMode == '未知') {
      return ExamineItem(
          key: 'bootenv',
          title: '启动环境',
          verdict: ExamineVerdict.failed,
          detail: '系统未返回固件类型');
    }
    return _ok('bootenv', '启动环境', p.bootMode);
  }

  /// 「网卡状态」。先做结构判据再探外网：参考实现把这一项叫「网卡状态」，
  /// 报的异常是「网卡数量异常」(`:66`)——同一台机器上多张带默认网关的网卡
  /// 同时用时，出站路由就说不准；修复指引是「若无法上网，请检查」(`:119`)
  /// 「并关闭VPN代理软件」(`:167`)。外网探测不通另算一档。
  Future<ExamineItem> _network() => _guard('network', '网卡状态', () async {
        final nics = await _source.adapterList();
        final usable = nics.where((n) => n.hasIp).toList();
        final gated = usable.where((n) => n.hasGateway).toList();
        // hosts 被改写 / 开了手动代理：网卡数正常也上不去，最常见的两种人为原因。
        // 先问这个——它比"网卡数量异常"具体得多，用户看到才知道去改哪。
        // 两项读不到就当没有，探针不该把整轮体检带崩。
        final ov = await _source.networkOverrides();
        final reasons = <String>[
          if (ov.hostsModified) 'hosts 被改写',
          if (ov.manualProxy) '开启了手动代理',
        ];
        if (reasons.isNotEmpty) {
          return _fix(
              key: 'network',
              title: '网卡状态',
              detail: '${reasons.join('、')}，'
                  '若无法上网请检查后重试（设置→网络修复可处理）',
              route: '/app_setting_route',
              actionLabel: '去处理');
        }
        // 探针没跑到 = **不能**当成"hosts 与代理都没问题"。原来这一段直接往下走，
        // 于是读失败时这一项看起来跟"确实干净"一模一样，白白少报一条最具体的线索。
        // 说法要短（面板那行 maxLines: 1），且不点名——点名要知道到底哪一项失败。
        if (!ov.allChecked) {
          return _fix(
              key: 'network',
              title: '网卡状态',
              detail: '未能确认 hosts 与手动代理状态，若无法上网请检查网络连接',
              route: '/app_setting_route',
              actionLabel: '去处理');
        }
        if (gated.length > 1) {
          return _fix(
              key: 'network',
              title: '网卡状态',
              detail: '网卡数量异常：${gated.length} 张网卡在用，'
                  '若无法上网请检查并关闭VPN代理软件',
              route: '/tool_box_dashboard/net_speed_test',
              actionLabel: '看实测');
        }
        if (usable.isEmpty) {
          // 说得出是哪几张网卡，就别只丢一句"未检测到"让人自己找。
          // 被禁用的网卡在 WMI 里仍在、只是没有 IP——那正是"在用网卡为 0"最常见的成因，
          // 而只报"检查网络连接"等于把出路推给了用户自己翻设备管理器。
          //
          // ⚠ 体检面板那一行是 **maxLines: 1**（九行要挤进首页一屏），字多了会被省略号
          // 截掉——而这里被截掉的恰恰是用户要照着去设置页找的那几个名字。
          // 所以只点名第一条，其余用条数带过：给出"还有几条"比截断强，
          // 完整名单在设置页「启用网卡（N）」那一行摆着。
          final disabled = nics
              .where((n) => !n.hasIp && n.netshName.isNotEmpty)
              .map((n) => n.netshName)
              .toList();
          return _fix(
              key: 'network',
              title: '网卡状态',
              detail: disabled.isEmpty
                  ? '未检测到在用网卡，若无法上网请检查网络连接'
                  : disabled.length == 1
                      ? '未检测到在用网卡，已禁用 ${disabled.first}，'
                          '如需使用请在设置中启用'
                      : '未检测到在用网卡，已禁用 ${disabled.first} 等 '
                          '${disabled.length} 张网卡，如需使用请在设置中启用',
              route: '/app_setting_route',
              actionLabel: '去处理');
        }
        return await _source.netAvailable()
            ? _ok('network', '网卡状态', '外网探测可达')
            : _fix(
                key: 'network',
                title: '网卡状态',
                detail: '外网探测无响应',
                route: '/tool_box_dashboard/net_speed_test',
                actionLabel: '看实测');
      });

  Future<ExamineItem> _memory() => _guard('memory', '内存', () async {
        final m = await _source.memoryInfo();
        final pct = (m.ratio * 100).round();
        return m.ratio < 0.8
            ? _ok('memory', '内存', '占用 $pct%')
            : _fix(
                key: 'memory',
                title: '内存',
                detail: '占用 $pct%，后台进程可释放',
                route: '/app_manage_dashboard/process_info',
                actionLabel: '看进程');
      });

  Future<ExamineItem> _startup() => _guard('startup', '开机启动项', () async {
        final items = await _source.startupList();
        final on = items.where((e) => e.enabled).length;
        if (on <= startupSuggestThreshold) {
          return _ok('startup', '开机启动项', on == 0 ? '没有开机自启项' : '$on 项开机自启');
        }
        return _fix(
            key: 'startup',
            title: '开机启动项',
            detail: '$on 项开机自启，可关掉不常用的',
            route: '/app_manage_dashboard/startup_manage',
            actionLabel: '去管理');
      });

  Future<ExamineItem> _recycleBin() => _guard('litter', '回收站', () async {
        final v = await _source.recycleBin();
        final bytes = int.tryParse(v.isEmpty ? '' : v.first) ?? 0;
        if (bytes == 0) return _ok('litter', '回收站', '回收站已清空');
        return _fix(
            key: 'litter',
            title: '回收站',
            detail: '占用 ${v.length > 1 ? v[1] : '$bytes B'}',
            route: '/disk_clean_dashboard',
            actionLabel: '去清理');
      });

  Future<ExamineItem> _disk() => _guard('disk', '磁盘检查', () async {
        final disks = await _source.diskList();
        if (disks.isEmpty) {
          return _ok('disk', '磁盘检查', '未检测到磁盘');
        }
        final tight = disks.where((d) => d.ratio >= 0.9).toList();
        if (tight.isEmpty) {
          final worst = disks.reduce((a, b) => a.ratio >= b.ratio ? a : b);
          return _ok('disk', '磁盘检查',
              '最满的是 ${worst.letter} 盘，已用 ${(worst.ratio * 100).round()}%');
        }
        final first = tight.first;
        return _fix(
            key: 'disk',
            title: '磁盘检查',
            detail:
                '${tight.map((d) => d.letter).join('、')} 盘已用 ${(first.ratio * 100).round()}%',
            route: '/disk_clean_dashboard/deep_clean_scan',
            actionLabel: '去清理');
      });

  /// 参考实现体检页第五张卡 `_ExaminationAnimatedAppItemCard` 对应的「应用」。
  /// 判定复用 #20 那条兼容性检查：清单没配时这一项是「未配置」，
  /// 既不算通过也不算待处理——没有标准就没有结论。
  Future<ExamineItem> _app() => _guard('app', '应用兼容性', () async {
        final hits = await _source.incompatibleApps();
        if (hits == null) {
          return ExamineItem(
              key: 'app',
              title: '应用兼容性',
              verdict: ExamineVerdict.skipped,
              detail: '未配置不兼容应用清单，未做判定');
        }
        if (hits.isEmpty) {
          return _ok('app', '应用兼容性', kCompatCleanMessage);
        }
        return _fix(
            key: 'app',
            title: '应用兼容性',
            detail: '${hits.length} 个应用$kCompatBodyTail',
            route: '/app_manage_dashboard',
            actionLabel: '去处理');
      });

  static ExamineItem _ok(String key, String title, String detail) =>
      ExamineItem(
          key: key, title: title, verdict: ExamineVerdict.ok, detail: detail);

  static ExamineItem _fix(
          {required String key,
          required String title,
          required String detail,
          required String route,
          required String actionLabel}) =>
      ExamineItem(
          key: key,
          title: title,
          verdict: ExamineVerdict.needFix,
          detail: detail,
          route: route,
          actionLabel: actionLabel);
}
