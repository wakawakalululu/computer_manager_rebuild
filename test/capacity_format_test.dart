import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 容量那一栏原来写的是 `bytes >> 30`：整除。一张 500 MB 的盘会显示成「0G」——
/// 比不显示更糟，用户以为盘是空的。三个标签（总容量/已用容量/剩余容量）逐字
/// 取自参考实现自带文案 `:449`/`:113`/`:109`。
void main() {
  DiskInfo disk(int total, int free) =>
      DiskInfo(letter: 'C', total: total, free: free);

  test('不足 1G 的盘不会被整除成 0G', () {
    expect(formatCapacity(500 * 1024 * 1024), '500.0M');
    expect(formatCapacity(999 * 1024 * 1024), '999.0M');
  });

  test('0 与负数不报成怪值', () {
    expect(formatCapacity(0), '0 B');
    expect(formatCapacity(-1), '0 B');
  });

  test('GB 保留一位小数', () {
    expect(formatCapacity(1024 * 1024 * 1024), '1.0G');
    expect(formatCapacity(100 * 1024 * 1024 * 1024), '100.0G');
  });

  test('明细三个标签齐全，且用的都是实测值', () {
    final s = diskCapacityDetail(
        disk(100 * 1024 * 1024 * 1024, 40 * 1024 * 1024 * 1024));
    expect(s, contains('总容量'));
    expect(s, contains('已用容量'));
    expect(s, contains('剩余容量'));
    expect(s, contains('100.0G'));
    expect(s, contains('60.0G'));
    expect(s, contains('40.0G'));
  });

  test('汇总行不再出现整除出来的 0G', () {
    final s = storageSummaryText([disk(500 * 1024 * 1024, 100 * 1024 * 1024)]);
    expect(s, isNot(contains('0G')));
    expect(s, contains('500.0M'));
  });

  test('一张盘都没有时报未检测到磁盘，不报 0G / 0G', () {
    expect(storageSummaryText([]), '未检测到磁盘');
  });

  testWidgets('盘列表读不到：卡片明说「检查磁盘容量出错」并给「重新加载」，不是静默消失', (tester) async {
    // 测试环境没有 RustLib → `getDiskInfoList()` 抛 → 走的就是失败那一支，不用注入。
    // 原来这一支 `SizedBox.shrink()`：整张卡静默消失，界面上看不出"读失败"与
    // "还没读到"的差别，也没有任何再试一次的动作。
    // ⚠ 失败时**仍不能**画「未检测到磁盘」——那句是"查过了、一个盘都没有"，
    //    上面那条纯函数用例钉的就是它只该给空列表。
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Column(children: [StorageHeaderCard()]))));
    await tester.pumpAndSettle();

    expect(find.text('检查磁盘容量出错'), findsOneWidget);
    expect(find.text('未检测到磁盘'), findsNothing, reason: '没查到 ≠ 一个盘都没有');
    expect(find.text('存储空间管理'), findsNothing, reason: '容量都没读到还摆一张标题卡，更容易被当成故障');
    final retry = find.widgetWithText(TextButton, '重新加载');
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull,
        reason: '挂着按钮却点不动＝假 affordance');
  });
}
