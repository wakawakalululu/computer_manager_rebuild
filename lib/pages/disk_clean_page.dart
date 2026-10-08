import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../services/running_tasks.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 四张清理入口卡（以及对应扫描页副标题）的描述，逐字取参考实现文案表：
/// 「深度清理可帮您优化电脑空间」`:312`、「清理电脑中的大文件」`:502`、
/// 「清理电脑中的重复文件」`:155`、「清理系统盘可帮您优化电脑空间」`:97`。
/// 判据：`:312`/`:97` 同句式（「…可帮您优化电脑空间」），`:502`/`:155` 同句式
/// （「清理电脑中的…」）——成对同句式只会出现在同一处的一组卡片上。
const String kDeepCleanDesc = '深度清理可帮您优化电脑空间';
const String kLargeFileDesc = '清理电脑中的大文件';
const String kDupFileDesc = '清理电脑中的重复文件';
const String kSystemDiskDesc = '清理系统盘可帮您优化电脑空间';

/// 勾选条目合计能释放多少。**只**给实测合计：`:569`「清理所选项可释放」这句
/// 自带文案只到动词为止，数值是我们勾选项的 size 合计，不勾任何项时整行不出现。
String reclaimableText(int totalMb) => totalMb >= 1024
    ? '${(totalMb / 1024).toStringAsFixed(1)} GB'
    : '$totalMb MB';

/// 勾选项的合计（MB）。`CleanItem.size` 本来就是 MB 为单位。
int selectedTotalMb(List<CleanItem> items) =>
    items.where((e) => e.checked).fold<int>(0, (s, e) => s + e.size);

/// 一个条目实际对应的文件路径（`paths` 为空即单文件行）。
List<String> pathsOf(CleanItem i) => i.paths.isEmpty ? [i.path] : i.paths;

/// 按"此刻还在不在"筛掉失效条目：返回 (保留的条目, 已失效的文件个数)。
///
/// 扫描结果会过期——扫完到点删除之间，文件可能被别的程序移走/删掉。那时按
/// 扫描时的条数报"将删除 N 个"是拿旧账说新话。`alive` 与 [pathsOf] 展开后的
/// 路径**同序**；传 null 或长度对不上就整批原样返回（探不到 ≠ 文件没了，
/// 宁可少报也不谎报）。
(List<CleanItem> kept, int stale) dropStaleItems(
  List<CleanItem> items,
  List<bool>? alive,
) {
  final paths = [for (final i in items) ...pathsOf(i)];
  if (alive == null || alive.length != paths.length) return (items, 0);
  final kept = <CleanItem>[];
  var stale = 0;
  var idx = 0;
  for (final i in items) {
    final n = pathsOf(i).length;
    final live = alive.sublist(idx, idx + n).where((b) => b).length;
    stale += n - live;
    if (live > 0) kept.add(i);
    idx += n;
  }
  return (kept, stale);
}

/// 勾选项真正会被删掉的文件个数。一条可能代表一组（重复文件一行是好几个
/// 副本），所以按 `paths` 算；`paths` 为空说明这一条就是单个文件。
int fileCountOf(List<CleanItem> items) =>
    items.fold<int>(0, (s, e) => s + pathsOf(e).length);

/// 清理面板 —— 路由 /disk_clean_dashboard
/// 子页对照规格整理路由：deep_clean_scan / large_file_scan /
/// duplicate_file_scan / system_disk_files
class DiskCleanDashboardPage extends StatelessWidget {
  const DiskCleanDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      const StorageHeaderCard(),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_dashboard_disk_clean.webp',
                title: '深度清理',
                subtitle: kDeepCleanDesc,
                onTap: () =>
                    context.go('/disk_clean_dashboard/deep_clean_scan'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_large_files.webp',
                title: '大文件',
                subtitle: kLargeFileDesc,
                onTap: () =>
                    context.go('/disk_clean_dashboard/large_file_scan'))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: EntryCard(
                icon: 'icon_duplicate_files.webp',
                title: '重复文件',
                subtitle: kDupFileDesc,
                onTap: () =>
                    context.go('/disk_clean_dashboard/duplicate_file_scan'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_system_disk_files.webp',
                title: '系统盘文件',
                subtitle: kSystemDiskDesc,
                onTap: () =>
                    context.go('/disk_clean_dashboard/system_disk_files'))),
      ]),
      const SizedBox(height: 12),
      const RecycleBinCard(),
    ]);
  }
}

