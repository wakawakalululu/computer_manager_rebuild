import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/theme.dart';
import '../services/agent_process.dart';
import '../services/feedback_service.dart';
import '../services/floating_window_host.dart';
import '../services/rust_api.dart';
import '../widgets/common.dart';

/// 设置区 —— 路由 /app_setting_route
/// 子页：app_about（关于）/ feedback（问题反馈）
class AppSettingPage extends StatefulWidget {
  const AppSettingPage({super.key});

  @override
  State<AppSettingPage> createState() => _AppSettingPageState();
}

class _AppSettingPageState extends State<AppSettingPage> {
  bool _autoStart = true; // HKLM Run /silent —— 注册表项由安装器写入，此处仅记忆偏好
  bool _autoUpdate = true; // config.ini autoUpgrade
  bool _wakeLock = false; // wakelock_plus
  bool _floating = false; // desktop_multi_window 悬浮窗

  ResidentStatus? _resident; // 常驻 agent / 守护服务状态
  bool _installing = false;

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
    });
    await _refreshResident();
  }

  Future<void> _refreshResident() async {
    final status = await ResidentAgentGuard.instance.status();
    if (!mounted) return;
    setState(() => _resident = status);
  }

  /// sc create/start ComputerKeepAlive 需要管理员令牌，失败只回报不抛异常。
  Future<void> _installKeepAliveService() async {
    setState(() => _installing = true);
    final msg = await ResidentAgentGuard.instance.installService();
    if (!mounted) return;
    setState(() => _installing = false);
    await _refreshResident();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 5)));
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
          value: _autoStart,
          onChanged: (v) {
            setState(() => _autoStart = v);
            unawaited(_saveFlag('autoStart', v));
          },
        ),
        _SwitchTile(
          title: '自动更新',
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
          leading: const Icon(Icons.install_desktop_outlined),
          title: const Text('安装并启动守护服务'),
          subtitle: const Text('sc create/start CmKeepAlive，需管理员权限'),
          trailing: _installing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: _installing ? null : _installKeepAliveService,
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
          title: const Text('网络修复（DNS/DHCP）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _runNetworkFix,
        ),
      ]),
      const SizedBox(height: 12),
      _Group(title: '其他', children: [
        ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('问题反馈'),
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

  /// 网络修复：Rust 侧 adapter::set_network_fix 会重置 DNS/DHCP 相关配置，
  /// 需要管理员权限；失败回报到界面而不是静默。
  Future<void> _runNetworkFix() async {
    try {
      await RustApi.instance.setNetworkFix();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('网络修复已执行（DNS/DHCP 重置）')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('网络修复失败：${bridgeErrorText(e)}'),
          duration: const Duration(seconds: 5)));
    }
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12)),
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

class _SwitchTile extends StatelessWidget {
  const _SwitchTile(
      {required this.title, required this.value, required this.onChanged});
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
        value: value,
        onChanged: onChanged,
        title: Text(title, style: const TextStyle(fontSize: 14)));
  }
}

class AppAboutPage extends StatefulWidget {
  const AppAboutPage({super.key});

  @override
  State<AppAboutPage> createState() => _AppAboutPageState();
}

class _AppAboutPageState extends State<AppAboutPage> {
  String _version = '';
  String _machineId = '';

  @override
  void initState() {
    super.initState();
    final api = RustApi.instance;
    api
        .getVersionInfo()
        .then((v) => mounted ? setState(() => _version = v) : null);
    api
        .getMachineId()
        .then((v) => mounted ? setState(() => _machineId = v) : null);
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
            Text(_version, style: const TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                // 检查更新占位 —— 真实实现接入更新服务（config.ini autoUpgrade）
                showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('检查更新'),
                    content: const Text('当前已是最新版本'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('检查更新'),
            ), // 版本更新已开启
            const SizedBox(height: 8),
            Text('机器标识 $_machineId',
                style: const TextStyle(color: AppTheme.textSub, fontSize: 10)),
            const Text('用户协议 · 隐私政策',
                style: TextStyle(color: AppTheme.primary, fontSize: 12)),
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
          subtitle: '提交后将自动收集运行日志便于定位',
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
