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

  /// 轮询每 2s 一次。四次读取里**任何一次抛异常，整轮都会中断**——
  /// 而抛出去的地方是 `Stream.periodic(...).listen(...)`，那个 Future 没人接，
  /// 于是这一轮的数字再也不更新：面板**看起来还是"活的"（曲线停在旧值）**，
  /// 实际已经死了，下一轮也起不来。
  ///
  /// 所以整轮包一层 catch：失败就保留上一轮的读数（那是真实测过的值，比清空可信），
  /// 记一条日志，下一轮 2s 后自然会重试。
  Future<void> _refresh() async {
    try {
      await _refreshOnce();
    } catch (e) {
      unawaited(RustApi.instance.logError('刷新首页数据失败（保留上一轮读数）: $e'));
    }
  }

  Future<void> _refreshOnce() async {
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
  /// 轮询每 2s 调一次，防重复由 claimReminder（本轮只弹一次）+ 「设置—高负载提示」
  /// 里的开关承担。
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
        // 标题取参考实现自带的「内存高负载提示」（zh_strings.txt:262）
        title: '内存高负载提示',
        // 两句都取参考实现自带的串（zh_strings.txt:579、:182），与 CPU 那条同一句式
        body: '您的电脑内存使用率已达 ${(mem.ratio * 100).round()}%，'
            '建议您释放内存，或关闭内存占用率高的应用',
        // ⚠「立即加速」是我们自己的说法（表里只有「一键加速」`:439`、「完成加速」`:60`，
        // 那两个已用在真正该用的地方：加速工具条目与加速完成提示）。
        actionLabel: '立即加速',
        actionId: 'expedite',
        // 修剪了几个进程是这件事唯一的证据；原来返回值直接丢掉（也不接异常），
        // 用户点了既不知道释放了多少，失败也一声不吭。
        report: () async {
          final trimmed = await RustApi.instance.processesMemoryOptimization();
          // trimmed = 0 不是失败（本来就没多少可释放的），但也**不**报"释放了 0 个"糊弄
          return trimmed > 0 ? '完成加速：释放 $trimmed 个进程' : '完成加速';
        },
        route: '/app_manage_dashboard/process_info',
      ));
    }
    for (final d in disks) {
      if (d.ratio > 0.9) {
        unawaited(ThresholdPopups.maybeShow(
          key: 'SystemDisk_window',
          title: '系统盘空间不足提示',
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

  int get _score => healthScore(
        cpuUsage: _cpu?.usage,
        memRatio: _mem?.ratio,
        diskRatios: [for (final d in _disks) d.ratio],
      );

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
              // 与清理页头卡同一套容量格式化：`>> 30` 会把不足 1G 的盘写成 0G
              detail: diskCapacityDetail(d),
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

/// 首页那张卡上的数字。
///
/// ⚠ **「设备健康评分」这个说法和它的算法都是我们自己的**，不是照抄参考实现：
/// 它的材料里**完全没有"评分/健康"这个概念**——`zh_strings.txt` 搜「评分」零命中、
/// 「健康」只出现在法律条款里，`classes.txt`/`click_events.txt`/`frb_calls.txt`
/// 搜 score/health/rating 也全为空。它首页那条线索是「上次体检时间」`:282`
/// 与「全面体检」（体检面板标题，我们已经在用）。所以这个数字是**我们加的一个概览指标**，
/// 不是它的功能复刻。留着的代价要如实写在这里：它把三个占用率折算成一个
/// 没有出处的分数，而界面上它长得像一句实测结论。
///
/// 权重（CPU/4、内存×20、最紧的一张盘×10）同样是我们的取值，
/// 刻意让"读不到"的那几项**不参与扣分**：把没读到当成 0 占用，等于
/// 凭空缺给 100 分里的一大块——那正是本项目一路在清的那类缺陷。
///
/// ⚠ 磁盘只取**最紧的那一张**，不是逐张累加。原先写的是 `for (d in disks) s -= d.ratio*10`，
/// 于是一台插了 4 张盘的机器光磁盘就能扣 40 分，而**配置完全相同的单盘机只扣 10 分**——
/// 分数取决于系统报了几张卷，而不是机器状态。那种差异不是"健康"，是计数副作用。
int healthScore({
  double? cpuUsage,
  double? memRatio,
  List<double> diskRatios = const [],
}) {
  var s = 100.0;
  if (cpuUsage != null) s -= cpuUsage / 4.0;
  if (memRatio != null) s -= memRatio * 20.0;
  var worst = 0.0;
  for (final r in diskRatios) {
    if (r > worst) worst = r;
  }
  s -= worst * 10.0;
  return s.round().clamp(5, 100);
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
            // ⚠「设备健康评分」这句话是我们自己的说法，参考实现的文案表里搜不到；
            // 整个"评分"概念它都没有（详见 [healthScore] 上方那段）。
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
          // ⚠「立即体检」是我们自己的说法，表里搜不到这个词。它只沿用了参考实现
          // 「立即X」的构词（「立即安装」`:189`、「立即更新」`:489`）；按钮的动作是真接通的
          // （就地跑一轮体检，见 _examine），不是画个假按钮。
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