/// 「存储空间管理」头卡的汇总文案。
/// 对照参考实现的 `DiskCleanDashboardHeaderCard`（类名表）与自带文案
///（`zh_strings.txt:126`「存储空间管理」、`:517`「已用存储空间」）。
/// 数字全部来自 `getDiskInfoList` 的实测值，不预估也不补零。
String storageSummaryText(List<DiskInfo> disks) {
  if (disks.isEmpty) return '未检测到磁盘';
  final total = disks.fold<int>(0, (a, d) => a + d.total);
  final used = disks.fold<int>(0, (a, d) => a + (d.total - d.free));
  if (total <= 0) return '已用存储空间 0 B / 0 B';
  return '已用存储空间 ${formatCapacity(used)} / ${formatCapacity(total)}'
      '（${(used * 100 / total).round()}%）';
}

/// 清理页顶部的存储空间卡：总用量 + 每个盘一条占用条。
///
/// 类名公开是给单测用的：私有类打不开，"读失败时这张卡该说什么"就只能靠肉眼。
class StorageHeaderCard extends StatefulWidget {
  const StorageHeaderCard({super.key});

  @override
  State<StorageHeaderCard> createState() => _StorageHeaderCardState();
}

class _StorageHeaderCardState extends State<StorageHeaderCard> {
  List<DiskInfo>? _disks;

  /// 「还没读到」与「读失败」原来共用一个 `SizedBox.shrink()`：卡片静默消失，
  /// 界面上看不出这两种区别，也没有任何再试一次的动作。分开之后失败那一支明说读不到
  /// ——但**仍然不画「未检测到磁盘」**，那句话是"查过了、一个盘都没有"的意思。
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 抽成方法是因为失败那一支要能重读。异常必须接住：抛出去是无人接的 Future 错误，
  /// 而界面只是"卡片不见了"，没人知道是读失败还是本来就没盘。
  void _load() {
    RustApi.instance.getDiskInfoList().then((v) {
      if (mounted) setState(() => _disks = v);
    }).onError((Object e, StackTrace _) {
      if (mounted) setState(() => _failed = true);
      unawaited(RustApi.instance.logError('读取磁盘列表失败: $e'));
    });
  }

  @override
  Widget build(BuildContext context) {
    final disks = _disks;
    // 还没读到就不占位：先画一张空卡比不画更容易被当成故障
    if (disks == null && !_failed) return const SizedBox.shrink();
    if (disks == null) {
      // 「检查磁盘容量出错」用的是自带的说法（表内那条带叹号的状态句），
      // 重试入口与补丁页/启动项页同一套：「重新加载」(`:225`)。
      return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Expanded(
                child: Text('检查磁盘容量出错',
                    style: TextStyle(fontWeight: FontWeight.w700))),
            TextButton(onPressed: _load, child: const Text('重新加载')),
          ]));
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('存储空间管理', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(storageSummaryText(disks),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
        const SizedBox(height: 10),
        for (final d in disks)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: UsageBar(
              label: '${d.letter} 盘',
              ratio: d.ratio,
              detail: diskCapacityDetail(d),
            ),
          ),
      ]),
    );
  }
}

class RecycleBinCard extends StatefulWidget {
  const RecycleBinCard({
    super.key,
    this.loadSize,
    this.openFolder,
    this.emptyBin,
  });

  /// 默认走真实 Rust 调用；单测从构造参数注入假实现（改字段来不及——initState
  /// 在 pumpWidget 里就跑完了，那时桩还没装上，会先打一次真调用）。
  final Future<String> Function()? loadSize;
  final Future<void> Function()? openFolder;
  final Future<void> Function()? emptyBin;

  @override
  State<RecycleBinCard> createState() => RecycleBinCardState();
}

/// 回收站的大小与两个动作都做成可注入的。
///
/// 原来在 build/onPressed 里直接调 `RustApi.instance`（具体单例，要真
/// `rust_lib.dll` 才跑得起来），于是"有没有查看入口""清空后会不会刷新"在单测里
/// 一点都点不动，只能靠实机肉眼比对——那正是它一开始写漏的原因。
class RecycleBinCardState extends State<RecycleBinCard> {
  String _human = '';

