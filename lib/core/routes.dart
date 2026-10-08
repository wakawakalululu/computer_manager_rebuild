import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../pages/app_manage_page.dart';
import '../pages/dashboard_page.dart';
import '../pages/disk_clean_page.dart';
import '../pages/settings_page.dart';
import '../pages/tool_box_page.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';
import 'theme.dart';

/// 左侧导航壳 —— 路由表 1:1 对照规格整理出的 go_router 结构：
/// /dashboard/examination · /disk_clean_dashboard/* · /app_manage_dashboard/*
/// /tool_box_dashboard/* · /app_setting_route/*
class ManagerShell extends StatefulWidget {
  const ManagerShell({super.key, required this.shell, required this.child});
  final StatefulNavigationShell shell;
  final Widget child;

  @override
  State<ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends State<ManagerShell> {
  int _memPct = 0;

  @override
  void initState() {
    super.initState();
    Stream.periodic(const Duration(seconds: 2)).listen((_) async {
      // 与首页同一个坑：`listen` 返回的 Future **没人接**，一次 readMemory2 抛异常
      // 就让这个轮询**永久停摆**——而导航栏上的内存百分比会**停在最后一个正常值**，
      // 看上去完全像在实时更新。失败就保留旧值，下一轮 2s 后自然重试。
      try {
        final mem = await RustApi.instance.readMemory2();
        if (mounted) setState(() => _memPct = (mem.ratio * 100).round());
      } catch (e) {
        unawaited(RustApi.instance.logError('刷新导航栏内存占用失败（保留上一次读数）: $e'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        const TitleBar(),
        Expanded(
          child: Row(children: [
            _Nav(shell: widget.shell, memPct: _memPct),
            Expanded(child: widget.child),
          ]),
        ),
      ]),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({required this.shell, required this.memPct});
  final StatefulNavigationShell shell;
  final int memPct;

  static const _items = [
    (Icons.dashboard_outlined, '首页', '/dashboard/examination'),
    (Icons.cleaning_services_outlined, '清理', '/disk_clean_dashboard'),
    (Icons.apps_outlined, '应用', '/app_manage_dashboard'),
    (Icons.home_repair_service_outlined, '工具', '/tool_box_dashboard'),
    (Icons.settings_outlined, '设置', '/app_setting_route'),
  ];

  @override
  Widget build(BuildContext context) {
    final current = GoRouterState.of(context).uri.toString();
    return Container(
      width: 84,
      color: AppTheme.cardBg,
      child: Column(children: [
        const SizedBox(height: 8),
        for (final it in _items)
          InkWell(
            onTap: () =>
                shell.goBranch(_items.indexOf(it), initialLocation: true),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color:
                    current.startsWith(it.$3) ? const Color(0xFFEAF1FF) : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(children: [
                Icon(it.$1,
                    size: 22,
                    color: current.startsWith(it.$3)
                        ? AppTheme.primary
                        : AppTheme.textSub),
                const SizedBox(height: 3),
                Text(it.$2,
                    style: TextStyle(
                        fontSize: 11,
                        color: current.startsWith(it.$3)
                            ? AppTheme.primary
                            : AppTheme.textSub)),
              ]),
            ),
          ),
        const Spacer(),
        Text('内存 $memPct%',
            style: const TextStyle(color: AppTheme.textSub, fontSize: 10)),
        const SizedBox(height: 12),
      ]),
    );
  }
}

GoRouter buildRouter() => GoRouter(
      initialLocation: '/dashboard/examination',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) =>
              ManagerShell(shell: shell, child: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/dashboard/examination',
                  builder: (_, __) => const ExaminationPage()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/disk_clean_dashboard',
                builder: (_, __) => const DiskCleanDashboardPage(),
                routes: [
                  GoRoute(
                      path: 'deep_clean_scan',
                      builder: (_, __) => const DeepCleanScanPage()),
                  GoRoute(
                      path: 'large_file_scan',
                      builder: (_, __) => const LargeFileScanPage()),
                  GoRoute(
                      path: 'duplicate_file_scan',
                      builder: (_, __) => const DuplicateFileScanPage()),
                  GoRoute(
                      path: 'system_disk_files',
                      builder: (_, __) => const SystemDiskFilesPage()),
                ],
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/app_manage_dashboard',
                builder: (_, __) => const AppManageDashboardPage(),
                routes: [
                  GoRoute(
                      path: 'process_info',
                      builder: (_, __) => const ProcessInfoPage()),
                  GoRoute(
                      path: 'startup_manage',
                      builder: (_, __) => const StartupManagePage()),
                ],
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/tool_box_dashboard',
                builder: (_, __) => const ToolBoxDashboardPage(),
                routes: [
                  GoRoute(
                      path: 'net_speed_test',
                      builder: (_, __) => const NetSpeedTestPage()),
                  GoRoute(
                      path: 'patch_test',
                      builder: (_, __) => const PatchTestPage()),
                  GoRoute(
                      path: 'security_disk',
                      builder: (_, __) => const SecurityDiskPage()),
                ],
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/app_setting_route',
                builder: (_, __) => const AppSettingPage(),
                routes: [
                  GoRoute(
                      path: 'app_about',
                      builder: (_, __) => const AppAboutPage()),
                  GoRoute(
                      path: 'feedback',
                      builder: (_, __) => const FeedbackPage()),
                ],
              ),
            ]),
          ],
        ),
      ],
    );
