import 'package:computer_manager/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 窗口尺寸按实测屏幕算，不写死。
///
/// 原来恒定 1020×700：在本机（屏幕 1802×1013）没问题，但 1366×768 那类
/// 小屏上标题栏 + 700 高就放不下，底部被切——而那正是参考实现去问
/// `GetSystemMetrics` 的原因（`GetMonitorSize` 与 `GetMonitorWorkSize`）。
void main() {
  test('小屏：屏幕比期望尺寸还矮时，取屏幕本身而不是溢出', () {
    // 1366×768 是云电脑/老笔记本常见分辨率
    final s = windowSizeForScreen(screen: const Size(1366, 768));
    expect(s.height, lessThanOrEqualTo(768));
    expect(s.width, lessThanOrEqualTo(1366));
  });

  test('更极端的小屏（1024×600）也不能超出屏幕', () {
    final s = windowSizeForScreen(screen: const Size(1024, 600));
    expect(s.width, lessThanOrEqualTo(1024));
    expect(s.height, lessThanOrEqualTo(600));
  });

  test('大屏：保持期望尺寸，不因为屏幕大就拉伸界面', () {
    // 之前想的是"撑满 88%"，那是反的：屏幕大就该保持设计尺寸，拉伸只会让
    // 字号和留白在大屏上显得稀。屏幕小才往下收。
    final s = windowSizeForScreen(screen: const Size(2560, 1440));
    expect(s.width, 1020);
    expect(s.height, 700);
  });

  test('preferred 与 minSize 都超过屏幕时按比例取，绝不越界', () {
    final s = windowSizeForScreen(screen: const Size(640, 480));
    expect(s.width, lessThanOrEqualTo(640));
    expect(s.height, lessThanOrEqualTo(480));
  });

  test('常规屏：保持原来的期望尺寸，不因为规则而变形', () {
    final s = windowSizeForScreen(screen: const Size(1802, 1013));
    expect(s.width, 1020);
    expect(s.height, 700);
  });

  test('极小屏兜底：不小于 640×480 之外的部分由 clamp 保证不越界', () {
    final s = windowSizeForScreen(screen: const Size(320, 240));
    expect(s.width, lessThanOrEqualTo(320));
    expect(s.height, lessThanOrEqualTo(240));
  });

  // 取尺寸的优先级：工作区（已扣掉任务栏的那一片）> 主屏 > 兜底。
  // 排错的后果不是"难看"，而是窗口底边压回任务栏上，所以这条顺序本身要钉住。
  group('屏幕来源优先级', () {
    test('两个都取到时用工作区，不用主屏', () {
      final picked = pickScreenSize(
        workArea: const Size(1920, 1040), // 主屏 1920 减去贴底任务栏
        primary: const Size(1920, 1080),
      );
      expect(picked, const Size(1920, 1040));
    });

    test('工作区读不到（null）时退回主屏', () {
      expect(
        pickScreenSize(primary: const Size(1366, 768)),
        const Size(1366, 768),
      );
    });

    // 系统返回了 0 宽高不是"有一块 0×0 的屏"，而是没取到；当成有效值会让
    // windowSizeForScreen 拿 0 当硬上限，窗口被压成 0×0。
    test('工作区为 0×0 视同没取到，退回主屏', () {
      expect(
        pickScreenSize(
            workArea: const Size(0, 0), primary: const Size(1366, 768)),
        const Size(1366, 768),
      );
    });

    test('负宽高同样视同没取到', () {
      expect(
        pickScreenSize(
            workArea: const Size(-1920, -1040), primary: const Size(800, 600)),
        const Size(800, 600),
      );
    });

    test('两个都没有时用兜底，不返回 null', () {
      expect(pickScreenSize(fallback: const Size(1020, 700)),
          const Size(1020, 700));
      expect(pickScreenSize(), isNull);
    });
  });
}
