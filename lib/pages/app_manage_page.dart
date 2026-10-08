import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/theme.dart';
import '../services/acceleration_tools.dart';
import '../services/app_compatibility.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 应用管理面板 —— 路由 /app_manage_dashboard
/// 子页：process_info（进程管理）/ startup_manage（启动项管理）
class AppManageDashboardPage extends StatefulWidget {
  const AppManageDashboardPage({super.key, this.appsOverride});

  /// 测试注入：给了就直接当已读到的列表用，不再走真桥。
  ///
  /// `initState` 一挂上就会 `_load()`，那时桩还没机会装——所以注入必须走
  /// **构造参数**（与 `RecycleBinCard` 同一个道理），不能给 State 加可写字段。
  /// 给了它同时也就不再执行兼容性弹窗那条链（那也要真桥读 config.ini）。
  final List<AppEntry>? appsOverride;

  @override
  State<AppManageDashboardPage> createState() => _AppManageDashboardPageState();
}

class _AppManageDashboardPageState extends State<AppManageDashboardPage> {
  /// null = 还没读到 / 读失败。**不能初始化成空列表**——那会让"读失败"显示成
  /// 「已安装应用」下一片空白，读起来就是"查过了、一个都没有"。
  List<AppEntry>? _apps;

  /// 兼容性清单（来自随包 config.ini 的 `[compat] incompatible`）。为空表示
  /// 「没配判定标准」，此时不显示任何兼容性结论。
  List<String> _patterns = [];
  List<AppEntry> _compatHits = [];
  bool _compatChecked = false;

  @override
  void initState() {
    super.initState();
    final injected = widget.appsOverride;
    if (injected != null) {
      _apps = injected;
      return;
    }
    unawaited(_load());
  }

