import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 工具箱 —— 路由 /tool_box_dashboard
/// 子页：net_speed_test / patch_test（另有未开放的：设备检测 / 打印设备 / 安全盘）
class ToolBoxDashboardPage extends StatelessWidget {
  const ToolBoxDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_net_speed_test.webp',
                title: '网速测试',
                subtitle: '下载 / 上传 / 延迟 / 抖动',
                onTap: () => context.go('/tool_box_dashboard/net_speed_test'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_patch.webp',
                title: '漏洞补丁检测',
                subtitle: '查看已安装的补丁',
                onTap: () => context.go('/tool_box_dashboard/patch_test'))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_device_detect.webp',
                title: '设备检测',
                subtitle: '硬件与组件状态')),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_security_disk.webp',
                title: '安全盘',
                subtitle: '智慧盘虚拟磁盘')),
      ]),
    ]);
  }
}

class NetSpeedTestPage extends StatefulWidget {
  const NetSpeedTestPage({super.key});

  @override
  State<NetSpeedTestPage> createState() => _NetSpeedTestPageState();
}

class _NetSpeedTestPageState extends State<NetSpeedTestPage> {
  bool _running = false;
  NetSpeedResult? _result;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      final r = await RustApi.instance.measureNetSpeed();
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = bridgeErrorText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Column(children: [
      PageHeader(
          title: '网速测试',
          subtitle: '实测链路往返时延与采样窗口内的网卡收发速率',
          onBack: () => context.go('/tool_box_dashboard')),
      Expanded(
        child: Center(
          child: _running
              ? ScanningBanner(text: '正在采样…', lottie: 'deep_scan_loading.json')
              : _error != null
                  ? EmptyView(text: '采样未完成：$_error')
                  : r == null
                      ? FilledButton(
                          onPressed: _start,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(180, 48)),
                          child: const Text('开始测速'))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          Wrap(spacing: 24, runSpacing: 14, children: [
                            _Metric('下行', formatRate(r.downBps)),
                            _Metric('上行', formatRate(r.upBps)),
                            _Metric(
                                '往返时延', r.reachable ? '${r.rttMs} ms' : '不可达'),
                            _Metric(
                                '抖动', r.reachable ? '${r.jitterMs} ms' : '—'),
                          ]),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 60),
                            child: Text(
                              r.reachable
                                  ? '往返时延取 ${r.probes} 次 TCP 握手的平均值；上下行取同一窗口内网卡计数器的增量，反映此刻的真实流量，不是签约带宽上限。'
                                  : '探测点无响应：本机当前没有可用外网链路，因此没有时延与抖动数据。',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textSub),
                            ),
                          ),
                          const SizedBox(height: 20),
                          OutlinedButton(
                              onPressed: _start, child: const Text('再测一次')),
                        ]),
        ),
      ),
    ]);
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value,
          style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: AppTheme.primary)),
      const SizedBox(height: 2),
      Text(label,
          style: const TextStyle(color: AppTheme.textSub, fontSize: 12)),
    ]);
  }
}

class PatchTestPage extends StatefulWidget {
  const PatchTestPage({super.key});

  @override
  State<PatchTestPage> createState() => _PatchTestPageState();
}

class _PatchTestPageState extends State<PatchTestPage> {
  List<PatchEntry> _patches = [];

  /// Windows 自己记下的重启挂起来源（cbs / wu / rename）
  List<String> _reboot = [];

  @override
  void initState() {
    super.initState();
    // crateApiSysinfoPatchesRGetInstalledPatchIds → api::sysinfo::patches::get_installed_patch_ids
    RustApi.instance
        .getPatchList()
        .then((v) => mounted ? setState(() => _patches = v) : null);
    RustApi.instance.rebootPendingReasons().then((v) {
      if (mounted) setState(() => _reboot = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final notice = rebootNotice(_reboot);
    return Column(children: [
      PageHeader(
          title: '漏洞补丁检测',
          subtitle: '列出系统已安装的补丁，可逐个卸载',
          onBack: () => context.go('/tool_box_dashboard')),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(children: [
                const Icon(Icons.restart_alt, size: 16, color: AppTheme.warn),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(notice,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.warn))),
              ]),
            ),
          for (final p in _patches)
            ListTile(
              leading:
                  const Icon(Icons.system_update_alt, color: AppTheme.primary),
              title: Text(dedupTitle(p.id, p.title),
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(p.kind,
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.textSub)),
              // 列表出自 get_installed_patch_ids（已装的补丁），所以这一行的动作是
              // 卸载而不是安装——参考实现文案表里也是「卸载补丁/补丁卸载失败」。
              trailing: FilledButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final ok = await confirmDestructive(context,
                      title: '卸载补丁', body: '确定卸载 ${p.id}？安全更新卸载后需重新安装才能恢复。');
                  if (!ok || !mounted) return;
                  try {
                    // wusa.exe /uninstall 需管理员权限，返回它的输出文本。
                    final out = await RustApi.instance.uninstallPatch(p);
                    // wusa 走 /quiet，成功时基本没有输出，原样插值会显示成空尾巴。
                    messenger.showSnackBar(SnackBar(
                        content: Text(out.trim().isEmpty
                            ? '卸载补丁完成：${p.id}'
                            : '卸载补丁 ${p.id}：${out.trim()}')));
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(
                        content: Text('补丁卸载失败：${bridgeErrorText(e)}')));
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
