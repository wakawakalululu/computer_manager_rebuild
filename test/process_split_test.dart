import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进程页按「可优化 / 进行中」两段分组（参考实现自带这两个标题：
/// `进程可优化`:481 / `进行中进程`:197），而不是一坨平铺。
void main() {
  ProcInfo p(String name, {double cpu = 0, int memMb = 0}) =>
      ProcInfo(pid: 1, name: name, exe: '', cpu: cpu, mem: memMb);

  // 8GB 机器；阈值 0.8 → 内存 ≥ 6400MB 或 CPU ≥ 80% 算"可优化"
  const total = 8192;

  test('占大头的进「可优化」，其余进「进行中」', () {
    final procs = [
      p('huge', memMb: 7000),
      p('busy', cpu: 90),
      p('idle', memMb: 50),
    ];
    final (opt, run) = splitByImpact(procs, totalMemMb: total);
    expect(opt.map((e) => e.name), containsAll(['huge', 'busy']));
    expect(opt, isNot(contains(p('idle'))));
    expect(run.map((e) => e.name), ['idle']);
  });

  test('两段内部按占用排序：先看最吃资源的', () {
    final (opt, _) = splitByImpact(
        [p('a', cpu: 81), p('b', cpu: 99), p('c', cpu: 85)],
        totalMemMb: total);
    expect(opt.map((e) => e.name), ['b', 'c', 'a']);
  });

  test('拿不到内存总量就不分组——宁可不给，不给错', () {
    final procs = [p('a', cpu: 10)];
    final (opt, run) = splitByImpact(procs, totalMemMb: 0);
    expect(opt, isEmpty);
    expect(run.length, 1, reason: '总量为 0 时退回平铺，条目一条不能少');
  });

  test('一个进程只出现在一段里，不重复', () {
    final procs = [p('a', cpu: 99, memMb: 7000), p('b', cpu: 1, memMb: 1)];
    final (opt, run) = splitByImpact(procs, totalMemMb: total);
    final all = [...opt, ...run].map((e) => e.name).toList();
    expect(all.toSet().length, all.length);
    expect(all.length, procs.length);
  });
}
