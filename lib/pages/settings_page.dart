import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/theme.dart';
import '../services/agent_process.dart';
import '../services/feedback_service.dart';
import '../services/floating_window_host.dart';
import '../services/reminders.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 设置区 —— 路由 /app_setting_route
/// 子页：app_about（关于）/ feedback（问题反馈）
class AppSettingPage extends StatefulWidget {
  const AppSettingPage({super.key, this.residentStatus});

  /// 测试注入用：不给时向 `ResidentAgentGuard` 问常驻状态。
  /// 不注入的话测试环境没有 RustLib，一进页面就抛
  /// "flutter_rust_bridge has not been initialized"。
  final Future<ResidentStatus?> Function()? residentStatus;

  @override
  State<AppSettingPage> createState() => _AppSettingPageState();
}

class _AppSettingPageState extends State<AppSettingPage> {
  bool _autoStart = true; // HKLM Run /silent —— 注册表项由安装器写入，此处仅记忆偏好
  bool _autoUpdate = true; // config.ini autoUpgrade
  bool _wakeLock = false; // wakelock_plus
  bool _floating = false; // desktop_multi_window 悬浮窗

  /// 阈值弹窗提醒的静音状态（键 → 是否已关）。弹窗上点「不再提示」写同一份 prefs，
  /// 这里就是 :466 那句「您可在PC Manager-设置 中再次开启」指的入口。
  Map<String, bool> _reminderMuted = {};

  ResidentStatus? _resident; // 常驻 agent / 守护服务状态
  bool _installing = false;

  /// 网卡列表（只为认被禁用的那些）。读不到就当没有——那就别显示那一行，
  /// 列不出名字的网卡点「启用」只会失败。
  List<Nic> _nics = const [];

  /// 服务**已装但停着** —— 按钮要变成「重启守护服务」而不是「安装」。
  ///
  /// 判据：Windows 明确回了 `NOT_INSTALLED`（1060）才叫没装；`UNKNOWN`（查不到）
  /// **不能**当成"装了"——那会在没装时劝用户去"重启"，而重启一个不存在的服务
  /// 只会失败。分界要和 Rust 侧那个 1060 判断对齐。
  /// 读不到状态（_resident 为 null）也按"没装"处理：那正是「安装」该出现的场合。
  bool get _serviceInstalled {
    final s = _resident?.serviceState;
    // 读不到、以及明确"没装"（1060）与"查不到"（UNKNOWN）都按**没装**处理。
    // ⚠ 别写成"只要不是 UNKNOWN 就算装了"——`NOT_INSTALLED` 会被那句话说成"装了"，
    // 于是去劝用户重启一个不存在的服务。这条判据有测试钉着（settings_action_guard_test）。
    if (s == null || s.isEmpty || s == 'UNKNOWN' || s == 'NOT_INSTALLED') {
      return false;
    }
    return true;
  }

  /// hosts / 手动代理的实测状态（进设置页读一次，供网络修复那行显示）。
  NetworkOverrides? _overrides;

  /// 网络修复正在跑（用户确认之后才置 true）。修复要动 DNS/hosts/代理，
  /// 中间几秒这一行原来**什么都不显示**——看着像没反应，于是会被再点一次，
  /// 两个修复流程叠在一起跑。参考实现自带这个进行态的说法「正在修复」`:57`，
  /// 与清理页那条「正在删除」`:235` 同一档设计。
  bool _fixing = false;

  /// 在用网卡的 DHCP/DNS 实测值——先把现状摆出来，再谈"修复"。
  NetworkDiagnosis? _diagnosis;

  /// 存储感知开关（HKCU\…\StoragePolicy）。null = 还没读到，
  /// 此时开关画成不可拨——先报一个"关"等于替用户报了个没读过的状态。
  bool? _storageSense;

  @override
  void initState() {
    super.initState();
    _loadFlags();
  }

