import 'package:computer_manager/services/agent_process.dart';
import 'package:flutter_test/flutter_test.dart';

/// 守护巡检那条链路是 `unawaited(ResidentAgentGuard.instance.start())` 拉起来的
/// ——抛出去没人接。原来 `start()` 里第一次 `_tick()` 抛了就把整条链路带走，
/// 而界面照样按 `_timer != null` 之外的状态说话，很容易看成"守护已就绪"。
///
/// 这里钉的是**可观测的那一半**：`isGuarding` 必须严格跟着定时器的真实生死走，
/// 两者不一致就意味着界面会说一句自己不知道成没成的话。
void main() {
  test('没 start 过就 report「无人守护」，不冒充已守护', () {
    final guard = ResidentAgentGuard.instance;
    guard.stop();
    // stop 之后再 start 之前必须是 false：界面据此说"GUI 会话内守护"，
    // 报 true 就是在替用户断言"有人在巡检"，而其实没有
    expect(guard.isGuarding, isFalse);
  });

  test('ResidentStatus 的三种守护来源说法互斥', () {
    final statuses = [
      ResidentStatus(
          serviceState: 'RUNNING', agentAlive: true, guardedBy: '服务'),
      ResidentStatus(
          serviceState: 'STOPPED', agentAlive: true, guardedBy: 'GUI 会话内守护'),
      ResidentStatus(
          serviceState: 'STOPPED', agentAlive: false, guardedBy: '无人守护'),
    ];

    // 服务在跑时才算 serviceRunning —— 否则界面会同时说"服务运行中"和"无人守护"
    expect(statuses[0].serviceRunning, isTrue);
    expect(statuses[1].serviceRunning, isFalse);
    expect(statuses[2].serviceRunning, isFalse);

    // 汇总行三种说法各出现一次，不重不漏
    expect(statuses.map((s) => s.guardedBy).toSet(), hasLength(3));
    for (final s in statuses) {
      expect(s.summary, contains(s.guardedBy));
      expect(s.summary, contains(s.agentAlive ? '运行中' : '未运行'));
    }
  });

  test('UNKNOWN 与 NOT_INSTALLED 是两件事，不能混成一句', () {
    final u = ResidentStatus(
        serviceState: 'UNKNOWN', agentAlive: false, guardedBy: '无人守护');
    expect(u.serviceStateText, '状态不可查询');
    expect(u.serviceStateText, isNot(contains('未安装')),
        reason: '只有 Windows 明确回了 1060 才叫"未安装"；查不到就别这么说');
    expect(u.serviceRunning, isFalse,
        reason: 'UNKNOWN 不是 RUNNING，拿它当"在跑"就是凭空断言');

    // Windows 明确回了 1060 的那种，才叫"未安装"
    final n = ResidentStatus(
        serviceState: 'NOT_INSTALLED', agentAlive: false, guardedBy: '无人守护');
    expect(n.serviceStateText, '未安装');
    expect(n.serviceRunning, isFalse);
  });

  test('stop 之后确实不再处于守护状态', () async {
    final guard = ResidentAgentGuard.instance;
    guard.stop();
    expect(guard.isGuarding, isFalse,
        reason: 'stop 了还 report isGuarding=true，界面就会说"会话内守护"而其实没人巡检');
  });
}