  @visibleForTesting
  Future<String> Function() get loadSize =>
      widget.loadSize ?? () => RustApi.instance.getRecycleBinSize();
  @visibleForTesting
  Future<void> Function() get openFolder =>
      widget.openFolder ?? () => RustApi.instance.openRecycleBinFolder();
  @visibleForTesting
  Future<void> Function() get emptyBin =>
      widget.emptyBin ?? () => RustApi.instance.emptyRecycleBin();

  @override
  void initState() {
    super.initState();
    load();
  }

  /// 公开是为了清空之后能重跑一次（容量得跟着变）。
  @visibleForTesting
  Future<void> load() async {
    try {
      final size = await loadSize();
      if (mounted) setState(() => _human = size);
    } catch (e) {
      // 读不到就保持空串 → 卡片只显示「回收站」而不带容量。
      // 这与"容量 0"是**两件事**：后者是实测值，空串是"没读到"。
      // 原来两者都摆成空，于是读失败看起来像"回收站是空的"。
      //
      // 记日志不会再抛——`RustApi.logError` 内部兜住了（桥未初始化时 `RustLib.api`
      // 是**同步抛**的，`.catchError` 接不住同步异常，会把「读容量失败」升级成
      // 「卡片构建失败」）。收在适配层之后，调用点就不必各套 try/catch。
      unawaited(RustApi.instance.logError('读取回收站容量失败: $e'));
    }
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
            // 尾巴上原来那句「，可一键清空」是编的；「回收站」(:545) 与
            // 「一键清理」(:65) 才是自带的，按钮位用后者。
            // `_human` 为空 = **没读到**（不是 0），所以不写容量，
            // 免得"读失败"看起来像"回收站是空的"。
            child: Text(_human.isEmpty ? '回收站' : '回收站  $_human',
                style: const TextStyle(fontSize: 14))),
        // 容量摆在这里却看不见里面是什么，用户没法判断那 3 GB 是不是还要留的东西。
        // 「查看」(:451) 是自带文案，空回收站也照样能点开看"现在到底有什么"。
        TextButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await openFolder();
            } catch (e) {
              messenger.showSnackBar(SnackBar(
                  duration: const Duration(seconds: 5),
                  content: Text('打开回收站失败：${bridgeErrorText(e)}')));
            }
          },
          child: const Text('查看'),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: () async {
            // crateApiDiskScanDeepCleanREmptyRecycleBin → …::deep_clean::empty_recycle_bin
            final messenger = ScaffoldMessenger.of(context);
            final ok = await confirmDestructive(context,
                title: '确定要清空回收站吗？', body: '清理后会导致回收站文件无法恢复。');
            if (!ok || !mounted) return;
            try {
              await emptyBin();
              await load();
            } catch (e) {
              messenger.showSnackBar(
                  SnackBar(content: Text('清空回收站失败：${bridgeErrorText(e)}')));
            }
          },
          child: const Text('一键清理'),
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
    required this.scan,
    required this.cancelKey,
    required this.actionLabel,
    this.lottie = 'deep_scan_loading.json',
    this.readOnly = false,
    this.summaryPrefix,
    this.itemUnit = '项',
    this.onClean,

    /// 清理完成时的那句话。**按页各写各的**（跟 [actionLabel] 一个道理）：
    /// 参考实现自带「深度清理完成」`:487`、「系统盘清理已完成！」`:222`，
    /// 四页共用一句是我们自造的。而且不给的话，删完列表清空 → 界面显示
    /// 「暂无可清理项」，跟"扫出来什么都没有"长得一模一样——用户分不清
    /// 刚才是**清完了**还是**本来就没有**。
    this.doneLabel,
  });

  final String title;
  final String subtitle;
  final String cancelKey;

  /// 结果页的动作按钮文案。**没有默认值**：参考实现每页各叫各的
  /// （「删除大文件」`:68`、「删除重复文件」`:446`），原来我们四页共用一个
  /// 自造的「立即清理」——那个词不在文案表里。
  final String actionLabel;
  /// 扫描的执行入口。**给函数而不是给一条 Stream**：`async*` 出来的 Stream 是
  /// 单订阅的，交出去一次就没了；而失败态上的「重新加载」(`:225`) 必须能再起
  /// 一轮，所以这里要的是"怎么再来一次"，不是"这一条流"。
  final Stream<List<CleanItem>> Function() scan;

  /// 结果汇总行的前缀，取参考实现自带的说法（「存在重复文件共」`:511`、
  /// 「超出 50MB 文件共」`:559`）；不给就不画这一行。大文件那句由
  /// [kLargeFileSummaryPrefix] 给出，与扫描门槛同源（见 `rust_api.dart`）。
  final String? summaryPrefix;

  /// 汇总行里的量词（组 / 个 / 项）
  final String itemUnit;

  /// 扫描中的动图，参考实现四个扫描页各有一支（见 assets/lottie/）。
  final String lottie;

  /// 只读结果页：不画勾选框、也不给「立即清理」。系统盘文件是 C 盘空间构成
  /// 分析，列出来的是 C:\Windows、C:\Program Files 这类目录，给一个「全选 +
  /// 立即清理」等于摆了一个删系统的按钮。
  final bool readOnly;

  /// 自定义清理动作（深度清理走 Rust 侧 clean_deep_clean，需按规则删文件并处理
  /// REMOVESELF 目录）；为空时按勾选路径调用 delete_file。
  final Future<void> Function(List<CleanItem> selected)? onClean;

  /// 清完之后摆出来的那句话；null = 不摆（保持空态那句话）。
  final String? doneLabel;

  @override
  State<ScanPageScaffold> createState() => _ScanPageScaffoldState();
}

