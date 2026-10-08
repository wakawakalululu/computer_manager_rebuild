/// 常驻采集组件的进程模型接线（specs/arch-notes §2）。
///
/// 参考实现：`ComputerKeepAlive` 服务每 10s 巡检进程表，缺失即拉起
/// 常驻 agent（30s 轮询采集任务）。本实现对应 `cm_keep_alive.exe` + `cm_agent.exe`
///（由 windows/CMakeLists.txt 一并构建、安装到 GUI exe 同目录），
/// 服务名为自有的 `CmKeepAlive`（见 kKeepAliveServiceName 注释）。
///
/// GUI 侧职责边界：
/// - 服务 RUNNING：完全让位给服务，不重复拉起，只展示状态；
/// - 服务未安装/未启动：GUI 充当**会话内守护**，缺失即拉起，并按重启次数退避冷却，
///   避免 agent 反复崩溃时风暴式重启；
/// - GUI 退出不回收 agent：参考实现它是常驻进程，随 GUI 生命周期退出会让采集任务失联；
///   完整模型请安装服务（设置页入口，需管理员）。
library;

import 'dart:async';
import 'dart:io';

import 'rust_api.dart';

/// 服务名与两个常驻 exe 的文件名（与 rust/src/bin 的 bin 名一致）。
/// 服务名刻意区别于参考实现的 `ComputerKeepAlive`：本机若装着原厂商服务，同名会让
/// 实现守护误判“服务已在守护”而永久让位，`sc create` 也会与它冲突。
const String kKeepAliveServiceName = 'CmKeepAlive';
const String kAgentExeName = 'cm_agent.exe';
const String kKeepAliveExeName = 'cm_keep_alive.exe';

class ResidentStatus {
  ResidentStatus({
    required this.serviceState,
    required this.agentAlive,
    required this.guardedBy,
  });

  /// sc query 解析出的服务状态。
  /// 'UNKNOWN' = 查了但说不上来；'NOT_INSTALLED' = Windows 明确回了 1060。
  /// 两者都表示"没在跑"，但**只有后者能据此说"还没装"**。
  final String serviceState;
  final bool agentAlive;

  /// '服务' / 'GUI 会话内守护' / '无人守护'
  final String guardedBy;

  bool get serviceRunning => serviceState == 'RUNNING';

  String get serviceStateText {
    // "没装" 与 "查不到" 是两件事：Windows 明确回了 1060 才叫没装。
    // 原来两者都摆成「未安装/不可查询」，等于永远不敢说"还没装"。
    if (serviceState == 'NOT_INSTALLED') return '未安装';
    if (serviceState == 'UNKNOWN') return '状态不可查询';
    if (serviceState == 'RUNNING') return '运行中';
    if (serviceState == 'STOPPED') return '已停止';
    return serviceState;
  }

  String get summary =>
      '守护服务：$serviceStateText 采集进程：${agentAlive ? "运行中" : "未运行"} 由$guardedBy负责拉起';
}

class ResidentAgentGuard {
  ResidentAgentGuard._();
  static final instance = ResidentAgentGuard._();

  /// 巡检周期：与 cm_keep_alive 的 WATCH_INTERVAL_SECS 对齐
  static const _interval = Duration(seconds: 10);

