import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「开机启动耗时」的显示口径（数据源见 `rust/src/api/sysinfo.rs` 的 get_boot_time_ms）。
///
/// 这条用例存在的理由很具体：第一版直接复用了 [formatDuration]，
/// 于是本机实测的 32016ms 在界面上写成「开机启动耗时 不足 1 分钟」——
/// 数字没错，但这一行唯一要传达的量（多少秒）被抹平了。
/// [formatDuration] 是为运行时长（小时/天）写的，两者不能共用一个格式化器。
void main() {
  test('秒级耗时保留到 0.1 秒，不塌成「不足 1 分钟」', () {
    expect(formatBootDuration(32016), '32.0 秒');
    expect(formatBootDuration(999), '999 毫秒');
    expect(formatBootDuration(1000), '1.0 秒');
    expect(formatBootDuration(59949), '59.9 秒');
  });

  test('过了一分钟就换成「分 + 秒」，且不留无意义的 0 秒', () {
    expect(formatBootDuration(60000), '1 分钟');
    expect(formatBootDuration(95000), '1 分 35 秒');
    expect(formatBootDuration(121000), '2 分 1 秒');
  });

  test('负数不写出「-5 毫秒」这种看着像结论的垃圾', () {
    expect(formatBootDuration(-1), '0 毫秒');
  });

  test('对照：同一个数交给 formatDuration 会丢掉秒数', () {
    // 这条把"为什么需要两个函数"钉在测试里，避免以后有人"顺手合并一下"
    expect(formatDuration(32016), '不足 1 分钟');
    expect(formatBootDuration(32016), isNot(formatDuration(32016)));
  });

  group('页头副标题：两件事分开说，缺哪个就少一句', () {
    test('两个都有 → 各自成句，用 · 分隔', () {
      expect(
          StartupManagePage.headerSubtitle(
              startupMs: 32016, bootMs: 54331500),
          '开机启动耗时 32.0 秒 · 已开机 15 小时 5 分钟');
    });

    test('读不到启动耗时（null 或 0）→ 这一句整个不出现，运行时长照说', () {
      expect(
          StartupManagePage.headerSubtitle(startupMs: null, bootMs: 54331500),
          '已开机 15 小时 5 分钟');
      expect(
          StartupManagePage.headerSubtitle(startupMs: 0, bootMs: 54331500),
          isNot(contains('开机启动耗时')));
    });

    test('⚠ 绝不拿运行时长冒充启动耗时——这是 #100 存在的全部理由', () {
      // 只有 bootMs 有值、而且那个值恰好等于启动耗时的那个 32016：
      // 如果谁图省事把两个量并成一个参数，这条就会红。
      final s = StartupManagePage.headerSubtitle(startupMs: null, bootMs: 32016);
      expect(s, isNot(contains('开机启动耗时')));
      expect(s, '已开机 不足 1 分钟');
    });

    test('两个都读不到 → 返回 null，不是空串（空串会在页头留一行空白）', () {
      expect(StartupManagePage.headerSubtitle(startupMs: null, bootMs: 0), isNull);
      expect(StartupManagePage.headerSubtitle(startupMs: 0, bootMs: 0), isNull);
    });
  });
}