  Future<void> _loadFlags() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _autoStart = prefs.getBool('autoStart') ?? true;
      _autoUpdate = prefs.getBool('autoUpdate') ?? true;
      _wakeLock = prefs.getBool('wakeLock') ?? false;
      _floating = FloatingWindowHost.instance.isRunning;
      _reminderMuted = {
        for (final k in kReminderKinds)
          k.key: prefs.getBool(reminderPrefKey(k.key)) ?? false
      };
    });
    await _refreshResident();
    await _readStorageSense();
    await _readOverrides();
    await _readDiagnosis();
    await _readNics();
  }

  /// 读网卡列表（只为认被禁用的那些）。读不到就留空，别把"读不到"报成"没有坏网卡"。
  Future<void> _readNics() async {
    try {
      final nics = await RustApi.instance.adapterList();
      if (mounted) setState(() => _nics = nics);
    } catch (_) {
      if (mounted) setState(() => _nics = const []);
    }
  }

  /// 读 DHCP/DNS 现状。读不到就留 null，不拿"未知"当"正常"。
  Future<void> _readDiagnosis() async {
    try {
      final d = await RustApi.instance.diagnoseNetwork();
      if (mounted) setState(() => _diagnosis = d);
    } catch (_) {
      if (mounted) setState(() => _diagnosis = null);
    }
  }

  /// 读 hosts/代理状态。读不到就留 null，那一行照旧只做 DNS/DHCP 重置。
  Future<void> _readOverrides() async {
    try {
      final ov = await RustApi.instance.networkOverrides();
      if (mounted) setState(() => _overrides = ov);
    } catch (_) {
      if (mounted) setState(() => _overrides = null);
    }
  }

  /// 读存储感知开关。读失败不摆开关——报不出状态就不该假装读到了。
  Future<void> _readStorageSense() async {
    try {
      final on = await RustApi.instance.storageSenseEnabled();
      if (mounted) setState(() => _storageSense = on);
    } catch (_) {
      if (mounted) setState(() => _storageSense = null);
    }
  }

  Future<void> _setReminderMuted(String key, bool muted) async {
    await setReminderMuted(key, muted: muted);
    if (!muted) releaseReminder(key); // 重新开启后本轮就能再次弹，不必等重启
    if (!mounted) return;
    setState(() => _reminderMuted[key] = muted);
  }

  Future<void> _refreshResident() async {
    final injected = widget.residentStatus;
    final status = injected != null
        ? await injected()
        : await ResidentAgentGuard.instance.status();
    if (!mounted) return;
    setState(() => _resident = status);
  }

  /// sc create/start ComputerKeepAlive 需要管理员令牌，失败只回报不抛异常。
  /// 这条会写系统服务（sc create），是本机改动里最重的一步——和删文件、
  /// 结束进程同一档，必须先过一次确认，不能点一下就执行。
  Future<void> _installKeepAliveService() async {
    final ok = await confirmDestructive(context,
        title: '安装并启动守护服务',
        body: '将执行 sc create/start CmKeepAlive 注册一个系统服务，'
            '开机自启并由它拉起采集进程。需管理员权限，确定继续？');
    if (!ok || !mounted) return;
    setState(() => _installing = true);
    final msg = await ResidentAgentGuard.instance.installService();
    if (!mounted) return;
    setState(() => _installing = false);
    await _refreshResident();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 5)));
  }

  /// 已安装但停着时的出路：`kill_restart_service`（sc stop + sc start）。
  ///
  /// 同样要确认——它停掉的是正在跑的系统服务，属于系统配置改动，和安装同一档。
  /// 停不掉也不假装成功：Rust 侧对 sc start 的退出码有校验，失败会带原因上来。
  Future<void> _restartKeepAliveService() async {
    final ok = await confirmDestructive(context,
        title: '重启守护服务',
        body: '将先停止再启动 CmKeepAlive 服务，期间采集守护会短暂中断。'
            '需管理员权限，确定继续？');
    if (!ok || !mounted) return;
    setState(() => _installing = true);
    final messenger = ScaffoldMessenger.of(context);
    var message = '守护服务已重启';
    try {
      await RustApi.instance.restartService(kKeepAliveServiceName);
    } catch (e) {
      message = '重启守护服务失败：${bridgeErrorText(e)}';
    }
    if (!mounted) return;
    setState(() => _installing = false);
    await _refreshResident();
    messenger.showSnackBar(
        SnackBar(duration: const Duration(seconds: 5), content: Text(message)));
  }

  /// 被禁用的网卡名。判据与体检那句「未检测到在用网卡」一致：没有 IP、但
  /// netsh 名字读得到（读不到就无从启用，列出来只是让人以为能点）。
  List<String> get _disabledNics => [
        for (final n in _nics)
          if (!n.hasIp && n.netshName.isNotEmpty) n.netshName,
      ];

  /// 启用被禁用的网卡（netsh admin=enable，需管理员权限）。
  ///
  /// 同样是系统配置改动，先确认；**逐张回报**——启一张失败不代表别的也失败，
  /// 笼统报一句"失败"用户不知道该重试哪一张。
  Future<void> _enableDisabledNics() async {
    final names = _disabledNics;
    if (names.isEmpty) return;
    final ok = await confirmDestructive(context,
        title: '启用网卡',
        body: '将启用 ${names.join('、')}。启用后本机会重新接入网络，'
            '需管理员权限，确定继续？');
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final done = <String>[];
    final failed = <String>[];
    for (final n in names) {
      try {
        await RustApi.instance.enableAdapter(n);
        done.add(n);
      } catch (e) {
        failed.add('$n（${bridgeErrorText(e)}）');
      }
    }
    await _readNics();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(failed.isEmpty
            ? '已启用：${done.join('、')}'
            : '部分网卡启用失败：${failed.join('；')}'
                '${done.isEmpty ? '' : '已启用：${done.join('、')}'}')));
  }

  /// 打开系统自带的「存储感知」设置页。失败只回报——打不开一个设置页
  /// 不该变成一个没头没脑的异常。
  Future<void> _openStorageSenseSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RustApi.instance.openStorageSenseSettings();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('打开系统存储感知设置失败：${bridgeErrorText(e)}')));
    }
  }

  /// 打开 hosts 供查看。**只读**——它不做任何恢复，恢复是上面那条的动作，
  /// 而且那一条要先确认。这一条是纯查看，所以不必拦。
  Future<void> _openHostsInNotepad() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RustApi.instance.notepadOpenHost();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('打开 hosts 失败：${bridgeErrorText(e)}')));
    }
  }

  Future<void> _saveFlag(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Group(title: '通用', children: [
        _SwitchTile(
          title: '开机自动启动',
          // ⚠ 这一行的动作我们**做不到**：真正决定开机自启的是 HKLM Run 项，
          // 而写那一项的是安装器——本项目没有安装器（仓库边界见 local_notes 与
          // project-public-repo-boundary）。所以这个开关只把偏好存进 SharedPreferences，
          // 全仓没有任何地方读它去做事（grep 只有这里写、这里回显）。
          // 副标题把这件事说在前面，别让人以为拨了就改了开机行为。
          subtitle: '仅记住偏好；开机自启由安装器写入注册表，本程序不代其改动',
          value: _autoStart,
          onChanged: (v) {
            setState(() => _autoStart = v);
            unawaited(_saveFlag('autoStart', v));
          },
        ),
        _SwitchTile(
          // 措辞换成参考实现自带的开关句「有更新时自动升级PC Manager客户端」`:501`，
          // 另有「自动升级」`:476` 佐证同一件事。原先写「自动更新」——表里**搜不到**这个词。
          //
          // ⚠ **换它的原话反而把问题放大了**：这句话明确承诺"有更新时自动升级"，
          // 而本项目**没有升级通道**（没有更新源端点，`exec_image_package` 与补丁安装
          // 那 6 个 codec 都因此故意不接），也没有把偏好上报给后端的路。
          // 于是这个开关此前是**纯惯性控件**：写进 prefs、只被回显成开关自己，
          // 拨与不拨，系统行为一模一样。措辞对齐之后它更像一个真承诺——那更糟。
          // 现在把做不到的部分写在副标题里，等升级通道落地再撤掉这句说明。
          title: '有更新时自动升级PC Manager客户端',
          subtitle: '仅记住偏好；升级服务尚未接入，当前不会自动下载或安装任何更新',
          value: _autoUpdate,
          onChanged: (v) {
            setState(() => _autoUpdate = v);
            unawaited(_saveFlag('autoUpdate', v));
          },
        ),
        _SwitchTile(
          title: '阻止云电脑息屏',
          value: _wakeLock,
          onChanged: (v) {
            setState(() => _wakeLock = v);
            unawaited(_saveFlag('wakeLock', v));
            unawaited(v ? WakelockPlus.enable() : WakelockPlus.disable());
          },
        ),
        _SwitchTile(
          // 措辞取参考实现自带的「桌面悬浮球」（zh_strings.txt:283），不叫「悬浮窗」
          title: '桌面悬浮球',
          value: _floating,
          onChanged: (v) {
            setState(() => _floating = v);
            // 偏好由宿主在 open/close 内落盘（floatingWindow），启动时自动恢复
            unawaited(v
                ? FloatingWindowHost.instance.open()
                : FloatingWindowHost.instance.close());
          },
        ),
        _SwitchTile(
          // 「存储感知」(:590) 是参考实现自带的开关名，对应
          // crateApiSysinfoStorageSenseR* 三个 codec：读状态 / 写开关 / 打开
          // 系统设置页。原来三个 codec 都实现了、适配层却没有出口，等于没有
          // 这条能力（reachable 检查里数得出来）。
          title: '存储感知',
          // 没读到值之前不摆开关：先显示"关"等于替用户报了个没读过的状态
          value: _storageSense,
          onChanged: _storageSense == null
              ? null
              : (v) async {
                  // 先乐观更新，失败再读回来——开关拨下去等一圈才有反应会被
                  // 当成没点上（启动项那处也是这么处理并读回真实值的）
                  setState(() => _storageSense = v);
                  try {
                    await RustApi.instance.setStorageSense(v);
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        duration: const Duration(seconds: 5),
                        content: Text(perItemFailure('修改存储感知', '当前用户', e))));
                    await _readStorageSense();
                  }
                },
        ),
        // 存储感知是 Windows 自带的功能，开关只管"开/关"，用户想弄清它到底
        // 什么时候清理时没有去处。这里给系统自己那份设置页的入口
        // （`show_stroge_sense` → ms-settings:storagesense）。
        ListTile(
          leading: const Icon(Icons.open_in_new),
          title: const Text('打开系统存储感知设置'),
          subtitle: const Text('查看 Windows 自带的那份说明与清理计划'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_openStorageSenseSettings()),
        ),
      ]),
      const SizedBox(height: 12),
      _Group(title: kReminderSectionTitle, children: [
        for (final k in kReminderKinds)
          _SwitchTile(
            title: k.title,
            subtitle: k.description,
            value: _reminderMuted[k.key] != true,
            onChanged: (v) => unawaited(_setReminderMuted(k.key, !v)),
          ),
      ]),
      const SizedBox(height: 12),
      _Group(title: '常驻采集与守护', children: [
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: Text(_resident?.summary ?? '正在读取常驻进程状态…'),
          subtitle: const Text(
            '守护模型：CmKeepAlive 服务每 10s 巡检并拉起 cm_agent.exe'
            '（30s 轮询采集任务）。服务未运行时由主程序在当前会话内守护。',
            style: TextStyle(fontSize: 11, color: AppTheme.textSub),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
            onPressed: _refreshResident,
          ),
        ),
        ListTile(
          leading: Icon(_serviceInstalled
              ? Icons.restart_alt
              : Icons.install_desktop_outlined),
          // 装了却停着的时候，按钮必须说「重启服务」而不是「安装」——
          // 对一个已经装好的服务再跑一遍 sc create 是错的，而且用户点之前
          // 并不知道自己已经装过了。
          title: Text(_serviceInstalled ? '重启守护服务' : '安装并启动守护服务'),
          subtitle: Text(_serviceInstalled
              ? '先停止再启动 CmKeepAlive，需管理员权限'
              : 'sc create/start CmKeepAlive，需管理员权限'),
          trailing: _installing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: _installing
              ? null
              : (_serviceInstalled
                  ? _restartKeepAliveService
                  : _installKeepAliveService),
        ),
      ]),
      const SizedBox(height: 12),
      _Group(title: '网络', children: [
        ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: const Text('打开系统代理设置'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              unawaited(RustApi.instance.openSettingNetworkProxyPage()),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          // 体检里点名了 hosts / 手动代理，这里就把实测状态摆出来——
          // 用户是顺着「去处理」跳过来的，光说"重置 DNS/DHCP"接不上话。
          title: Text(_networkFixTitle()),
          // 没读到就不画副标题：空字符串会占一行高度，把这一行的版式挤歪
          subtitle: _fixing
              ? const Text('正在修复',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSub))
              : _networkFixSubtitle() == null
                  ? null
                  : Text(_networkFixSubtitle()!,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSub)),
          trailing: _fixing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: _runNetworkFixGuarded,
        ),
        // 体检报「未检测到在用网卡」时会点名被禁用的网卡，这里就是那个"去处理"的落点——
        // 没有它就等于把出路推给用户自己翻设备管理器。
        if (_disabledNics.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: Text('启用网卡（${_disabledNics.length}）'),
            subtitle: Text(_disabledNics.join('、'),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _enableDisabledNics,
          ),
        // 体检里点名了 hosts 被改写时，用户要看的不是"恢复默认"（那会连他自己
        // 加的映射一起丢掉），而是先看见是谁写了什么。
        if (_overrides?.hostsModified ?? false)
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('用记事本打开 hosts'),
            subtitle: const Text('先看清被改了什么，再决定要不要恢复默认'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(_openHostsInNotepad()),
          ),
      ]),
      const SizedBox(height: 12),
      _Group(title: '其他', children: [
        ListTile(
            leading: const Icon(Icons.feedback_outlined),
            // 用自带的那句「意见反馈」(`:295`)。原来这行写「问题反馈」——
            // 表里搜不到那个词，而**我们自己的反馈页抬头已经在用它**
            // （见 `_FeedbackPage` 的 `title: '意见反馈'`），等于同一个入口两个名字。
            title: const Text('意见反馈'),
            subtitle: const Text('自动打包日志上传'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/app_setting_route/feedback')),
        ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/app_setting_route/app_about')),
      ]),
    ]);
  }

  /// 网络修复那一行的副标题：把实测到的现状说清楚，再谈"修复"。
  ///
  /// 「重置」是治标——DHCP 被关了、DNS 指到手改的地址，重置一次也未必好。
  /// 先摆现状，用户才知道该找运营商还是找自己。读不到就只说 hosts/代理
  /// 那两样，不拿"未知"当"正常"。
  String? _networkFixSubtitle() {
    final parts = <String>[];
    final ov = _overrides;
    if (ov != null) {
      if (ov.hostsModified) {
        parts.add('hosts 被改写，将一并恢复默认内容');
      } else if (!ov.allChecked) {
        // 探针没跑到 ≠ hosts 干净。不说的话，这一行看起来与"两项都没问题"
        // 完全一样——而体检那边已经把这条报成"未能确认"了。
        parts.add('未能确认 hosts 与手动代理状态');
      }
      if (ov.manualProxy) parts.add('手动代理已开启，将一并关闭');
    }
    final d = _diagnosis;
    if (d != null) {
      if (d.dnsLooksBroken) {
        parts.add('当前 DNS 无有效配置');
      } else {
        // null = 没读到网卡。写「DHCP 关」是凭空结论，写不出状态才对。
        // 先取到局部变量：`d.dhcpEnabled` 是字段，三元里不会被收窄。
        final dhcpEnabled = d.dhcpEnabled;
        final dhcp = dhcpEnabled == null
            ? 'DHCP 未确认'
            : 'DHCP ${dhcpEnabled ? '开' : '关'}';
        parts.add('$dhcp · DNS ${d.dnsServers.join('、')}');
      }
    }
    return parts.isEmpty ? null : parts.join('；');
  }

  /// 网络修复那一行的标题：把体检点名的东西原样摆出来。
  String _networkFixTitle() {
    final ov = _overrides;
    if (ov == null) return '网络修复（DNS/DHCP）';
    if (ov.any) return '网络修复（DNS/DHCP、hosts、代理）';
    // 没读到也说一句：标题退回最简的样子会让人以为"就剩 DNS/DHCP 了"，
    // 而实际是 hosts/代理**根本没查**。
    if (!ov.allChecked) return '网络修复（DNS/DHCP，部分状态未确认）';
    return '网络修复（DNS/DHCP）';
  }

  /// 这一行的点击入口：挡住重复点，并**无论走哪条路都把进行态收掉**。
  /// `_runNetworkFix` 中途抛错（`_readOverrides`/`_readDiagnosis` 不在它自己的
  /// `step()` 兜底里）时，如果没人复位，这一行就永远转圈且再也点不动——
  /// 比"不报进行中"更糟，所以复位放 `finally`，而不是放在函数末尾。
  Future<void> _runNetworkFixGuarded() async {
    if (_fixing) return;
    try {
      await _runNetworkFix();
    } finally {
      if (mounted && _fixing) setState(() => _fixing = false);
    }
  }

  /// 网络修复：先按实测状态把 DNS 真的修回来，再重置 Winsock。
  ///
  /// 原来的标题写着「DNS/DHCP 重置」，实际跑的是 `setNetworkFix`——它只做
  /// `ipconfig /flushdns` + `netsh winsock reset`，**既不重置 DNS 也不重置 DHCP**。
  /// DNS 被手改成不可用地址时跑完照样上不了网，界面却报"已修复"。
  ///
  /// hosts / 手动代理也一并处理：体检里点名了它们，用户顺着「去处理」跳过来
  /// 就是要解决那个。每一步单独回报——改 hosts 要管理员、关代理是改他的设置、
  /// 改 DNS 要管理员，任一步失败都不能笼统报"已修复"。
  Future<void> _runNetworkFix() async {
    final ov = _overrides;
    final d = _diagnosis;
    final willFixHosts = ov?.hostsModified ?? false;
    final willFixProxy = ov?.manualProxy ?? false;
    // 只在**真的坏了**时才动 DNS。DNS 明明是好的（云电脑给的 100.127.129.129
    // 就是对的）却去重置，只会把能用的配置换成 DHCP 自动获取——那是没事找事。
    final brokenNics =
        (d != null && d.dnsLooksBroken) ? await _brokenNics() : <Nic>[];
    final extra = [
      if (brokenNics.isNotEmpty) '将 ${brokenNics.length} 张网卡恢复为 DHCP 自动获取 DNS',
      if (willFixHosts) '恢复 hosts 为默认内容',
      if (willFixProxy) '关闭手动代理',
    ].join('、');
    final ok = await confirmDestructive(context,
        title: '网络修复（DNS/DHCP）',
        body: '将重置 DNS 与 DHCP 配置以排查上不了网的问题。'
            '${extra.isEmpty ? '' : '并$extra。'}'
            '执行期间当前网络连接会短暂中断，需管理员权限，确定继续？');
    if (!ok || !mounted) return;
    // 用户**确认之后**才立进行态：确认框还开着时报「正在修复」是假信息。
    setState(() => _fixing = true);
    final done = <String>[];
    final failed = <String>[];
    Future<void> step(String label, Future<void> Function() body) async {
      try {
        await body();
        done.add(label);
      } catch (e) {
        failed.add('$label（${bridgeErrorText(e)}）');
      }
    }

    for (final nic in brokenNics) {
      await step('${nic.netshName} 已恢复 DHCP 自动获取 DNS',
          () => RustApi.instance.setAdapterDhcp(nic.netshName));
    }
    await step('DNS 缓存已清理', RustApi.instance.setNetworkFix);
    if (willFixHosts) {
      await step('hosts 已恢复', () async {
        // 本来就干净时返回 false，不是失败——别报成"失败"吓人
        if (!await RustApi.instance.fixHostsConfigured()) {
          done.add('hosts 本就干净，未改动');
        }
      });
    }
    if (willFixProxy) {
      await step('手动代理已关闭', RustApi.instance.disableProxy);
    }
    await _readOverrides();
    // DNS 也可能刚被改过：不重读的话这一行还摆着修复前的"无有效配置"，
    // 用户点完看到"已修复"却配着一行说没修好的话。
    await _readDiagnosis();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (failed.isEmpty) {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('网络修复已执行：${done.join('、')}')));
    } else {
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('网络修复部分失败：${failed.join('；')}'
              '${done.isEmpty ? '' : '已完成：${done.join('、')}'}')));
    }
  }

  /// 值得动手的网卡：配了 IP（否则谈不上上不了网）且 netsh 名字读得到
  /// （读不到就无从执行，列出来只会让人以为已经修过）。
  Future<List<Nic>> _brokenNics() async {
    try {
      final nics = await RustApi.instance.adapterList();
      return nics.where((n) => n.hasIp && n.netshName.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // 用 Material 承载背景色而不是 Container+BoxDecoration：ListTile 的
    // 水波纹画在最近的 Material 上，被中间那层 DecoratedBox 挡住的话，
    // 点下去一点反馈都没有（Flutter 会为此断言）。
    return Material(
      color: AppTheme.cardBg,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(title,
                style: const TextStyle(color: AppTheme.textSub, fontSize: 12))),
        ...children,
      ]),
    );
  }
}

