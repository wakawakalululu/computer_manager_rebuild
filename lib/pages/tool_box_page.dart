import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 工具箱 —— 路由 /tool_box_dashboard
/// 四张卡**都有去处**：net_speed_test / patch_test / security_disk /
/// 外设检测（指到体检页，那一页里就有真的外设检查行）。
/// 原来「外设检测」这张卡 `onTap` 是 null：卡上写着"检测"，点了什么都不发生，
/// 是典型的假 affordance；而标题「设备检测」还不是参考实现自己的词。
class ToolBoxDashboardPage extends StatelessWidget {
  const ToolBoxDashboardPage({super.key, this.probe, this.launch});

  /// 「应用中心」两条动作的注入缝（不给时走真桥）。
  ///
  /// 为什么要缝：这张卡有**三种**要说的话——已装并起了、未装、探测失败——
  /// 真机上要凑齐得换三台机器，没有缝就只能测"有这张卡"，测不到
  /// **"未装时它不去拉起、也不开任何网页"**这条真正的判据。
  final Future<bool?> Function()? probe;
  final Future<bool> Function()? launch;

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
                // 「外设检测」`:478` 是参考实现自带的那一项的名字（同类还有
                // 「打印机配置」`:310`、「启动环境」`:164`）。原来这里写「设备检测」——
                // 文案表里**搜不到这个词**，是我们自己拼的。
                // ⚠ 副标题「查看有没有带故障码的设备」**同样是我们自己的说法**，
                // 表里没有这句——它只是把我们真做的那条检查用大白话说出来。
                // 别把它当成照抄来的句子（这条由 parity_audit.py 的"自造面"一起看着）。
                // 跳转指体检页：那一页里就有真做的外设检查（WMI
                // `ConfigManagerErrorCode` 非 0 的设备数），所以这张卡点下去有东西看，
                // 不再是"标题写着检测、点了什么都不发生"。
                title: '外设检测',
                subtitle: '查看有没有带故障码的设备',
                onTap: () => context.go('/dashboard/examination'))),
        const SizedBox(width: 12),
        Expanded(
            child: EntryCard(
                icon: 'icon_security_disk.webp',
                // 「智慧盘」`:140` 是参考实现自带的标题（配 `_SecurityDiskPageState`
                // 与说明 `:456`）。原来这里写「安全盘」——同一个东西两个名字，
                // 而「智慧盘」是它自己的说法，图标名 security_disk 是内部命名。
                title: '智慧盘',
                subtitle: '在运行内存不足时提升运行速度，清理后会在剩余空间最大的盘符再次生成',
                onTap: () => context.go('/tool_box_dashboard/security_disk'))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        // 「应用中心」：标题 :596、说明 :486 都是参考实现自带的说法，
        // 而 `openPcasClient` 此前是**唯一一个没有任何界面入口的适配层方法**
        // （接线面的那条真缺口，任务单 #98）。
        // ⚠ 这张卡**不打开任何网址**：原来 Rust 侧在客户端没装时会去开一个
        //   我们自己填的占位官网（TODO(占位)），那条分支已删除——
        //   未安装就如实说未安装，不替用户开浏览器。
        // 图标名与别处同一口径（素材由 scripts/fetch_assets.ps1 恢复，不入库）。
        Expanded(
            child: EntryCard(
                icon: 'icon_app_center.webp',
                title: '应用中心',
                subtitle: '海量正版软件，集中安装管理',
                onTap: () => unawaited(_openAppCenter(context)))),
        // 这一行只有一张卡：参考实现工具箱的排布没有证据（主窗在 auth 门后），
        // 所以不猜第二张卡的内容，只留一个同宽的占位，保证卡片宽度与上面两行一致。
        const SizedBox(width: 12),
        const Expanded(child: SizedBox.shrink()),
      ]),
    ]);
  }

  /// 点「应用中心」：先探一下客户端在不在，再决定说什么。
  ///
  /// 三种结果分开报，**不把"探测失败"并进"未安装"**；
  /// 拉起本身仍由 Rust 侧决定（它只认默认安装位置）。
  Future<void> _openAppCenter(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final installed = await (probe ?? RustApi.instance.pcasClientInstalled)();
    if (installed == null) {
      // 探测本身失败：说"无法确认"，**不许**并进"未安装"
      messenger.showSnackBar(const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('无法确认认证客户端是否安装')));
      return;
    }
    if (!installed) {
      // 未安装就到此为止：不拉起、不开网页（原来这里会去开一个占位网址）
      messenger.showSnackBar(const SnackBar(
          duration: Duration(seconds: 5), content: Text('未安装认证客户端')));
      return;
    }
    try {
      final started =
          await (launch ?? _launchPcasViaBridge)();
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(started ? '已启动认证客户端' : '认证客户端未能启动')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('启动认证客户端失败：${bridgeErrorText(e)}')));
    }
  }
}

