import 'package:computer_manager/pages/dashboard_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页概览分的算法判据。
///
/// ⚠ 先说清性质：**「设备健康评分」这个概念与权重都是我们自己的**——
/// 参考实现的材料里没有"评分/健康"（`zh_strings.txt` 搜「评分」零命中、
/// 「健康」只在法律条款里、classes/click_events/frb_calls 搜 score·health·rating
/// 全为空）。所以这台测的不是"和它算得一样"，而是**我们自己这个数别自相矛盾**。
/// 最要命的一条是下面那条"盘数无关"：原先逐张累加，分数由系统报几张卷决定。
void main() {
  group('盘数无关（这条是修过的真缺陷）', () {
    test('同样的使用率，插 4 张盘和 1 张盘必须是同一个分', () {
      // 旧实现：`for (d in disks) s -= ratio*10` ⇒ 四张 80% 的盘扣 32 分，
      // 一张 80% 的盘只扣 8 分——差的 24 分跟机器健康毫无关系。
      final one = healthScore(diskRatios: [0.8]);
      final four = healthScore(diskRatios: [0.8, 0.8, 0.8, 0.8]);
      expect(four, one, reason: '磁盘按"最紧的一张"算，不是逐张累加；否则分数随卷数漂移');
    });

    test('多张盘里只按最紧的那张扣，其余不叠加', () {
      expect(healthScore(diskRatios: [0.1, 0.2, 0.9]),
          healthScore(diskRatios: [0.9]));
    });

    test('没有盘读数时不扣分', () {
      expect(healthScore(diskRatios: const []), 100);
    });
  });

  group('读不到 ≠ 零占用', () {
    // 把"没读到"当 0 参与计算，等于凭空发分——本项目一路在清的就是这一族。
    // 这里要求：读不到的那一项**不进入扣分**，因此分只会比"读到了并且很高"时低或持平，
    // 而不是比它高。
    test('CPU 读不到时不扣 CPU 分（而不是按 0% 算）', () {
      expect(healthScore(cpuUsage: null), 100);
      expect(healthScore(cpuUsage: 100), lessThan(100));
    });

    test('内存读不到时不扣内存分', () {
      expect(healthScore(memRatio: null), 100);
      expect(healthScore(memRatio: 1.0), lessThan(100));
    });

    test('全读不到 = 100（没证据就不扣分），而不是 0', () {
      expect(healthScore(), 100);
    });
  });

  group('边界与单调', () {
    test('最满的机器也不给 0 分：下限夹在 5', () {
      // CPU 100% + 内存 100% + 盘 100% ⇒ 100-25-20-10 = 45
      // 下限是为"什么都不给一个零"留的，不是为真实读数留的；仍要钉住不越界。
      expect(healthScore(cpuUsage: 100, memRatio: 1.0, diskRatios: [1.0]), 45);
      expect(healthScore(cpuUsage: 400, memRatio: 4.0, diskRatios: [4.0]),
          greaterThanOrEqualTo(5));
    });

    test('干净机器给满分', () {
      expect(healthScore(cpuUsage: 0, memRatio: 0, diskRatios: [0]), 100);
    });

    test('三项各自越满分越低（单调，别出现反向）', () {
      expect(healthScore(cpuUsage: 10), greaterThan(healthScore(cpuUsage: 80)));
      expect(
          healthScore(memRatio: 0.1), greaterThan(healthScore(memRatio: 0.9)));
      expect(healthScore(diskRatios: [0.1]),
          greaterThan(healthScore(diskRatios: [0.9])));
    });
  });
}