/// 启动时把「阻止云电脑息屏」的偏好**重新落到系统上**。
///
/// ⚠ 为什么要这么一层：这个开关原来只在 `onChanged` 里调 `WakelockPlus.enable()`，
/// 而**没有任何地方在启动时重放它**。于是——用户开过一次、存了 `wakeLock=true`，
/// 重启之后设置页那格照样回显成"开"（读 prefs 画出来的），**但系统层面什么都没做**：
/// 屏幕该息还是息。比"惯性控件"更糟一档：那是从来没生效，这是**上一次真的生效过、
/// 这次悄悄没了还显示着开**。
///
/// 两条刻意的保守选择：
///  * **只在存过 true 时才动手**（没存过 / 存 false 一律不碰 `WakelockPlus`）：
///    不然第一次启动就给用户的机器加上"不息屏"，那是凭空多出来的系统级副作用。
///  * 失败只记日志、返回 false：阻止息屏失败不该拦住启动。
///
/// `setLock` 是给单测留的注入缝——测试环境没有 wakelock 插件，
/// 真调一次会 `MissingPluginException`。
Future<bool> restoreWakeLock(
    {Future<void> Function(bool enabled)? setLock}) async {
  final prefs = await SharedPreferences.getInstance();
  if ((prefs.getBool('wakeLock') ?? false) != true) return false;
  try {
    final apply =
        setLock ?? (v) => v ? WakelockPlus.enable() : WakelockPlus.disable();
    await apply(true);
  } catch (e) {
    await RustApi.instance.logWarn('恢复「阻止云电脑息屏」失败: $e');
    return false;
  }
  return true;
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile(
      {required this.title,
      this.subtitle,
      required this.value,
      required this.onChanged});
  final String title;

  /// 参考实现的提醒行下面挂着「当…时，系统将自动触发此提示」这类说明，
  /// 开关和说明同行，不是点进去的二级页。
  final String? subtitle;

  /// null = 还没读到值（对应 onChanged 为 null，开关不可拨）
  final bool? value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return SwitchListTile(
        value: value ?? false,
        onChanged: onChanged,
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: sub == null
            ? null
            : Text(sub,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSub)));
  }
}