/// 不给注入缝时走的真桥路径：只把"有没有真的起来"这一件事带回去。
Future<bool> _launchPcasViaBridge() async =>
    (await RustApi.instance.openPcasClient()).clientStarted;

/// 时延/抖动的显示口径。
///
/// 云电脑里到本机网关的链路常是亚毫秒，取整后会显示成「0 ms」，读起来像"零延迟"。
/// 实测确实落在 1ms 以内就说「<1 ms」；一次都没连上时不给 0，给「不可达」。
String latencyText(int ms, {required bool reachable}) {
  if (!reachable) return '不可达';
  return ms == 0 ? '<1 ms' : '$ms ms';
}

class NetSpeedTestPage extends StatefulWidget {
  const NetSpeedTestPage({super.key, this.result, this.measure});

  /// 测试注入用：不给时点「开始测速」才走真桥 `measureNetSpeed()`。
  /// 结果态（含「重新测速」按钮）真机上要等一次真实采样才看得到，注入后可直接钉住。
  final NetSpeedResult? result;

  /// 失败态的注入缝。只有 [result] 不够：它能摆出"测成功了"的样子，
  /// 摆不出"测失败了"那一条路，而**失败态给不给重试入口**正是行为本身
  /// （这一支原来一个按钮都没有，只能退回上一页）。给定时用它代替真桥，
  /// 不给时 `_start` 仍走 `measureNetSpeed()`。
  final Future<NetSpeedResult> Function()? measure;

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
      final injected = widget.measure;
      final r = await (injected != null
          ? injected()
          : RustApi.instance.measureNetSpeed());
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = bridgeErrorText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result ?? widget.result;
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
                  // 失败态原来只有这一句话、一个按钮都没有：重试入口 `_start` 只在
                  // 空闲那一支上，用户唯一出路是退回上一页再进一次。与扫描页/补丁页/
                  // 启动项页同一族缺陷的第五处。按钮沿用自带的「重新测速」(`:135`)，
                  // 与结果态那个同一个词，不另起一个说法。
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      EmptyView(text: '采样未完成：$_error'),
                      TextButton(
                          onPressed: _start, child: const Text('重新测速')),
                    ])
                  : r == null
                      ? FilledButton(
                          onPressed: _start,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(180, 48)),
                          child: const Text('开始测速'))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          // 参考实现结果区有「当前网速」这个抬头（:208），
                          // 我们原来四个指标光秃秃摆着，没有归属。
                          const Text('当前网速',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textMain)),
                          const SizedBox(height: 12),
                          Wrap(spacing: 24, runSpacing: 14, children: [
                            // 指标名用参考实现自带的「下载速度」「上传速度」，
                            // 不写成我们顺手的「下行 / 上行」。
                            _Metric('下载速度', formatRate(r.downBps)),
                            _Metric('上传速度', formatRate(r.upBps)),
                            _Metric('往返时延',
                                latencyText(r.rttMs, reachable: r.reachable)),
                            _Metric(
                                '抖动',
                                latencyText(r.jitterMs,
                                    reachable: r.reachable)),
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
                          // 重测按钮用自带的「重新测速」(:135)；原来写「再测一次」
                          // 是自造的说法。
                          OutlinedButton(
                              onPressed: _start, child: const Text('重新测速')),
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
  const PatchTestPage({super.key, this.patches, this.loadFailed = false});

  /// 测试注入用：不给时走真桥 `getPatchList()`。
  /// 「没有补丁」这一支真机上测不到（本机必然有已装补丁），只能注入。
  final List<PatchEntry>? patches;

  /// 测试注入用：走"读取失败"那一支。
  /// 与 [patches] 互斥——失败时列表本来就是空的，必须靠这个开关才能把它
  /// 与"读到空"区分开（否则两条路渲染一模一样，测试测不出差别）。
  final bool loadFailed;

  @override
  State<PatchTestPage> createState() => _PatchTestPageState();
}

class _PatchTestPageState extends State<PatchTestPage> {
  List<PatchEntry> _patches = [];

  /// 首轮读取完成前不画空态：还没读到就说「暂无更新」等于把"没加载出来"
  /// 说成"没有更新"（和进程页计数行同一个规矩）。
  bool _loaded = false;

  /// 补丁列表**读失败**（区别于"读到空"）。
  /// 失败时 `_patches` 停在空列表，若照样按"已加载"渲染就会摆出「暂无更新」——
  /// 那是在断言"这台机器没有待更新的补丁"，而真实情况是"没查到"。
  /// 补丁有没有装正是这个页要回答的问题，不能拿读不到当答案。
  bool _loadFailed = false;

  /// Windows 自己记下的重启挂起来源（cbs / wu / rename）
  List<String> _reboot = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 读补丁列表与重启挂起状态。
  ///
  /// 原来这一段只写在 `initState` 里——于是**读失败是个死胡同**：页面摆出
  /// 「补丁列表读取失败」，却没有任何"再试一次"的动作可做。抽成方法之后，
  /// 错误态上的「重新加载」(`zh_strings.txt:225`) 才有东西可调
  /// （同族自带说法还有「暂无内容，请刷新试试」`:181` 与已用上的「重新测速」`:135`）。
  /// 重试不复位 `_loaded/_loadFailed`：成功回调自己会把两面都改对，
  /// 中途把状态清成"还没读"反而会让这一页出现既不是失败也不是空的第三种样子。
  void _load() {
    if (widget.loadFailed) {
      // 单测注入"读失败"：不碰桥，直接落到失败态
      _loaded = true;
      _loadFailed = true;
      return;
    }
    final injected = widget.patches;
    if (injected != null) {
      // 注入时不碰桥：测试环境没有 RustLib，调用会直接抛
      // "flutter_rust_bridge has not been initialized"。
      _patches = injected;
      _loaded = true;
      return;
    }
    // crateApiSysinfoPatchesRGetInstalledPatchIds → api::sysinfo::patches::get_installed_patch_ids
    //
    // 这两个 `.then` 原来都**没有 onError**：补丁读失败就永远停在"加载中"转圈，
    // 而 `rebootPendingReasons` 失败会被当成"没有待重启补丁"——那是**假的安心**
    // （真的挂着补丁等着重启时，恰恰是这条读不出来）。
    RustApi.instance.getPatchList().then((v) {
      if (mounted) {
        setState(() {
          _patches = v;
          _loaded = true;
          _loadFailed = false;
        });
      }
    }).catchError((Object e) {
      // 读失败也要把加载态收掉，否则用户对着一张永远转圈的卡片
      if (mounted) {
        setState(() {
          _loaded = true;
          _loadFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 5),
            content: Text('读取补丁列表失败：${bridgeErrorText(e)}')));
      }
    });
    RustApi.instance.rebootPendingReasons().then((v) {
      if (mounted) setState(() => _reboot = v);
    }).catchError((Object e) {
      // 这里**不动** _reboot：保持"不知道"，而不是把读不到当成"没有待重启"。
      // `rebootNotice([])` 返回 null（不提示），所以读不到就不提示——
      // 宁可少说一句，不可报假安心。
      unawaited(RustApi.instance.logError('读取待重启状态失败: $e'));
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
          // 一条都没有时要有个说法：原来是个空列表，看着像没加载出来。
          // 「暂无更新」(:430) 是自带的空态措辞。
          if (_loaded && _loadFailed)
            // 读不到 ≠ 没有。摆「暂无更新」是在断言"这台机器不需要打补丁"，
            // 而真实情况是"没查到"——补丁有没有装正是这个页面要回答的问题。
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const EmptyView(text: '补丁列表读取失败'),
                const SizedBox(height: 10),
                // 「重新加载」(`:225`) 是自带说法。这一支原来是个**死胡同**：
                // 只说"读失败"，什么都不让用户做——而补丁有没有装正是这页要答的问题。
                TextButton(onPressed: _load, child: const Text('重新加载')),
              ]),
            )
          else if (_loaded && _patches.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: EmptyView(text: '暂无更新')),
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
                    // 与成功那行一致带上补丁号，否则一屏补丁不知道是哪条失败
                    messenger.showSnackBar(SnackBar(
                        duration: const Duration(seconds: 5),
                        content: Text(perItemFailure('卸载补丁', p.id, e))));
                  }
                },
                // 按钮文案也用自带的「卸载补丁」(:172)：原来只写「卸载」，
                // 而同一个对话框的标题就是「卸载补丁」，两处应当同一个说法。
                child: const Text('卸载补丁'),
              ),
            ),
        ]),
      ),
    ]);
  }
}

