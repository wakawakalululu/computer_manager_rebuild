import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 清理面板 —— 路由 /disk_clean_dashboard
/// 子页对照规格整理路由：deep_clean_scan / large_file_scan /
/// duplicate_file_scan / system_disk_files
class DiskCleanDashboardPage extends StatelessWidget {
  const DiskCleanDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_dashboard_disk_clean.webp',
                title: '深度清理',
                subtitle: '按规则库清理系统缓存',
                onTap: () =>
                    context.go('/disk_clean_dashboard/deep_clean_scan'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_large_files.webp',
                title: '大文件',
                subtitle: '找出占用空间的大文件',
                onTap: () =>
                    context.go('/disk_clean_dashboard/large_file_scan'))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_duplicate_files.webp',
                title: '重复文件',
                subtitle: '释放重复占用的磁盘空间',
                onTap: () =>
                    context.go('/disk_clean_dashboard/duplicate_file_scan'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_system_disk_files.webp',
                title: '系统盘文件',
                subtitle: '分析 C 盘空间构成',
                onTap: () =>
                    context.go('/disk_clean_dashboard/system_disk_files'))),
      ]),
      const SizedBox(height: 12),
      const _RecycleBinCard(),
    ]);
  }
}

class _RecycleBinCard extends StatefulWidget {
  const _RecycleBinCard();

  @override
  State<_RecycleBinCard> createState() => _RecycleBinCardState();
}

class _RecycleBinCardState extends State<_RecycleBinCard> {
  String _human = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final size = await RustApi.instance.getRecycleBinSize();
    if (mounted) setState(() => _human = size);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.delete_outline, size: 30, color: AppTheme.primary),
        const SizedBox(width: 12),
        Expanded(
            child: Text('回收站  $_human，可一键清空',
                style: const TextStyle(fontSize: 14))),
        OutlinedButton(
          onPressed: () async {
            // crateApiDiskScanDeepCleanREmptyRecycleBin → …::deep_clean::empty_recycle_bin
            final messenger = ScaffoldMessenger.of(context);
            final ok = await confirmDestructive(context,
                title: '确定要清空回收站吗？', body: '清理后会导致回收站文件无法恢复。');
            if (!ok || !mounted) return;
            try {
              await RustApi.instance.emptyRecycleBin();
              await _load();
            } catch (e) {
              messenger.showSnackBar(
                  SnackBar(content: Text('清空回收站失败：${bridgeErrorText(e)}')));
            }
          },
          child: const Text('清空'),
        ),
      ]),
    );
  }
}

/// 四个扫描页共用骨架 —— 还原参考实现三态：扫描中(Lottie) → 结果勾选 → 清理完成
class ScanPageScaffold extends StatefulWidget {
  const ScanPageScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.stream,
    required this.cancelKey,
    this.actionLabel = '立即清理',
    this.lottie = 'deep_scan_loading.json',
    this.readOnly = false,
    this.onClean,
  });

  final String title;
  final String subtitle;
  final String cancelKey;
  final String actionLabel;
  final Stream<List<CleanItem>> stream;

  /// 扫描中的动图，参考实现四个扫描页各有一支（见 assets/lottie/）。
  final String lottie;

  /// 只读结果页：不画勾选框、也不给「立即清理」。系统盘文件是 C 盘空间构成
  /// 分析，列出来的是 C:\Windows、C:\Program Files 这类目录，给一个「全选 +
  /// 立即清理」等于摆了一个删系统的按钮。
  final bool readOnly;

  /// 自定义清理动作（深度清理走 Rust 侧 clean_deep_clean，需按规则删文件并处理
  /// REMOVESELF 目录）；为空时按勾选路径调用 delete_file。
  final Future<void> Function(List<CleanItem> selected)? onClean;

  @override
  State<ScanPageScaffold> createState() => _ScanPageScaffoldState();
}