/// 「检测更新」弹窗的正文。
///
/// 只说**能核实的话**：本地版本 + 本机镜像包版本（读得到才写）。远程更新源没接，
/// 就明确说没接——**不拿本地镜像版本冒充"有新版本"**，那个文件不是更新源，
/// 拿它比出来的结论是编的。
String updateCheckText({String? localVersion, String? imageVersion}) {
  final local = (localVersion ?? '').trim();
  final image = (imageVersion ?? '').trim();
  final buf = StringBuffer();
  if (local.isNotEmpty) buf.write('本地版本 $local。');
  if (image.isNotEmpty) {
    buf.write('本机镜像包版本 $image。');
  }
  buf.write('远程更新源尚未接入，暂时无法检测是否有新版本。');
  return buf.toString();
}

/// 关于页读数失败时的收尾：记一条日志后**原样把异常吞掉**。
///
/// 页面在这几种读数上**没有**要报的错——`_version`/`_machineId`/`_imageVersion`
/// 为空串时那一行不出现，[updateCheckText] 也因为空而少写一句。所以失败只需
/// 让日志里有，不该弹提示打扰一个正在看版本号的人。
///
/// `catchError` 要求回调返回的**类型**与 Future 一致，这几个都是 `Future<void>`
/// （then 里只做 setState），所以 `catchError` 后必须接一个返回 void 的函数；
/// 直接写 `.catchError((_) {})` 能过是因为 `{}` 恰好是 void。
Function logAboutReadFailure(String what) => (Object e) {
      unawaited(RustApi.instance.logError('读取$what失败: $e'));
    };

