import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/theme.dart';
import '../services/examination.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';
import '../widgets/examination_panel.dart';

/// 首页体检 —— 路由 /dashboard/examination
/// 参考实现类名指纹：_ExaminationAnimatedComponentItemCardState、
/// _ExaminationAnimatedNetworkItemCardState（动画卡片）。
/// 页头那个健康评分环是净室分支自己加的（参考实现文案表里没有「评分」，
/// 类名表里也没有 Score/Ring 一类控件），数值取自实测 CPU/内存/磁盘占比。
class ExaminationPage extends StatefulWidget {
  const ExaminationPage({super.key});

  @override
  State<ExaminationPage> createState() => _ExaminationPageState();
}

class _ExaminationPageState extends State<ExaminationPage> {
  CpuInfo? _cpu;
  MemoryInfo? _mem;
  List<DiskInfo> _disks = [];
  NetInfo? _net;
  final _cpuHist = <double>[];
  final _memHist = <double>[];

  /// 体检面板是否展开，以及第几轮（换 key 就重跑）。
  bool _examOpen = false;
  int _examSeq = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    Stream.periodic(const Duration(seconds: 2))
        .takeWhile((_) => mounted)
        .listen((_) => _refresh());
  }

  Future<void> _refresh() async {
    final api = RustApi.instance;
    final cpu = await api.readCupInfo();
    final mem = await api.readMemory2();
    final disks = await api.getDiskInfoList();
    final net = await api.getNetInfo();
    if (!mounted) return;
    setState(() {
      _cpu = cpu;
      _mem = mem;
      _disks = disks;
      _net = net;
      _cpuHist.add(cpu.usage);
      _memHist.add(mem.ratio * 100);
      if (_cpuHist.length > 30) _cpuHist.removeAt(0);
      if (_memHist.length > 30) _memHist.removeAt(0);
    });
    _checkThresholds(cpu, mem, disks);
  }

  /// 阈值告警 —— 占用超过 90% 时触发参考实现同款弹窗。
  /// 轮询每 2s 调一次，防重复由 ThresholdPopups.seen 集合 + 本地“不再提示”承担。
  /// 三个弹窗的键名（RAM_window / CPU_window / SystemDisk_window）与参考实现的点击
  /// 事件名同源，主动作 id 也照事件表里的英文标识写（expedite / ProcessManagement /
  /// deepclean），埋点才能对上。
  void _checkThresholds(CpuInfo? cpu, MemoryInfo mem, List<DiskInfo> disks) {
    if (cpu != null && cpu.usage > 90) {
      unawaited(ThresholdPopups.maybeShow(
        key: 'CPU_window',
        title: 'CPU 占用过高',
        // 两句都取参考实现文案表自带的串（zh_strings.txt:291、:215）
        body: '您的电脑CPU使用率已达 ${cpu.usage.round()}%，'
            '建议您关闭CPU占用率较高的应用',
        actionLabel: '进程管理',
        actionId: 'ProcessManagement',
        action: () {},
        route: '/app_manage_dashboard/process_info',
      ));
    }
    if (mem.ratio > 0.9) {
      unawaited(ThresholdPopups.maybeShow(
        key: 'RAM_window',
        title: '内存占用过高',
        body: '检测到内存占用过高，可一键关闭后台进程释放资源。',
        actionLabel: '立即加速',
        actionId: 'expedite',
        action: () => RustApi.instance.processesMemoryOptimization(),
        route: '/app_manage_dashboard/process_info',
      ));
    }
    for (final d in disks) {
      if (d.ratio > 0.9) {
        unawaited(ThresholdPopups.maybeShow(
          key: 'SystemDisk_window',
          title: '系统盘空间不足',
          // 前半句取参考实现自带的「您的电脑系统盘使用率已达」（zh_strings.txt:510）
          body: '您的电脑系统盘使用率已达 ${(d.ratio * 100).round()}%，建议深度清理。',
          actionLabel: '深度清理',
          actionId: 'deepclean',
          route: '/disk_clean_dashboard/deep_clean_scan',
          action: () {},
        ));
        break; // 任一磁盘超阈值只提示一次
      }
    }
  }

  int get _score {
    var s = 100;
    if (_cpu != null) s -= (_cpu!.usage / 4).round();
    if (_mem != null) s -= (_mem!.ratio * 20).round();
    for (final d in _disks) {
      s -= (d.ratio * 10).round();
    }
    return s.clamp(5, 100);
  }

  /// 立即体检：在首页这一页就地跑一轮（参考实现的检查内容就在首页路由上）。
  /// 每次点都把面板换一个新 key，重跑一遍；跑完的结果留在页上。
  void _examine() => setState(() {
        _examOpen = true;
        _examSeq++;
      });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _ScoreCard(score: _score, onExamine: _examine),
        const SizedBox(height: 14),
        if (_examOpen) ...[
          ExaminationPanel(
            key: ValueKey(_examSeq),
            runner: ExaminationRunner(ExamineSource.fromBridge()),
            onCollapse: () => setState(() => _examOpen = false),
          ),
          const SizedBox(height: 14),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: _MonitorCard(title: 'CPU', hist: _cpuHist, unit: '%')),
          const SizedBox(width: 12),
          Expanded(child: _MonitorCard(title: '内存', hist: _memHist, unit: '%')),
        ]),
        const SizedBox(height: 12),
        for (final d in _disks)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: UsageBar(
              label: '磁盘 ${d.letter}',
              ratio: d.ratio,
              detail: '${(d.free >> 30)}G 可用 / ${(d.total >> 30)}G',
            ),
          ),
        if (_net != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: UsageBar(
                label: '网络（${_net!.ipv4}）',
                ratio: _net!.available ? 0.3 : 0,
                detail: _net!.available ? '连接正常' : '未连接'),
          ),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
              child: EntryCard(
                  icon: 'icon_net_speed_test.webp',
                  title: '网速测试',
                  subtitle: '当前网络环境测速',
                  onTap: () =>
                      context.go('/tool_box_dashboard/net_speed_test'))),
          const SizedBox(width: 12),
          Expanded(
              child: EntryCard(
                  icon: 'icon_process.webp',
                  title: '进程管理',
                  subtitle: '关闭不用的应用进程，提升设备速度',
                  onTap: () =>
                      context.go('/app_manage_dashboard/process_info'))),
        ]),
      ]),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score, required this.onExamine});
  final int score;

  /// 「立即体检」的动作。原来它是 `onPressed: () {}`——首页最显眼的主动作按钮
  /// 点下去什么都不发生，比没有按钮更糟。
  final VoidCallback onExamine;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          gradient: AppTheme.headerGradient,
          borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        SizedBox(
          width: 92,
          height: 92,
          child: CustomPaint(
              painter: _ScoreRing(score / 100),
              child: Center(
                child: Text('$score',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800)),
              )),
        ),
        const SizedBox(width: 18),
        const Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('设备健康评分',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text('全面体检 · 启动检查 · 垃圾清理一键直达',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Colors.white, foregroundColor: AppTheme.primary),
          onPressed: onExamine,
          child: const Text('立即体检'),
        ),
      ]),
    );
  }
}

class _ScoreRing extends CustomPainter {
  _ScoreRing(this.v);
  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = Colors.white24;
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), 0, 6.2832, false, bg);
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r), -1.5708, 6.2832 * v, false, fg);
  }

  @override
  bool shouldRepaint(covariant _ScoreRing old) => old.v != v;
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard(
      {required this.title, required this.hist, required this.unit});
  final String title;
  final List<double> hist;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final now = hist.isEmpty ? 0.0 : hist.last;
    return Container(
      height: 150,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${now.toStringAsFixed(0)}$unit',
              style: const TextStyle(
                  color: AppTheme.primary, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: LineChart(
            LineChartData(
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              minY: 0,
              maxY: 100,
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < hist.length; i++)
                      FlSpot(i.toDouble(), hist[i])
                  ],
                  isCurved: true,
                  barWidth: 2,
                  color: AppTheme.primary,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                      show: true,
                      color: AppTheme.primary.withValues(alpha: 0.08)),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
