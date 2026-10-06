import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/theme.dart';
import '../services/app_compatibility.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 应用管理面板 —— 路由 /app_manage_dashboard
/// 子页：process_info（进程管理）/ startup_manage（启动项管理）
class AppManageDashboardPage extends StatefulWidget {
  const AppManageDashboardPage({super.key});

  @override
  State<AppManageDashboardPage> createState() => _AppManageDashboardPageState();
}

class _AppManageDashboardPageState extends State<AppManageDashboardPage> {
  List<AppEntry> _apps = [];

  /// 兼容性清单（来自随包 config.ini 的 `[compat] incompatible`）。为空表示
  /// 「没配判定标准」，此时不显示任何兼容性结论。
  List<String> _patterns = [];
  List<AppEntry> _compatHits = [];
  bool _compatChecked = false;

  @override
  void initState() {
    super.initState();
    // crateApiSysinfoAppCheckRCheckApp2 → api::sysinfo::app_check::check_app2
    RustApi.instance.checkApp2().then((v) {
      if (mounted) setState(() => _apps = v);
      unawaited(_checkCompat(v));
    });
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
                title: '进程管理',
                subtitle: '查看并结束占用资源的进程',
                onTap: () => context.go('/app_manage_dashboard/process_info'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'img_dashboard_startup.webp',
                title: '启动项管理',
                subtitle: '管理开机自启动，缩短开机时长',
                onTap: () =>
                    context.go('/app_manage_dashboard/startup_manage'))),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('已安装应用', style: TextStyle(fontWeight: FontWeight.w700)),
          // 兼容性结论只在真的配了判定标准时出现；没配就是没检查，不说「兼容」。
          if (_compatChecked && _patterns.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
                _compatHits.isEmpty
                    ? kCompatCleanMessage
                    : '发现 ${_compatHits.length} 个可能存在兼容性问题的应用',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
          ],
          const SizedBox(height: 6),
          for (final app in _apps)
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
                  } catch (e) {
                    messenger.showSnackBar(
                        SnackBar(content: Text('卸载失败：${bridgeErrorText(e)}')));
                  }
                },
                child: const Text('卸载'),
              ),
            ),
        ]),
      ),
    ]);
  }
}

class ProcessInfoPage extends StatefulWidget {
  const ProcessInfoPage({super.key});

  @override
  State<ProcessInfoPage> createState() => _ProcessInfoPageState();
}

class _ProcessInfoPageState extends State<ProcessInfoPage> {
  List<ProcInfo> _procs = [];

  @override
  void initState() {
    super.initState();
    _load();
    Stream.periodic(const Duration(seconds: 3))
        .takeWhile((_) => mounted)
        .listen((_) => _load());
  }

  Future<void> _load() async {
    final procs = await RustApi.instance.readProcessInfo();
    if (mounted) setState(() => _procs = procs);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(
          title: '进程管理',
          subtitle: '关闭不用的应用进程，提升设备速度',
          onBack: () => context.go('/app_manage_dashboard')),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          for (final p in _procs)
            ListTile(
              leading: AppIconImage(displayIcon: p.exe, size: 28),
              title: Text('${p.name}  (${p.pid})',
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                  'CPU ${p.cpu.toStringAsFixed(1)}%   内存 ${p.mem} MB',
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.textSub)),
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
                        content: Text('结束进程失败：${bridgeErrorText(e)}')));
                  }
                },
                child: const Text('结束'),
              ),
            ),
        ]),
      ),
    ]);
  }
}

class StartupManagePage extends StatefulWidget {
  const StartupManagePage({super.key});

  @override
  State<StartupManagePage> createState() => _StartupManagePageState();
}

class _StartupManagePageState extends State<StartupManagePage> {
  List<StartupItem> _items = [];
  int _bootMs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = RustApi.instance;
    final items = await api.readStartupList();
    final boot = await api.getSystemBootUpDuration();
    if (mounted) {
      setState(() {
        _items = items;
        _bootMs = boot;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(
          title: '启动项管理',
          // Rust 侧给的是 LastBootUpTime 到现在的差值（开机后的累计运行时长），
          // 不是「上一次开机花了多久」，措辞按数据本身的含义改过来。
          subtitle: _bootMs > 0 ? '已开机 ${formatDuration(_bootMs)}' : null,
          onBack: () => context.go('/app_manage_dashboard')),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          for (final it in _items)
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
                  messenger.showSnackBar(
                      SnackBar(content: Text('修改启动项失败：${bridgeErrorText(e)}')));
                }
                await _load();
              },
              title: Text(it.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(it.location, style: const TextStyle(fontSize: 11)),
            ),
        ]),
      ),
    ]);
  }
}