/// 智慧盘：在一张盘上生成一块**占空间的文件**，给 Windows 腾出物理内存用。
///
/// 证据（全部来自参考实现自带材料）：
///  * 标题「智慧盘」`docs/extracted/zh_strings.txt:140`，页面类 `_SecurityDiskPageState`
///  * 说明「在运行内存不足时提升运行速度，清理后会在剩余空间最大的盘符再次生成」`:456`
///    —— **"清理后会在剩余空间最大的盘符再次生成"** 就是选盘规则：选**剩余空间最大**的那张。
///  * 机制是 `crateApiUtilsRCreateTmepEmptyFileWhitSize`（`docs/extracted/frb_calls.txt:86`），
///    Rust 侧 `create_tmep_empty_file_whit_size` 按字节长度建空文件。
///
/// 原来的工具箱卡片写「安全盘」且没有出口：同一个东西两个名字，点了也没反应。
/// 现在用参考实现自己的说法「智慧盘」，并接上真实出口。
class SecurityDiskPage extends StatefulWidget {
  const SecurityDiskPage({super.key, this.actions});

  /// 测试注入：不走真桥直接驱动"读盘/生成/清理"三条动作。
  /// 给 null 时用 [RustApi.instance]（要真 dll）。
  final SmartDiskActions? actions;