  /// 读已安装应用。`.then(...)` 原来**没有 onError**：注册表读失败就抛到无人接的地方，
  /// `_apps` 停在空列表，界面摆一片空白——读起来是"查过了、一个都没装"。
  /// 现在失败如实说，并回到 null（读不到），不假装是空列表。
  Future<void> _load() async {
    List<AppEntry>? apps;
    try {
      apps = await RustApi.instance.checkApp2();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('读取已安装应用失败：${bridgeErrorText(e)}')));
      }
    }
    if (!mounted) return;
    setState(() => _apps = apps);
    if (apps != null) unawaited(_checkCompat(apps));
  }

  /// 参考实现的 AppCompatibility_window：命中不兼容清单时弹窗，主动作是卸载。
  Future<void> _checkCompat(List<AppEntry> apps) async {
    final patterns = await loadIncompatiblePatterns();
    final hits = findIncompatibleApps(apps, patterns);
    if (!mounted) return;
    setState(() {
      _patterns = patterns;
      _compatHits = hits;
      _compatChecked = true;
    });
    if (hits.isEmpty) return;
    final first = hits.first;
    await ThresholdPopups.maybeShow(
      key: 'AppCompatibility_window',
      title: kCompatTitle,
      body: compatBody(hits),
      actionLabel: '卸载',
      actionId: 'uninstall',
      action: () async {
        // 卸载不可逆，和列表里那个「卸载」同一档：先过二次确认。
        final messenger = ScaffoldMessenger.of(context);
        final ok = await confirmDestructive(context,
            title: '卸载应用', body: '确定卸载 ${first.name}？将启动该应用自带的卸载程序。');
        if (!ok) return;
        try {
          await RustApi.instance.uninstallApp(first.uninstallKey);
          // 与列表里那个「卸载」同一句：只说启动了卸载程序，
          // **不说"卸载成功"**——我们不知道它卸没卸完（没有监控循环）。
          messenger.showSnackBar(SnackBar(
              duration: const Duration(seconds: 5),
              content: Text('已启动 ${first.name} 的卸载程序')));
        } catch (e) {
          messenger.showSnackBar(
              SnackBar(content: Text('卸载失败：${bridgeErrorText(e)}')));
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_process.webp',
                // 标题与描述都取参考实现自带的成对标签（zh_strings.txt:122、:59）；
                // 原来这两行是我自己写的说法。
                title: '应用进程管理',
                subtitle: '关闭不用的应用进程，提升设备速度',
                onTap: () => context.go('/app_manage_dashboard/process_info'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'img_dashboard_startup.webp',
                title: '开机启动项管理',
                subtitle: '减少开机启动项可以提升开机速度',
                onTap: () =>
                    context.go('/app_manage_dashboard/startup_manage'))),
      ]),
      const SizedBox(height: 14),
      Material(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('已安装应用', style: TextStyle(fontWeight: FontWeight.w700)),
            // 兼容性结论只在真的配了判定标准时出现；没配就是没检查，不说「兼容」。
            if (_compatChecked && _patterns.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                  _compatHits.isEmpty
                      ? kCompatCleanMessage
                      : '发现 ${_compatHits.length} 个可能存在兼容性问题的应用',
                  style:
                      const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ],
            const SizedBox(height: 6),
            // 读失败（null）与"确实一个都没装"（空）要分开：空列表照画，
            // null 时只留标题不列条目——一片空白会被读成"没有应用"。
            for (final app in _apps ?? const <AppEntry>[]) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: AppIconImage(displayIcon: app.displayIcon),
                title: Text(dedupTitle(app.name, app.version),
                    style: const TextStyle(fontSize: 14)),
                subtitle:
                    Text(app.publisher, style: const TextStyle(fontSize: 11)),
                trailing: TextButton(
                  onPressed: () async {
                    // crateApiSysinfoAppCheckRUninstallApp → …::app_check::uninstall_app
                    // Rust 侧是 `cmd /C <UninstallString>`：一次点击就直接把该应用
                    // 自带的卸载程序跑起来，所以和清理/结束进程同一档，要过确认。
                    final messenger = ScaffoldMessenger.of(context);
                    final name = dedupTitle(app.name, app.version, sep: ' ');
                    final ok = await confirmDestructive(context,
                        title: '卸载应用', body: '确定卸载 $name？将启动该应用自带的卸载程序。');
                    if (!ok || !mounted) return;
                    try {
                      await RustApi.instance.uninstallApp(app.uninstallKey);
                      // 只说"已启动卸载程序"——我们**不知道**它有没有卸成功：
                      // 那要等卸载器自己跑完（`uninstall_app_moint` 那种监控循环
                      // 本项目没有）。不写"卸载成功"，也不写进度百分比冒充监控。
                      messenger.showSnackBar(SnackBar(
                          duration: const Duration(seconds: 5),
                          content: Text('已启动 $name 的卸载程序')));
                    } catch (e) {
                      // 成功那行写了应用名，失败也得写——列表里几十个应用，
                      // 只说"卸载失败"用户不知道是哪一条
                      messenger.showSnackBar(SnackBar(
                          duration: const Duration(seconds: 5),
                          content: Text(perItemFailure('卸载', name, e))));
                    }
                  },
                  child: const Text('卸载'),
                ),
              ),
              // crateApiSysinfoWindowsInfoROpenApp → …::windows_info::open_app
              // 只在 launchTarget 非空时才有这个按钮：那个字段是"确实存在的
              // .exe 全路径"，不是从 DisplayIcon 猜的。推不出就不给入口——比给一个
              // 点了弹「选择打开方式」的按钮强（DisplayIcon 指向 .ico 的本机有 7 个）。
              if (app.launchTarget != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final name = dedupTitle(app.name, app.version, sep: ' ');
                      try {
                        await RustApi.instance.openApp(app.launchTarget!);
                        // 启动与应用管理一样是跨进程动作：**不知道**它有没有真起来
                        // （有的应用起来后自己又退），所以只说"已启动"，不写"启动成功"。
                        messenger.showSnackBar(SnackBar(
                            duration: const Duration(seconds: 3),
                            content: Text('已启动 $name')));
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(
                            duration: const Duration(seconds: 5),
                            content: Text(perItemFailure('启动', name, e))));
                      }
                    },
                    child: const Text('启动'),
                  ),
                ),
            ],
          ]),
        ),
      ),
    ]);
  }
}

class ProcessInfoPage extends StatefulWidget {
  const ProcessInfoPage({super.key});

  @override
  State<ProcessInfoPage> createState() => _ProcessInfoPageState();
}

/// 进程行的副标题。抽成纯函数是为了能钉住"读不到就不写占位话"——
/// 内联在 build 里的话，这条约束没人能测。
///
/// 发布者（PE CompanyName）只在真读出来时带上：进程名（svchost / RuntimeBroker
/// 一堆同名的）本身认不出是什么，CompanyName 才认得出是谁家的。
/// 文件说明（FileDescription）跟着发布者走：它回答"它自称是什么"，两者合起来
/// 才认得出一个进程。⚠ 与发布者相同则**不重复写**——很多程序两个字段是一句话，
/// 写两遍等于把同一句话说两遍。**都读不到时不留占位话**。
String processSubtitle(ProcInfo p) => [
      if (p.publisher.isNotEmpty && p.publisher != p.description) p.publisher,
      if (p.description.isNotEmpty) p.description,
      'CPU ${p.cpu.toStringAsFixed(1)}%',
      '内存 ${p.mem} MB',
    ].join('   ');