class _ScanPageScaffoldState extends State<ScanPageScaffold> {
  List<CleanItem>? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.stream.listen(
      (items) => mounted
          ? setState(() {
              _result = items;
              _error = null;
            })
          : null,
      onError: (Object e) => mounted ? setState(() => _error = '$e') : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(children: [
      PageHeader(
          title: widget.title,
          subtitle: widget.subtitle,
          onBack: () => context.go('/disk_clean_dashboard')),
      Expanded(
        child: _error != null
            ? Center(child: EmptyView(text: '扫描未完成：${_error!}'))
            : result == null
                ? Center(
                    child: ScanningBanner(
                        text: '正在检测…',
                        lottie: widget.lottie,
                        onCancel: () =>
                            RustApi.instance.cancel(widget.cancelKey)))
                : result.isEmpty
                    ? const EmptyView(text: '很干净，没有发现可清理项')
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: result.length,
                        itemBuilder: (_, i) {
                          final it = result[i];
                          final subtitle = Text('${it.size} MB',
                              style: const TextStyle(color: AppTheme.textSub));
                          if (widget.readOnly) {
                            return ListTile(
                              title: Text(it.path,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: subtitle,
                            );
                          }
                          return CheckboxListTile(
                            value: it.checked,
                            onChanged: (v) =>
                                setState(() => it.checked = v ?? false),
                            title: Text(it.path,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: subtitle,
                          );
                        },
                      ),
      ),
      if (result != null &&
          result.isNotEmpty &&
          _error == null &&
          !widget.readOnly)
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () async {
              final selected = result.where((e) => e.checked).toList();
              final onClean = widget.onClean;
              final messenger = ScaffoldMessenger.of(context);
              // delete_file 是 fs::remove_file，不进回收站；清理前必须过一次确认。
              final ok = await confirmDestructive(context,
                  title: widget.actionLabel,
                  body: '共 ${selected.length} 项。'
                      '所选项删除后不可恢复，请慎重清理');
              if (!ok || !mounted) return;
              try {
                if (onClean != null) {
                  await onClean(selected);
                } else {
                  // crateApiDiskScanDiskToolsRDeleteFile → api::disk_scan::disk_tools::delete_file
                  await RustApi.instance.deleteFile(selected);
                }
                if (mounted) setState(() => _result = []);
              } catch (e) {
                // 失败原来只是 await 抛出去没人接，页面停在结果列表上像是清理成功了。
                messenger.showSnackBar(SnackBar(
                    content: Text('以下文件删除失败，请尝试手动删除：${bridgeErrorText(e)}')));
              }
            },
            style: FilledButton.styleFrom(minimumSize: const Size(220, 44)),
            child: Text(widget.actionLabel),
          ),
        ),
    ]);
  }
}

class DeepCleanScanPage extends StatelessWidget {
  const DeepCleanScanPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '深度清理',
      subtitle: '按清理规则库扫描系统缓存与垃圾文件',
      stream: RustApi.instance.scanDeepClean(),
      cancelKey: 'deep_clean',
      onClean: (_) => RustApi.instance.cleanDeepClean());
}

class LargeFileScanPage extends StatelessWidget {
  const LargeFileScanPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '大文件扫描',
      subtitle: '快速定位大体积文件',
      stream: RustApi.instance.largeFileScan(),
      cancelKey: 'large_file',
      lottie: 'large_files_loading.json');
}

class DuplicateFileScanPage extends StatelessWidget {
  const DuplicateFileScanPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '重复文件',
      subtitle: '基于内容指纹查找重复文件',
      stream: RustApi.instance.duplicateFileScan(),
      cancelKey: 'dup_file',
      lottie: 'duplicate_files_loading.json');
}

class SystemDiskFilesPage extends StatelessWidget {
  const SystemDiskFilesPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '系统盘文件',
      subtitle: '分析 C 盘空间占用构成',
      stream: RustApi.instance.systemDiskScan(),
      cancelKey: 'system_disk',
      readOnly: true,
      lottie: 'system_disk_files_loading.json');
}