  @override
  State<SecurityDiskPage> createState() => _SecurityDiskPageState();
}

class SmartDiskActions {
  const SmartDiskActions({
    required this.listDisks,
    required this.makeFile,
    required this.removeFile,
    required this.pathExists,
  });

  final Future<List<DiskInfo>> Function() listDisks;

  /// 生成占位文件；返回落成的完整路径
  final Future<String> Function(String path, int sizeBytes) makeFile;

  /// 清理：删掉占位文件
  final Future<void> Function(String path) removeFile;

  /// 这个路径在不在。**进页面要先查一次**：文件可能是上次生成的，
  /// 不查就会把"磁盘上确实有 2G 占位文件"报成「未生成」。
  final Future<bool> Function(String path) pathExists;
}

/// 智慧盘占位文件的落点：`<盘符>:\cm_smart_disk.tmp`。
///
/// 抽成顶层纯函数才能单测——这里有两处写错都**只有测得住**：盘符后面必须带 `:`，
/// 分隔符必须是反斜杠。少冒号得到 `D\cm_...`（不属于任何盘的根）；
/// 用 `/` 或不带分隔符会落到进程当前目录。两种都不是"该盘根上的占位文件"。
String smartDiskPath(String driveLetter) => '$driveLetter:\\cm_smart_disk.tmp';

/// 选一张盘：**剩余空间最大**的那张（`:456`）。
///
/// 判据是"剩余空间"而不是"总容量"或"使用率"——那句话逐字说的是剩余空间最大。
/// 读不到盘列表返回 null（那是"没读到"，不是"没找到可用的盘"）。
DiskInfo? pickSmartDiskDrive(List<DiskInfo> disks) {
  DiskInfo? best;
  for (final d in disks) {
    if (d.free <= 0) continue;
    if (best == null || d.free > best.free) best = d;
  }
  return best;
}

class _SecurityDiskPageState extends State<SecurityDiskPage> {
  late final SmartDiskActions _a = widget.actions ??
      SmartDiskActions(
        listDisks: RustApi.instance.getDiskInfoList,
        makeFile: (path, size) async {
          await RustApi.instance.createTempEmptyFile(path, size);
          return path;
        },
        removeFile: (path) => RustApi.instance.deleteSingleFile(path),
        pathExists: (path) => RustApi.instance.pathExists(path),
      );

  /// 生成多大规模的占位文件（字节）。2G 的量级依据：这个文件的作用是
  /// "在运行内存不足时提升运行速度"（`:456`），要能挤出可观的物理内存才有效；
  /// 同时不能大到把盘写满。**这是我们的取值，参考实现没有给数字**。
  static const int defaultSizeBytes = 2 << 30;

  List<DiskInfo>? _disks;
  String? _drive; // 选中的盘符，如 "C"

  /// 盘上**当前存在**的占位文件路径；null = 不存在。
  /// 进页面先查一次：文件可能是上次生成的，不查就会把"有"报成"没有"。
  String? _existingPath;