/// 把进程分成「可优化」与「进行中」两段。
///
/// 参考实现是**两段**而不是一坨平铺：`进程可优化`(:481) 与 `进行中进程`(:197)
/// 是一对分组标题。一屏几十个进程平铺着，用户不知道该先关哪个——把"占了大头、
/// 关了有收益"的那些挑到前面，才是能下手的那部分。
///
/// 判据：内存占比 ≥ [ratio]（复用加速球判定"内存吃紧"的同一个数
/// `accelMemoryToolRatio`，两处各写一个阈值就会漂）或 CPU 单进程 ≥ 同比例。
/// **必须有 [totalMemMb]**：拿 MB 直接跟百分比比是量纲错误（进程页拿不到
/// 内存总量时就不分两段，只平铺——宁可不给分组，不给错分组）。
(List<ProcInfo> optimizable, List<ProcInfo> running) splitByImpact(
  List<ProcInfo> procs, {
  required int totalMemMb,
  double ratio = accelMemoryToolRatio,
}) {
  if (totalMemMb <= 0) {
    final all = List<ProcInfo>.of(procs);
    return (const <ProcInfo>[], all);
  }
  bool hot(ProcInfo p) => p.mem / totalMemMb >= ratio || p.cpu >= ratio * 100;
  final optimizable = procs.where(hot).toList()
    ..sort((a, b) => b.cpu.compareTo(a.cpu));
  final running = procs.where((p) => !hot(p)).toList()
    ..sort((a, b) => b.mem.compareTo(a.mem));
  return (optimizable, running);
}

/// 进程页计数行：`null` 表示还没读到数据，此时不占位、不报「0 个」。
/// 「个应用进程运行中」是参考实现自带的说法（zh_strings.txt:75），前面接实测条数。
String? processCountLine(int? count) =>
    count == null ? null : '$count 个应用进程运行中';

class _ProcessInfoPageState extends State<ProcessInfoPage> {
  List<ProcInfo> _procs = [];

  /// 首轮读取完成前不给计数：没读到数据就上屏「0 个应用进程运行中」是假数据。
  bool _loaded = false;

  /// 内存总量（MB），分组判据要用；读不到就不分两段（见 [splitByImpact]）
  int _totalMemMb = 0;

  @override
  void initState() {
    super.initState();
    _load();
    Stream.periodic(const Duration(seconds: 3))
        .takeWhile((_) => mounted)
        .listen((_) => _load());
  }

  Future<void> _load() async {
    List<ProcInfo> procs;
    try {
      procs = await RustApi.instance.readProcessInfo();
    } catch (e) {
      // 这一页每 3s 自动刷一次：这里抛出去没人接（timer 回调），
      // 进程列表就永远停在第一次读到的样子，看着像"进程没变"。
      // 失败时保留上一次的列表——它是真实读到的值，比清空更可信。
      // 记日志这一句现在**不可能抛**：`RustApi.logError` 内部已兜住
      // （桥未初始化时 `RustLib.api` 是同步抛的，20 多处 unawaited 调用点逐个套
      // try/catch 既漏得掉又难读，收在这一层最稳）。
      unawaited(RustApi.instance.logError('读取进程列表失败: $e'));
      return;
    }
    var total = 0;
    try {
      total = (await RustApi.instance.readMemory2()).total;
    } catch (_) {
      // 读不到就留 0：分不了组而已，列表照常出
    }
    if (mounted) {
      setState(() {
        _procs = procs;
        _totalMemMb = total;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(
          title: '进程管理',
          // 计数行取参考实现自带的「个应用进程运行中」（zh_strings.txt:75，前面接数字）；
          // 原来这里的「关闭不用的应用进程…」挪到入口卡上了（:59 在参考实现里就是卡片描述）。
          subtitle: processCountLine(_loaded ? _procs.length : null),
          onBack: () => context.go('/app_manage_dashboard')),
      Expanded(
        child: Builder(builder: (context) {
          final (optimizable, running) =
              splitByImpact(_procs, totalMemMb: _totalMemMb);
          final grouped = _totalMemMb > 0;
          final rows = <Widget>[
            if (grouped && optimizable.isNotEmpty) ...[
              const _SectionLabel('进程可优化'),
              for (final p in optimizable) _procTile(p),
            ],
            if (grouped && running.isNotEmpty) ...[
              const _SectionLabel('进行中进程'),
              for (final p in running) _procTile(p),
            ],
            if (!grouped)
              for (final p in _procs) _procTile(p),
          ];
          return ListView(padding: const EdgeInsets.all(12), children: rows);
        }),
      ),
    ]);
  }

  Widget _procTile(ProcInfo p) => ListTile(
        leading: AppIconImage(displayIcon: p.exe, size: 28),
        title:
            Text('${p.name}  (${p.pid})', style: const TextStyle(fontSize: 13)),
        subtitle: Text(processSubtitle(p),
            style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
        trailing: TextButton(
          onPressed: () async {
            // crateApiSysinfoProcessRTerminateProcess → …::process::terminate_process
            final messenger = ScaffoldMessenger.of(context);
            final ok = await confirmDestructive(context,
                title: '确定结束进程？',
                body: '${p.name}（PID ${p.pid}）将被强制结束，未保存的数据会丢失。');
            if (!ok || !mounted) return;
            try {
              await RustApi.instance.terminateProcess(p.pid);
              await _load();
            } catch (e) {
              messenger.showSnackBar(SnackBar(
                  duration: const Duration(seconds: 5),
                  content: Text(
                      perItemFailure('结束', '${p.name}（PID ${p.pid}）', e))));
            }
          },
          child: const Text('结束'),
        ),
      );
}

/// 分组小标题。参考实现那两个标题自带（`进程可优化` :481 / `进行中进程` :197），
/// 不是我们另起的说法。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSub)),
      );
}

