import 'package:flutter/foundation.dart';

/// 正在进行中的长任务（扫描 / 清理）登记表。
///
/// 为什么要有这么一份全局状态：参考实现自带一句
/// 「关闭窗口将会取消正在进行中的任务。」（zh_strings.txt:89）。这句话只有在
/// "系统知道现在有没有任务在跑"的时候才说得出、也才该说；我们原来把扫描态关在
/// 各个扫描页自己的 State 里，页面一换就没人管了——Rust 侧的扫描还在后台跑，
/// 关窗确认也无从判断要不要提醒。
///
/// 键用扫描页的 `cancelKey`（deep_clean / large_file / dup_file / system_disk），
/// 与 Rust 侧 `cancel(key)` 同一套名字，销记和取消因此不会走偏。
class RunningTasks extends ChangeNotifier {
  RunningTasks._();

  static final RunningTasks instance = RunningTasks._();

  final Set<String> _running = {};

  /// 有没有任务在跑。关窗确认按它决定要不要带上 :89 那句提醒。
  bool get anyRunning => _running.isNotEmpty;

  /// 当前在跑的任务名（测试与日志用；顺序不保证）
  Set<String> get running => Set<String>.unmodifiable(_running);

  /// 登记一个任务。同一个键重复登记只算一个。
  void begin(String key) {
    if (_running.add(key)) notifyListeners();
  }

  /// 销记一个任务。没登记过也不报错。
  void end(String key) {
    if (_running.remove(key)) notifyListeners();
  }

  /// 全部销记（测试之间隔离状态用）
  void reset() {
    if (_running.isEmpty) return;
    _running.clear();
    notifyListeners();
  }
}

/// 有任务在跑时，关窗确认里要带的那句提醒，逐字取 zh_strings.txt:89。
const String kRunningTaskCloseNotice = '关闭窗口将会取消正在进行中的任务。';