  int? _busy; // 0=读盘 1=生成 2=清理
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = 0;
      _error = null;
    });
    try {
      final disks = await _a.listDisks();
      final pick = pickSmartDiskDrive(disks);
      String? existing;
      if (pick != null) {
        // 查不到就按"不存在"处理：这一句只决定按钮开不开，
        // 报错了下面还有「读取磁盘信息失败」那条兜着。
        try {
          if (await _a.pathExists(smartDiskPath(pick.letter))) {
            existing = smartDiskPath(pick.letter);
          }
        } catch (_) {
          existing = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _disks = disks;
        _drive = pick?.letter;
        _existingPath = existing;
        _busy = null;
        // 一张都挑不出来要说清为什么，不能画成"还没有智慧盘"
        _error = pick == null ? '未找到可用磁盘' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _disks = null;
        _busy = null;
        _error = '读取磁盘信息失败：${bridgeErrorText(e)}';
      });
    }
  }

  Future<void> _create() async {
    final drive = _drive;
    if (drive == null) return;
    setState(() {
      _busy = 1;
      _error = null;
    });
    try {
      final path = await _a.makeFile(smartDiskPath(drive), defaultSizeBytes);
      if (!mounted) return;
      setState(() {
        _existingPath = path;
        _busy = null;
      });
      // 生成成功必须说一句话：这个动作在磁盘上**真的写了 2G**，
      // 而界面上除了那行状态没有别的变化。
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 3),
          content:
              Text('已在 $drive 盘生成 ${formatCapacity(defaultSizeBytes)} 智慧盘')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '生成失败：${bridgeErrorText(e)}';
      });
    }
  }

  Future<void> _clean() async {
    final path = _existingPath;
    if (path == null) return;
    setState(() {
      _busy = 2;
      _error = null;
    });
    try {
      await _a.removeFile(path);
      if (!mounted) return;
      setState(() {
        _existingPath = null;
        _busy = null;
      });
      // 清理成功用参考实现自带的「已清理」`:457`。
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(duration: Duration(seconds: 3), content: Text('已清理')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '清理失败：${bridgeErrorText(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 没读到盘列表（null）时**不画**卡片：一片空白会被读成"这台机器没有智慧盘功能"，
    // 而真实情况是"没读到"。
    final disks = _disks;
    final err = _error;
    final existing = _existingPath;
    final picked = disks == null || _drive == null
        ? null
        : disks.firstWhere((d) => d.letter == _drive,
            orElse: () => disks.first);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Material(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('智慧盘', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            // 说明逐字取自参考实现自带文案 `:456`，不自己另造一句。
            // ⚠ 但**按钮上的「生成」「清理」是我们自己的说法**：文案表里
            // 「生成」只出现在 `:456` 那句话中间、「清理」只在别的具体动作里
            // （「一键清理」`:65`、「自动清理临时文件」`:87`），没有单独作为
            // 按钮标签出现过；能作准的只有完成态那句「已清理」`:457`。
            // 动作总得有个名字，这里用最短的两个动词，并在注释里标清出处。
            Text('在运行内存不足时提升运行速度，清理后会在剩余空间最大的盘符再次生成',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            const SizedBox(height: 12),
            if (_busy == 0)
              const Text('正在读取磁盘信息…')
            else if (err != null)
              // 这一支原来只有一行红字：错误把下面整块（含按钮）都顶掉了，而
              // `_load()` 只有 initState 调过 —— 读盘失败之后界面上没有任何东西
              // 能再读一次。「读失败死胡同」这一族的第六处，标签沿用自带的
              // 「重新加载」(`:225`)，动作就是再跑一遍 `_load`（它自己会清 `_error`）。
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(err,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.danger)),
                TextButton(onPressed: _load, child: const Text('重新加载')),
              ])
            else if (disks == null)
              const Text('未取得磁盘信息')
            else ...[
              Text(
                  picked == null
                      ? '目标磁盘：无'
                      : '目标磁盘：${picked.letter} 盘'
                          '（剩余 ${formatCapacity(picked.free)}）',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              // 磁盘上到底有没有这个文件，是进页面**查过**的结论，不是本次点没点。
              // 上次生成的文件留在盘上，这里就得说「已生成」并把「清理」开出来。
              Text(
                  existing == null
                      ? '状态：未生成'
                      : '状态：已生成 ${formatCapacity(defaultSizeBytes)}'
                          '（$existing）',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: FilledButton(
                    // 已经存在就不给第二次「生成」：再写一遍只是覆盖，
                    // 而按钮看起来像是还有事可做。
                    onPressed:
                        (_busy != null || existing != null) ? null : _create,
                    child: Text(_busy == 1 ? '正在生成…' : '生成'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    // 盘上没有文件就不给「清理」：那是个点了没反应的按钮。
                    onPressed:
                        (existing == null || _busy != null) ? null : _clean,
                    child: Text(_busy == 2 ? '正在清理…' : '清理'),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
    ]);
  }
}