/// 开机启动项那一页的汇总行。
///
/// 只给实测数：读到了几条、其中几条是开着的。一条都没读到就返回 null——
/// **不拿"0 个"当结论**，那会显得"查过了、确实没有"，而实际是没查到。
///
/// 「减少开机启动项可以提升开机速度」`:61` 是参考实现自带的收益说明，
/// 有可关项时才摆出来（全开着时说什么都像在劝用户做没用的事）。
String? startupSummaryText(List<StartupItem>? items) {
  if (items == null) return null;
  final total = items.length;
  final enabled = items.where((i) => i.enabled).length;
  final head = '共 $total 个启动项，$enabled 个已启用';
  final canDisable = total - enabled;
  return canDisable > 0 ? '$head，减少开机启动项可以提升开机速度' : head;
}

class StartupManagePage extends StatefulWidget {
  const StartupManagePage({super.key});

  /// 页头副标题：把**两件不同的事**分开说——
  /// 「开机启动耗时」= 这次开机花了多久（Windows 启动诊断事件的 `BootTime`，本机实测 32.0 秒），
  /// 「已开机」= 开机以后跑了多久（`LastBootUpTime` 与现在的差）。
  ///
  /// 缺哪个就不说哪个；**绝不拿后者顶替前者**（那等于对着一行字说谎，正是 #100 的由来）。
  /// 做成不依赖 State 的纯函数，是为了让"null 时不许出现这一句"这条能被直接钉住
  /// ——本页的其它判据（`startupSummaryText`）也是这个形状。
  static String? headerSubtitle({required int? startupMs, required int bootMs}) {
    final parts = <String>[
      if (startupMs != null && startupMs > 0)
        '开机启动耗时 ${formatBootDuration(startupMs)}',
      if (bootMs > 0) '已开机 ${formatDuration(bootMs)}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  State<StartupManagePage> createState() => _StartupManagePageState();
}

class _StartupManagePageState extends State<StartupManagePage> {
  /// null = 还没读到 / 读失败。**不能初始化成空列表**——那样读失败与"确实没有"
  /// 长得一模一样，界面会说「暂无可管理的开机启动项」，而那是"查过了、没有"的
  /// 意思。这是 analyzer 的 unnecessary_null_comparison 顺带查出来的。
  List<StartupItem>? _items;
  int _bootMs = 0;

  /// `_items == null` 有两种来由：**还没读到** 与 **读失败**。
  /// 原来两者都画 `SizedBox.shrink()`，于是读失败 = 一片空白 + 一条会自己消失的
  /// snackbar：页面永远停在"什么都没有"的样子，也没有任何再试一次的动作。
  /// 分开之后：失败那一支明说失败并给「重新加载」(`:225`)，未读到那一支继续不画
  /// （不画比画错好——画一张"共 0 个启动项"就是拿没查过的结果当结论）。
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 上一次开机花了多久（毫秒）。null = 读不到 ⇒ 页头不显示这一句，
  /// **不拿运行时长冒充**（那正是 #100 要避免的说谎）。
  int? _startupMs;

  /// 读启动项与开机时长。**读失败要让界面上说得出**：
  /// 原来两个 await 都没接异常，一抛就整个挂在那儿——既没有列表也没有一句解释，
  /// 用户面对的是一片空白（那看起来像"没有启动项"，而不是"没读到"）。
  Future<void> _load() async {
    final api = RustApi.instance;
    List<StartupItem>? items;
    int boot = 0;
    int? startup;
    try {
      items = await api.readStartupList();
      boot = await api.getSystemBootUpDuration();
      // 独立的一条事实：`getBootTimeMs` 自己吞异常并记日志（读不到给 null），
      // 所以它既不会把这一整次读取带崩，也不该被上面的失败连累到不显示。
      startup = await api.getBootTimeMs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('读取开机启动项失败：${bridgeErrorText(e)}')));
      }
    }
    if (!mounted) return;
    setState(() {
      // 读失败就让 _items 回到 null（= 读不到），**不**沿用上一次的旧值：
      // 摆着一份可能已经过期的列表，比说"读不到"更像真的。
      _items = items;
      _bootMs = items == null ? 0 : boot;
      // 与启动项列表、运行时长各自独立：读不到就是 null，页头少说一句而已。
      _startupMs = startup;
      // `items == null` 只可能来自 catch（成功读到"没有"会给空列表，不是 null），
      // 所以这一句就把"失败"与"没查到过"分开了。
      _failed = items == null;
    });
  }

  String? _headerSubtitle() =>
      StartupManagePage.headerSubtitle(startupMs: _startupMs, bootMs: _bootMs);

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(
          title: '开机启动项管理',
          // Rust 侧给的是 LastBootUpTime 到现在的差值（开机后的累计运行时长），
          // 不是「上一次开机花了多久」，措辞按数据本身的含义改过来。
          // 真正的「开机启动耗时」另有来源，见 _headerSubtitle()。
          subtitle: _headerSubtitle(),
          onBack: () => context.go('/app_manage_dashboard')),
      Expanded(child: _buildBody()),
    ]);
  }

  /// 列表体。三态要分清：
  /// - 还没读到 / 读失败（`_items == null`）：什么都不画。画一张"共 0 个启动项"
  ///   等于拿没查过的结果当结论——那是"查过了、确实没有"的意思。
  /// - 读到了但是空的：才摆空态。
  /// - 有内容：汇总行 + 列表。
  Widget _buildBody() {
    final items = _items;
    if (items == null) {
      if (!_failed) return const SizedBox.shrink();
      // 「获取开机启动项出错」是参考实现自带说法（表里另有一条近义的
      // 「获取开机自启动项错误。」，带句号、看着像日志句——取能当标签用的这条）。
      // 重试按钮用自带的「重新加载」(`:225`)：读失败原来是个死胡同。
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const EmptyView(text: '获取开机启动项出错'),
        const SizedBox(height: 10),
        TextButton(onPressed: _load, child: const Text('重新加载')),
      ]));
    }
    if (items.isEmpty) return const EmptyView(text: '暂无可管理的开机启动项');
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(startupSummaryText(items)!,
              style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
        ),
        for (final it in items)
          SwitchListTile(
            value: it.enabled,
            onChanged: (v) async {
              // crateApiSysinfoStartupRChangeStartupStatus → …::startup::change_startup_status
              // 失败（例如 HKLM 项需要管理员）后必须重读：否则开关停在用户刚拨的
              // 那一格，注册表却纹丝不动，界面从此和真实启动项不一致。
              final messenger = ScaffoldMessenger.of(context);
              try {
                await RustApi.instance.changeStartupStatus(it, v);
              } catch (e) {
                // 列表里十几条，只说"修改启动项失败"用户不知道是哪一条——
                // 报错要带上名字与位置，才对得上他刚拨的那一格。
                messenger.showSnackBar(SnackBar(
                    duration: const Duration(seconds: 5),
                    content: Text(perItemFailure(
                        '修改启动项', '${it.name}（${it.location}）', e))));
              }
              await _load();
            },
            title: Text(it.name, style: const TextStyle(fontSize: 14)),
            subtitle: Text(it.location, style: const TextStyle(fontSize: 11)),
          ),
      ],
    );
  }
}
