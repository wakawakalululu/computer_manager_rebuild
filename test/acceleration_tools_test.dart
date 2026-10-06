import 'package:computer_manager/services/acceleration_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「加速工具」卡的条目规则：列出来的每一条都必须真的能执行
///（原程序「隐藏不可操作项」的字面实现）。
void main() {
  test('空闲时只有「一键加速」一条，不摆没意义的条目', () {
    expect(
        accelerationTools(memoryRatio: 0.4, maxDiskRatio: 0.5).map((t) => t.id),
        ['accelerate']);
  });

  test('内存吃紧才给「查看进程」，磁盘吃紧才给「深度清理」', () {
    final tools = accelerationTools(memoryRatio: 0.93, maxDiskRatio: 0.96);
    expect(tools.map((t) => t.label), ['一键加速', '查看进程', '深度清理']);
    expect(tools[1].route, '/app_manage_dashboard/process_info');
    expect(tools[2].route, '/disk_clean_dashboard/deep_clean_scan');
  });

  test('阈值两侧：0.79/0.89 不算可操作，0.8/0.9 才算', () {
    expect(accelerationTools(memoryRatio: 0.79, maxDiskRatio: 0.89).length, 1);
    expect(accelerationTools(memoryRatio: 0.8, maxDiskRatio: 0.9).length, 3);
  });

  test('跳转条目一律带 route，就地执行的那条不带', () {
    final tools = accelerationTools(memoryRatio: 0.9, maxDiskRatio: 0.9);
    expect(tools.first.route, isNull);
    expect(
        tools.skip(1).every((t) => t.route != null && t.route!.startsWith('/')),
        isTrue);
  });

  test('没有加速能力且都不吃紧时是空列表，由界面显示空态', () {
    expect(
        accelerationTools(
            memoryRatio: 0.1, maxDiskRatio: 0.1, canAccelerate: false),
        isEmpty);
    expect(accelToolsEmptyMessage, isNotEmpty);
  });
}
