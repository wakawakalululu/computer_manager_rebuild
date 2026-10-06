import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../services/examination.dart';

/// 首页上的体检面板：点「立即体检」就地跑一轮，结果与修复入口都留在这一页。
///
/// 参考实现的首页路由本身就是 `/dashboard/examination`（`specs/routes_ui.txt`），
/// `classes.txt` 里 `_ExaminationPageState` 下头直接挂着
/// `_ExaminationCheckContentState` 与 `_ExaminationRepairContentState`——
/// 检查内容和修复入口是同一页上的两段，不是弹层。
///
/// 这一层只做检查：待处理项的动作是跳进对应二级页，删除类动作在那边还要再过一次
/// 二次确认，面板自己不落到任何写操作。
class ExaminationPanel extends StatefulWidget {
  const ExaminationPanel({super.key, required this.runner, this.onCollapse});

  final ExaminationRunner runner;

  /// 「收起」——面板只在这一轮跑完后给一个收回去的出口，收起后再点「立即体检」是重跑
  final VoidCallback? onCollapse;

  @override
  State<ExaminationPanel> createState() => _ExaminationPanelState();
}

class _ExaminationPanelState extends State<ExaminationPanel> {
  /// 检查项按这个顺序排队，跑完一项点亮一项。
  static const _titles = ['常驻组件', '网络', '内存', '开机启动项', '回收站', '磁盘空间', '应用兼容性'];

  List<ExamineItem> _done = [];
  bool _finished = false;

  /// 上一次体检落在什么时候。参考实现首页状态栏就写着「上次体检时间」。
  int? _lastAt;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLast());
    unawaited(_start());
  }

  Future<void> _loadLast() async {
    final at = await readLastExaminationAt();
    if (mounted) setState(() => _lastAt = at);
  }

  Future<void> _start() async {
    await widget.runner.run(onProgress: (list) {
      if (mounted) setState(() => _done = List.of(list));
    });
    // 一轮跑完才记时间：中途取数失败也算跑过，但没跑完不写「上次体检时间」。
    final now = DateTime.now().millisecondsSinceEpoch;
    await writeLastExaminationAt(now);
    if (mounted) {
      setState(() {
        _lastAt = now;
        _finished = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _done.where((e) => e.needsAction).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('全面体检',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.textMain)),
        const SizedBox(height: 4),
        Text(formatLastExamination(_lastAt),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
        const SizedBox(height: 6),
        for (var i = 0; i < _titles.length; i++)
          _row(i < _done.length ? _done[i] : null, _titles[i]),
        if (_finished) ...[
          const SizedBox(height: 4),
          Text(
            // 「均已优化」不能说给一项都没检查过的机器：有未配置项时如实报未配置。
            pending.isNotEmpty
                ? '共 ${_titles.length} 项，${pending.length} 项可优化'
                : _done.any((e) => e.verdict == ExamineVerdict.skipped)
                    ? '共 ${_titles.length} 项，'
                        '${_done.where((e) => e.verdict == ExamineVerdict.skipped).length} 项未配置'
                    : '共 ${_titles.length} 项，均已优化',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
          if (pending.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => context.go(pending.first.route!),
                child: Text('去处理：${pending.first.title}'),
              ),
            ),
        ],
        if (_finished && widget.onCollapse != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: widget.onCollapse, child: const Text('收起')),
          ),
      ]),
    );
  }

  /// 一行检查项。没用 ListTile：它按 title+subtitle 撑高度，六行下来每一行约 70 逻辑
  /// 像素，首页那一屏放不下；这里按固定行高压，六项一眼看全。
  Widget _row(ExamineItem? item, String title) {
    final color = switch (item?.verdict) {
      ExamineVerdict.ok => AppTheme.ok,
      ExamineVerdict.needFix => AppTheme.warn,
      _ => AppTheme.textSub,
    };
    final icon = switch (item?.verdict) {
      ExamineVerdict.ok => Icons.check_circle_outline,
      ExamineVerdict.needFix => Icons.error_outline,
      ExamineVerdict.failed => Icons.help_outline,
      // 未配置 ≠ 正在检查：没有这个分支的话，它会转着圈显示成「正在检查…」
      ExamineVerdict.skipped => Icons.stop_circle_outlined,
      _ => null,
    };
    return SizedBox(
      height: 46,
      child: Row(children: [
        SizedBox(
            width: 18,
            height: 18,
            child: icon == null
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Icon(icon, size: 18, color: color)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                if (item != null) ...[
                  const SizedBox(width: 8),
                  Text(examineBadge(item),
                      style: TextStyle(fontSize: 11, color: color)),
                ],
              ]),
              Text(item?.detail ?? '正在检查…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.textSub)),
            ],
          ),
        ),
        if (item != null && item.needsAction && item.route != null)
          TextButton(
            onPressed: () => context.go(item.route!),
            child: Text(item.actionLabel ?? '查看'),
          ),
      ]),
    );
  }
}