class AppAboutPage extends StatefulWidget {
  const AppAboutPage({super.key, this.version, this.windowsVersion});

  /// 测试注入用：不给时走真桥 `windowsVersion()`（读 HKLM 的详细版本号）。
  final WindowsVersion? windowsVersion;

  /// 测试注入用：不给时走真桥 `getVersionInfo()`。
  final String? version;

  @override
  State<AppAboutPage> createState() => _AppAboutPageState();
}

class _AppAboutPageState extends State<AppAboutPage> {
  String _version = '';
  WindowsVersion? _winVersion;
  String _machineId = '';

  /// 本机镜像包版本（读 ProgramData\ImageUpgrade\version.txt）；没装镜像包为空串。
  String _imageVersion = '';

  @override
  void initState() {
    super.initState();
    final injected = widget.version;
    if (injected != null) {
      // 注入时不碰桥（测试环境没有 RustLib）
      _version = injected;
      return;
    }
    final api = RustApi.instance;
    // 这四个读都**不能抛**：抛出去是无人接的 Future 错误（页面还照常渲染，
    // 只是那一行永远空着，没人知道为什么）。而 `_version == ''` 这个状态本身
    // 是安全的——[updateCheckText] 与下面的版本行都会因为空而少写一句，
    // 不会因此报出"本地版本"这种没读到的东西。所以这里只要不炸、只记日志。
    // ⚠ 四条一视同仁：`windowsVersion` 当初单独挂了个 onError，其余三条没有，
    // 那种"有的挂了有的没挂"的不一致比全挂更难排查。
    api.getVersionInfo().then((v) {
      if (mounted) setState(() => _version = v);
    }).catchError(logAboutReadFailure('版本'));
    final wv = widget.windowsVersion;
    if (wv != null) {
      _winVersion = wv;
    } else {
      // 读不到就不显示这一行：宁可少一行，也不要写一个空版本串
      // 读不到就保持 null（那一行不显示），不编一个空版本串出来
      RustApi.instance.windowsVersion().then((v) {
        if (mounted) setState(() => _winVersion = v);
      }).catchError(logAboutReadFailure('Windows 详细版本'));
    }
    api.getMachineId().then((v) {
      if (mounted) setState(() => _machineId = v);
    }).catchError(logAboutReadFailure('机器标识'));
    api.getImageVersion().then((v) {
      if (mounted) setState(() => _imageVersion = v);
    }).catchError(logAboutReadFailure('镜像版本'));
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(title: '关于', onBack: () => context.go('/app_setting_route')),
      Expanded(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/images/_computer_logo.webp',
                width: 84,
                errorBuilder: (_, __, ___) => const Icon(Icons.computer,
                    size: 72, color: AppTheme.primary)),
            const SizedBox(height: 12),
            const Text('PC Manager',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            // 用详细版本（产品名 + 显示版本 + Build.xxx）而不是只有产品名——
            // 提问题单时对方只认完整串
            Text(_winVersion?.fullVersion ?? _version,
                style: const TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                // 这里**不能**弹「当前已是最新版本」：没有任何一处在联网查版本，
                // 说"已是最新"等于凭空编一个结论（参考实现真的去比对了，才敢这么写
                // 「当前已是最新版本」:514）。升级服务接入前如实说清现状。
                showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('检测更新'),
                    content: Text(updateCheckText(
                        localVersion: _version, imageVersion: _imageVersion)),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('检测更新'),
            ),
            const SizedBox(height: 8),
            Text('机器标识 $_machineId',
                style: const TextStyle(color: AppTheme.textSub, fontSize: 10)),
            // 这一行原来染成主题蓝，看着像能点，实际没有任何 onTap——摆一个点不动的
            // 入口比不摆更糟。协议正文不能抄参考实现那份（那是原厂法律文本），
            // 而本项目也没有自己的协议文件，所以这里只如实写成静态说明文字。
            const Text('用户协议 · 隐私政策（尚未提供）',
                style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
          ]),
        ),
      ),
    ]);
  }
}

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.submitter});

  /// 注入点：默认真实链路，测试可换成假的以离线跑 UI 状态流。
  final FeedbackSubmitter? submitter;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _controller = TextEditingController();

  late final FeedbackSubmitter _submitter =
      widget.submitter ?? FeedbackSubmitter.production();

  /// 授权勾选：参考实现文案「授权上传日志与诊断数据」，未勾选不允许提交（提示「勾选同意」）。
  /// 一次授权同时覆盖日志采集与上传，避免“提交了但没带日志”的中间态。
  bool _agreed = false;
  FeedbackStage _stage = FeedbackStage.idle;
  String _message = '';
  bool _busy = false;

  static const _agreeKey = 'feedbackAgreeUploadLog';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      // 记住上次的授权选择，但仍由用户可见的勾选框决定
      if (mounted && (p.getBool(_agreeKey) ?? false)) {
        setState(() => _agreed = true);
      }
    }).onError((Object e, StackTrace _) {
      // 读不到就**保持未勾选**：这是安全的一侧（用户必须自己勾一次才上传）。
      // 记一条日志，别让这次失败静悄悄过去。
      unawaited(RustApi.instance.logError('读取反馈授权记录失败: $e'));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final content = _controller.text.trim();
    if (content.isEmpty) {
      setState(() => _message = '请填写问题描述');
      return;
    }
    if (!_agreed) {
      setState(() => _message = '勾选同意');
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await SharedPreferences.getInstance()
          .then((p) => p.setBool(_agreeKey, true));
      await _submitter.submit(
        content: content,
        onStage: (s) => mounted ? setState(() => _stage = s) : null,
      );
      _controller.clear();
      if (mounted) setState(() => _stage = FeedbackStage.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = FeedbackStage.failed;
          _message = bridgeErrorText(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      PageHeader(
          title: '意见反馈',
          // 换成参考实现自带的采集说明 `:584`——它比我们那句**多说了一件要紧的事**：
          // 最小化采集、且不含个人隐私文件。原来那句是我们自己的说法。
          subtitle: '我们将最小化采集系统及应用的报错日志，不包含个人隐私文件，便于工程师快速定位问题',
          onBack: () => context.go('/app_setting_route')),
      Expanded(
        child: _stage == FeedbackStage.done
            ? _SuccessPage(
                onAgain: () => setState(() {
                  _stage = FeedbackStage.idle;
                  _message = '';
                }),
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  TextField(
                    controller: _controller,
                    maxLines: 8,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      hintText: '请描述你遇到的问题…',
                      filled: true,
                      fillColor: AppTheme.cardBg,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _agreed,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _agreed = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('授权上传日志与诊断数据',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        '我们将最小化采集系统及应用的报错日志，不包含个人隐私文件，便于工程师快速定位问题',
                        style:
                            TextStyle(color: AppTheme.textSub, fontSize: 11)),
                  ),
                  if (_message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_message,
                          style: const TextStyle(
                              color: AppTheme.danger, fontSize: 12)),
                    ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 46)),
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? _stage.label : '提交反馈'),
                  ),
                ]),
              ),
      ),
    ]);
  }
}

/// 「反馈提交成功」态：参考实现另有「感谢您的反馈，我们会尽快处理」与「再次提交」
class _SuccessPage extends StatelessWidget {
  const _SuccessPage({required this.onAgain});
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.check_circle_outline, size: 56, color: AppTheme.primary),
      const SizedBox(height: 14),
      const Text('反馈提交成功',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('感谢您的反馈，我们会尽快处理',
          style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
      const SizedBox(height: 20),
      OutlinedButton(onPressed: onAgain, child: const Text('再次提交')),
    ]);
  }
}