class _ScanPageScaffoldState extends State<ScanPageScaffold> {
  /// 当前这一轮扫描的订阅。重新扫描与 dispose 都要先把它断掉（见 _startScan）。
  StreamSubscription<List<CleanItem>>? _sub;
  List<CleanItem>? _result;
  String? _error;

  /// 扫描是否还没出结果。dispose 时按它决定要不要替用户取消掉。
  bool _scanning = true;

  /// 删除进行中：按钮换成自带的「正在删除」(`:235`) 并禁用，避免重复点；
  /// 同时登记成"进行中任务"，让关窗时那句「关闭窗口将会取消正在进行中的任务」
  /// 对删除这件事也成立。
  bool _deleting = false;

  /// 刚清完（而不是本来就没扫出东西）。空列表有两种完全不同的来由，
  /// 摆同一句话等于让用户分不清"我清掉了"和"本来就没有"。
  bool _justCleaned = false;

  /// 点路径 → 在资源管理器里打开所在目录并选中该文件。
  ///
  /// 只打开、选中，不删不改。聚合行（重复文件一行代表多份）取第一份：paths 里的
  /// 第一个就是用户要核对的那一个。失败按 `perItemFailure` 点名报，不静默。
  Future<void> _openWhere(CleanItem item) async {
    final path = item.paths.isEmpty ? item.path : item.paths.first;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RustApi.instance.openFileDir(path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(perItemFailure('打开所在位置', path, e))));
    }
  }

  /// 逐条删除扫描结果里的一个条目。
  ///
  /// 确认框用自带文案「准备删除全部」`:483` 与「个文件将被删除。」`:556`——
  /// **报的是文件数不是行数**：一行常常代表一组文件（一条清理规则 / 一组重复文件），
  /// 拿行数冒充文件数会少报，而这是"要删我的东西"的确认，少报最糟。
  Future<void> _deleteOne(CleanItem item) async {
    final targets = pathsOf(item);
    if (targets.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmDestructive(context,
        title: '准备删除全部', body: '${targets.length} 个文件将被删除。');
    if (!ok || !mounted) return;
    // 一条一条删：单条失败不影响其余，最后如实报"哪几条没删掉"，
    // 失败那行点名（列表里几十行，只说"删除失败"用户不知道该手动处理哪一条）
    final failed = <String>[];
    for (final p in targets) {
      try {
        await RustApi.instance.deleteSingleFile(p);
      } catch (e) {
        failed.add('$p（${bridgeErrorText(e)}）');
      }
    }
    if (!mounted) return;
    setState(() {
      _result?.remove(item);
      // 删掉了最后一行也是"清完了"，空列表同样该说完成而不是"暂无可清理项"
      _justCleaned = true;
    });
    messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(failed.isEmpty
            ? '文件已被删除'
            : '部分文件删除失败，请尝试手动删除：${failed.join('；')}')));
  }

  @override
  void initState() {
    super.initState();
    // 首轮不包 setState：还没有第一帧可以标记重建，字段直接生效就行。
    _startScan();
  }

  /// 起一轮扫描 —— 进页面时的第一轮，和失败后点「重新加载」的那一轮，走同一段代码。
  ///
  /// 调用方负责重建（`setState(_startScan)`）。
  ///
  /// 开头必须先取消上一轮的订阅：回调里的 `RunningTasks.end(cancelKey)` 没有
  /// mounted 保护，而两轮用的是**同一个键**。留着上一条订阅，它晚到的
  /// onData/onError 会把**正在跑的这一轮**从登记表里抹掉，于是关窗时那句
  /// 「关闭窗口将会取消正在进行中的任务」(`:89`) 对这次扫描就不成立了。
  /// RunningTasks 内部是 Set，重复 begin/end 本身无害，要挡的就是"迟到的 end
  /// 销掉新一轮"这一种。
  void _startScan() {
    unawaited(_sub?.cancel());
    _sub = null;
    _error = null;
    _result = null;
    _justCleaned = false;
    _scanning = true;
    RunningTasks.instance.begin(widget.cancelKey);
    _sub = widget.scan().listen(
      (items) {
        RunningTasks.instance.end(widget.cancelKey);
        _scanning = false;
        if (!mounted) return;
        setState(() {
          _result = items;
          _error = null;
        });
      },
      onError: (Object e) {
        RunningTasks.instance.end(widget.cancelKey);
        _scanning = false;
        if (mounted) setState(() => _error = '$e');
      },
    );
  }

  @override
  void dispose() {
    // 订阅必须断掉：离开页面之后它还会回调，而回调会按同一个键销记
    // RunningTasks——用户此刻可能已经在另一张扫描页上重开了这一轮。
    unawaited(_sub?.cancel());
    // 结果还没出来就离开页面：把扫描取消掉。Rust 侧不会因为没人看就自己停，
    // 而 :89 那句「关闭窗口将会取消正在进行中的任务」也要求这个动作是真的。
    if (_scanning) {
      RunningTasks.instance.end(widget.cancelKey);
      unawaited(_cancelQuietly());
    }
    super.dispose();
  }

  /// 取消失败不往上抛：dispose 里抛异常会把整棵树的卸载带崩。
  ///
  /// 但**不能什么都不留**：取消失败意味着这次扫描还在跑、而已经没有界面看着它了
  /// （用户已经离开这一页）。原来 `catch (_) {}` 完全静默，出了这种状态无从追查。
  /// 记一条日志（`logError` 本身保证不抛，不会反过来把 dispose 带崩）。
  Future<void> _cancelQuietly() async {
    try {
      await RustApi.instance.cancel(widget.cancelKey);
    } catch (e) {
      unawaited(RustApi.instance
          .logError('取消扫描失败（${widget.cancelKey}），该次扫描可能仍在后台运行: $e'));
    }
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
            // 失败态原来是个死胡同：只有这一句话，用户唯一的出路是退回上一页再进一次。
            // 重试入口与补丁页/启动项页/存储卡同一套，标签用自带的「重新加载」(`:225`)。
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EmptyView(text: '扫描未完成：${_error!}'),
                    TextButton(
                        onPressed: () => setState(_startScan),
                        child: const Text('重新加载')),
                  ],
                ),
              )
            : result == null
                ? Center(
                    child: ScanningBanner(
                        text: '正在检测…',
                        lottie: widget.lottie,
                        onCancel: () {
                          RunningTasks.instance.end(widget.cancelKey);
                          _scanning = false;
                          unawaited(_cancelQuietly());
                        }))
                : result.isEmpty
                    // 清完了 ≠ 本来就没有：空列表有两种来由，摆同一句等于分不清
                    ? EmptyView(
                        text: _justCleaned && widget.doneLabel != null
                            ? widget.doneLabel!
                            : '暂无可清理项')
                    : Column(children: [
                        if (widget.summaryPrefix != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Text(
                                      '${widget.summaryPrefix} ${result.length} '
                                      '${widget.itemUnit}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textSub),
                                    ),
                                  ),
                                  if (!widget.readOnly)
                                    TextButton(
                                      // 参考实现有「全选」(`:209`)；反选那半句它没留，
                                      // 用「取消全选」是我们自己的措辞。
                                      onPressed: () => setState(() {
                                        final toAll =
                                            !result.every((e) => e.checked);
                                        for (final e in result) {
                                          e.checked = toAll;
                                        }
                                      }),
                                      child: Text(result.every((e) => e.checked)
                                          ? '取消全选'
                                          : '全选'),
                                    ),
                                ]),
                                if (!widget.readOnly &&
                                    selectedTotalMb(result) > 0)
                                  Text(
                                    '清理所选项可释放 '
                                    '${reclaimableText(selectedTotalMb(result))}',
                                    style: const TextStyle(
                                        fontSize: 13, color: AppTheme.textSub),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: result.length,
                            itemBuilder: (_, i) {
                              final it = result[i];
                              // 有归类名就带上（深度清理按 LangSecRef 归类：
                              // 垃圾清理 / 系统无用文件 / 应用缓存 / 网络缓存），
                              // 其余扫描页 category 为空串，界面与改前一致
                              final meta = it.category.isEmpty
                                  ? '${it.size} MB'
                                  : '${it.category} · ${it.size} MB';
                              final subtitle = Text(meta,
                                  style:
                                      const TextStyle(color: AppTheme.textSub));
                              // 路径点得开：扫出来的一大堆文件，用户唯一能自己
                              // 验证的办法就是去资源管理器里看一眼。点了只开目录、
                              // 不改任何东西——`crateApiDiskScanDiskToolsROpenFileDir`。
                              final openWhere = InkWell(
                                  onTap: () => _openWhere(it),
                                  child: Text(it.path,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          decoration: TextDecoration.underline,
                                          decorationColor: AppTheme.textSub)));
                              if (widget.readOnly) {
                                // 只读的扫描页（系统盘）没有底部按钮，一行一个都动不了。
                                // 逐条删除（`crateApiDiskScanDiskToolsRDeleteSingleFile`）
                                // 正好补在这里：「删除文件」`:593` 是自带文案。
                                // 每一行可能代表**多个文件**（聚合条目），所以删的是这行的
                                // 全部路径，条数照实报，不能拿行数冒充文件数。
                                return ListTile(
                                  title: openWhere,
                                  subtitle: subtitle,
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '删除文件',
                                    onPressed: () => _deleteOne(it),
                                  ),
                                );
                              }
                              return CheckboxListTile(
                                value: it.checked,
                                onChanged: (v) =>
                                    setState(() => it.checked = v ?? false),
                                title: openWhere,
                                subtitle: subtitle,
                              );
                            },
                          ),
                        ),
                      ]),
      ),
      if (result != null &&
          result.isNotEmpty &&
          _error == null &&
          !widget.readOnly)
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _deleting
                ? null
                : () async {
                    final picked = result.where((e) => e.checked).toList();
                    final onClean = widget.onClean;
                    final messenger = ScaffoldMessenger.of(context);
                    // 扫描结果会过期：扫完到点删除之间，文件可能被别的程序移走。
                    // 那时按扫描时的条数说"将删除 N 个"就是拿旧账说新话——先探一遍
                    // 还在的（crateApiDiskScanDiskToolsRCheckFilesExists），把失效的
                    // 剔掉，并如实告诉用户少了多少（参照实现也留了「文件不存在」:58）。
                    List<bool>? alive;
                    final allPaths = [for (final i in picked) ...pathsOf(i)];
                    if (allPaths.isNotEmpty) {
                      try {
                        alive =
                            await RustApi.instance.checkFilesExist(allPaths);
                      } catch (_) {
                        // 探不到就按原样走删除：探不到不等于文件已经没了
                        alive = null;
                      }
                    }
                    final (selected, stale) = dropStaleItems(picked, alive);
                    if (selected.isEmpty) {
                      messenger.showSnackBar(
                          const SnackBar(content: Text('所选文件已不存在，没有可删除的内容')));
                      return;
                    }
                    // delete_file 是 fs::remove_file，不进回收站；清理前必须过一次确认。
                    // 计数说「个文件」而不是「项」：参考实现这句是「个文件将被删除」
                    // (:556)，而重复文件一行代表好几份，按"项"数会少报要删的文件数。
                    final ok = await confirmDestructive(context,
                        title: widget.actionLabel,
                        body: '${fileCountOf(selected)} 个文件将被删除。'
                            '${stale > 0 ? '（另有 $stale 个已不存在）' : ''}'
                            '所选项删除后不可恢复，请慎重清理');
                    if (!ok || !mounted) return;
                    setState(() => _deleting = true);
                    RunningTasks.instance.begin('delete:${widget.cancelKey}');
                    try {
                      if (onClean != null) {
                        await onClean(selected);
                      } else {
                        // crateApiDiskScanDiskToolsRDeleteFile → api::disk_scan::disk_tools::delete_file
                        await RustApi.instance.deleteFile(selected);
                      }
                      if (mounted) {
                        setState(() {
                          _result = [];
                          _justCleaned = true;
                        });
                      }
                    } catch (e) {
                      // 失败原来只是 await 抛出去没人接，页面停在结果列表上像是清理成功了。
                      messenger.showSnackBar(SnackBar(
                          content:
                              Text('以下文件删除失败，请尝试手动删除：${bridgeErrorText(e)}')));
                    } finally {
                      RunningTasks.instance.end('delete:${widget.cancelKey}');
                      if (mounted) setState(() => _deleting = false);
                    }
                  },
            style: FilledButton.styleFrom(minimumSize: const Size(220, 44)),
            child: Text(_deleting ? '正在删除' : widget.actionLabel),
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
      subtitle: kDeepCleanDesc,
      scan: RustApi.instance.scanDeepClean,
      cancelKey: 'deep_clean',
      actionLabel: '深度清理',
      // 自带的「深度清理完成」`:487`
      doneLabel: '深度清理完成',
      onClean: (_) => RustApi.instance.cleanDeepClean());
}

