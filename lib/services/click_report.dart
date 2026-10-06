/// 点击埋点上报（`specs/routes_ui.txt:11` 的 `/report/click/count`）。
///
/// 规格整理依据：
/// - 接口路径来自 Dart 侧 URI 清单；与反馈链路同理，发请求在 Dart、不进 Rust；
/// - 事件名来自 AOT 里读出的 15 条 `click_*`（`specs/click_events.txt`），
///   命名格式是 `click_<弹窗或控件>_<动作>`。这些串是接口契约的一部分，逐字保留，
///   不按我们的界面措辞另造；
/// - 请求体字段参考实现不可见（产物里只有路径与事件名），按接口语义自拟，见 [clickPayload]。
///
/// 合规：baseHost 只从随包 `config.ini` 读，代码里不硬编码任何网关域名；
/// 埋点是尽力而为的旁路——没配网关、后端不可达、机器标识取不到，都只落一行
/// gui_log 就丢掉这次上报，绝不影响用户刚点的那个动作。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'feedback_service.dart';
import 'rust_api.dart';

const String kClickCountPath = '/report/click/count';

/// 参考实现里能读到的全部点击事件名。界面上还没有对应入口的（`AppCompatibility_window_*`
/// 对应的「应用兼容性」弹窗我们还没做）留在表里当占位，等那个功能落地再接。
const Set<String> kKnownClickEvents = {
  'click_RAM_window_cancel',
  'click_RAM_window_never',
  'click_RAM_window_expedite',
  'click_CPU_window_cancel',
  'click_CPU_window_never',
  'click_CPU_window_ProcessManagement',
  'click_SystemDisk_window_cancel',
  'click_SystemDisk_window_never',
  'click_SystemDisk_window_deepclean',
  'click_SystemDisk_window_tempclose',
  'click_SystemDisk_window_tempopen2',
  'click_AppCompatibility_window_cancel',
  'click_AppCompatibility_window_never',
  'click_AppCompatibility_window_uninstall',
  'click_ball',
};

/// 弹窗上一个动作对应的事件名。
///
/// 动作在界面上是中文（「立即加速」「深度清理」），事件名却是英文标识
///（`click_RAM_window_expedite`），所以按钮文案不能拿来拼事件名，
/// 每个动作得自己带一个 id。
String clickEventFor(String windowKey, String actionId) =>
    'click_${windowKey}_$actionId';

/// 请求体。TODO(假设)：字段名按「哪个控件在什么时候被点了」这个语义自拟，
/// 真实字段待与自建网关联调确认（参考实现的后端不在实现范围内）。
Map<String, dynamic> clickPayload({
  required String event,
  required String machineId,
  required int atMillis,
  String version = kClientVersion,
}) =>
    {
      'event': event,
      'machine_id': machineId,
      'version': version,
      'time': atMillis,
    };

class ClickReporter {
  ClickReporter({
    Future<FeedbackTarget> Function()? resolveTarget,
    Future<void> Function(Uri uri, String body)? send,
    int Function()? now,
    void Function(String message)? onError,
  })  : _resolveTarget = resolveTarget ?? FeedbackTarget.resolve,
        _send = send ?? _postJson,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _onError = onError ?? _warnQuietly;

  final Future<FeedbackTarget> Function() _resolveTarget;
  final Future<void> Function(Uri, String) _send;
  final int Function() _now;

  /// 失败只留痕。测试里换成收集器，就不必为了跑通这条旁路依赖 Rust 桥。
  final void Function(String message) _onError;

  /// 留痕本身也不能抛：桥还没初始化（子引擎抢跑）或测试环境下没有桥时，
  /// 埋点失败的报告失败必须静默，否则异常会跑到用户点的动作头上。
  static void _warnQuietly(String message) {
    try {
      unawaited(RustApi.instance.logWarn(message));
    } catch (_) {}
  }

  /// 上报一次点击。永不抛异常：埋点失败不能把用户刚点的动作带崩。
  Future<void> report(String event) async {
    try {
      final target = await _resolveTarget();
      await _send(
          target.uri(kClickCountPath),
          jsonEncode(clickPayload(
              event: event, machineId: target.machineId, atMillis: _now())));
    } catch (e) {
      _onError('点击上报 $event 失败：$e');
    }
  }
}

Future<void> _postJson(Uri uri, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
    if (res.statusCode >= 400) {
      throw FeedbackException('点击上报接口返回错误状态');
    }
  } finally {
    client.close(force: true);
  }
}

/// 全局默认上报器。测试里换成假实现，或把 [_defaultClickReporter] 换成指向
/// 本地网关的实例。
ClickReporter defaultClickReporter = ClickReporter();

/// UI 侧唯一入口：`reportClick(clickEventFor('RAM_window', 'cancel'))`。
void reportClick(String event) => unawaited(defaultClickReporter.report(event));