  /// 第 N 次拉起后的冷却时长（首 3 项之外一律 5 分钟）
  static const List<Duration> _backoff = [
    Duration.zero,
    Duration(seconds: 15),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  Timer? _timer;
  bool _busy = false;
  int _spawnCount = 0;
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _lastAgentAlive;
  bool _missingExeReported = false;
  bool _firstTick = true;
  bool _tasklistWarned = false;

  bool get isGuarding => _timer != null;

  /// GUI exe 所在目录：agent/keep_alive 与 config.ini 都以它为路径基准
  String get appDir => File(Platform.resolvedExecutable).parent.path;
  String get agentExePath => '$appDir\\$kAgentExeName';
  String get keepAliveExePath => '$appDir\\$kKeepAliveExeName';

  Future<void> start() async {
    if (_timer != null) return;
    // 巡检是这条链路的**全部**：timer 起不来就等于"无人守护"，而调用方是
    // `unawaited(ResidentAgentGuard.instance.start())`——抛出去没人接，
    // 界面上照样显示"守护已启动"。所以在这里兜住，别让一次失败断掉整条链路。
    try {
      await RustApi.instance
          .logInfo('会话内守护启动：每 ${_interval.inSeconds}s 巡检 $kAgentExeName');
      _timer = Timer.periodic(_interval, (_) => _tick());
      await _tick();
    } catch (e) {
      await RustApi.instance.logError('会话内守护启动失败（采集守护将不可用）: $e');
      // 定时器已经起了就留着：下一轮可能就成功了，犯不着一失败就整个停掉
      if (_timer == null) stop();
    }
  }

  /// 只停掉本 GUI 的巡检；已拉起的 agent 继续常驻（见类注释）
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<ResidentStatus> status() async {
    final serviceState = await _serviceState();
    final agentAlive = await _isAgentRunning() ?? false;
    final guardedBy =
        serviceState == 'RUNNING' ? '服务' : (isGuarding ? 'GUI 会话内守护' : '无人守护');
    return ResidentStatus(
        serviceState: serviceState,
        agentAlive: agentAlive,
        guardedBy: guardedBy);
  }

  /// 安装并启动守护服务（sc create + start，需管理员）。
  /// 返回给用户看的一句话结果，失败不抛异常（GUI 不该因权限问题崩）。
  Future<String> installService() async {
    final api = RustApi.instance;
    if (!File(keepAliveExePath).existsSync()) {
      await api.logError('未找到 $kKeepAliveExeName：$keepAliveExePath');
      return '缺少 $kKeepAliveExeName，无法安装服务';
    }
    try {
      await api.installStartService(kKeepAliveServiceName, keepAliveExePath);
      await api
          .logInfo('守护服务已安装并启动：$kKeepAliveServiceName ← $keepAliveExePath');
      return '服务 $kKeepAliveServiceName 已安装并启动';
    } catch (e) {
      final msg = '安装守护服务失败（需要管理员权限）：${bridgeErrorText(e)}';
      await api.logError(msg);
      return msg;
    }
  }

  // ---- 内部实现 ----

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    final api = RustApi.instance;
    try {
      final serviceState = await _serviceState();
      final alive = await _isAgentRunning();
      if (_firstTick) {
        _firstTick = false;
        await api.logInfo(
            '常驻守护首轮：exeDir=$appDir agentFile=${File(agentExePath).existsSync()} '
            '判定=${alive == null ? "tasklist 失败" : (alive ? "在跑" : "未跑")} 服务=$serviceState');
      }
      if (alive == null) {
        // tasklist 不可用：本轮不判定，避免重复拉起
        if (!_tasklistWarned) {
          _tasklistWarned = true;
          await api.logWarn('tasklist 判定不可用，跳过本轮拉起');
        }
        return;
      }
      if (alive) {
        _tasklistWarned = false;
        if (_lastAgentAlive != true) {
          _lastAgentAlive = true;
          _spawnCount = 0;
          _missingExeReported = false;
          await api.logInfo('检测到 $kAgentExeName 运行中（服务状态 $serviceState）');
        }
        return;
      }
      _lastAgentAlive = false;

      // 服务在跑就交给服务拉起（它也是 10s 一轮），GUI 不抢
      if (serviceState == 'RUNNING') return;

      if (DateTime.now().isBefore(_cooldownUntil)) return;
      if (!File(agentExePath).existsSync()) {
        if (!_missingExeReported) {
          _missingExeReported = true;
          await api.logError('$kAgentExeName 不存在（$agentExePath），会话内守护无法拉起');
        }
        return;
      }

      _spawnCount += 1;
      final cooldown =
          _backoff[(_spawnCount - 1).clamp(0, _backoff.length - 1)];
      _cooldownUntil = DateTime.now().add(cooldown);
      try {
        // detached：不继承 GUI 控制台、不随 GUI 关闭收控制台事件；
        // 与 cm_keep_alive 里的 CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW 同义
        final p = await Process.start(agentExePath, const [],
            mode: ProcessStartMode.detached);
        await api.logInfo(
            '已拉起 $kAgentExeName pid=${p.pid}（第 $_spawnCount 次），冷却 ${cooldown.inSeconds}s');
      } catch (e) {
        await api.logError('拉起 $kAgentExeName 失败: $e');
      }
    } catch (e, s) {
      await api.logError('常驻守护巡检异常: $e $s');
    } finally {
      _busy = false;
    }
  }

  Future<String> _serviceState() async {
    try {
      return await RustApi.instance.serviceStatus(kKeepAliveServiceName);
    } catch (e) {
      // sc.exe 本身不可用（极少见）：按未安装处理，GUI 继续自查守护
      await RustApi.instance.logError('查询服务状态失败: $e');
      return 'UNKNOWN';
    }
  }

  /// null = 判定失败（tasklist 启动不了），调用方据此跳过本轮
  Future<bool?> _isAgentRunning() async {
    try {
      final out = await Process.run(
          'tasklist.exe', ['/FI', 'IMAGENAME eq $kAgentExeName', '/NH']);
      return out.stdout
          .toString()
          .toLowerCase()
          .contains(kAgentExeName.toLowerCase());
    } catch (_) {
      return null;
    }
  }
}