class LargeFileScanPage extends StatelessWidget {
  const LargeFileScanPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      // 页名用自带的「大文件」(:175)；原来写的「大文件扫描」不在文案表里。
      title: '大文件',
      subtitle: kLargeFileDesc,
      scan: RustApi.instance.largeFileScan,
      cancelKey: 'large_file',
      actionLabel: '删除大文件',
      summaryPrefix: kLargeFileSummaryPrefix,
      itemUnit: '个',
      lottie: 'large_files_loading.json');
}

class DuplicateFileScanPage extends StatelessWidget {
  const DuplicateFileScanPage({super.key});
  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '重复文件',
      subtitle: kDupFileDesc,
      scan: RustApi.instance.duplicateFileScan,
      cancelKey: 'dup_file',
      actionLabel: '删除重复文件',
      summaryPrefix: '存在重复文件共',
      itemUnit: '组',
      // 重复文件**没有**自带的"清理完成"句，只有「重复文件rust扫描完成！」`:533`
      // 和「重复文件进度条动画完成！」`:141`——都是扫描/动画态。删完这一页保持
      // 原空态那句，不拿别的页的完成句硬套（那等于编一句它没说的话）。
      lottie: 'duplicate_files_loading.json');
}

/// 系统盘那行的说明：把**实测的**文件系统带上。
///
/// 「清理系统盘可帮您优化电脑空间」(:97) 只说收益，不说盘长什么样；而这页列的
/// 是用户自己的系统文件，文件系统（NTFS/ReFS/FAT32…）是判断"能不能动、怎么
/// 备份"的第一手信息。读不到就退回原来那句——**不编一个文件系统名出来**。
String systemDiskSubtitle(RootDiskInfo? root) {
  final base = kSystemDiskDesc;
  if (root == null || root.fileSystem.trim().isEmpty) return base;
  final fs = root.fileSystem.trim();
  return root.removable ? '$base（当前系统盘 $fs，可移动介质）' : '$base（当前系统盘 $fs）';
}

class SystemDiskFilesPage extends StatefulWidget {
  const SystemDiskFilesPage({super.key});
  @override
  State<SystemDiskFilesPage> createState() => _SystemDiskFilesPageState();
}

class _SystemDiskFilesPageState extends State<SystemDiskFilesPage> {
  RootDiskInfo? _root;

  @override
  void initState() {
    super.initState();
    // 读不到系统盘信息就留着 null：副标题退回原来那句，不编文件系统名
    RustApi.instance.getRootDiskInfo().then((v) {
      if (mounted) setState(() => _root = v);
    }).onError((_, __) => null);
  }

  @override
  Widget build(BuildContext context) => ScanPageScaffold(
      title: '系统盘文件',
      subtitle: systemDiskSubtitle(_root),
      scan: RustApi.instance.systemDiskScan,
      cancelKey: 'system_disk',
      actionLabel: '系统盘文件',
      readOnly: true,
      // 这一页是逐条删（上一轮补的行内入口），删到空就该说完成而不是"暂无可清理项"。
      // 用自带的「系统盘清理已完成！」`:222`。
      doneLabel: '系统盘清理已完成！',
      lottie: 'system_disk_files_loading.json');
}
