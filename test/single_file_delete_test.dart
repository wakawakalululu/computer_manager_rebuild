import 'dart:async';

import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/services/running_tasks.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只读的扫描页（系统盘文件）原来**一行一个都动不了**：没有底部按钮，也没有行内动作。
/// 扫出来的东西看得见、点得开（打开所在位置），却删不掉——那是"扫出来的一大堆文件"
/// 除了看之外唯一的处理方式。
///
/// 逐条删走 `crateApiDiskScanDiskToolsRDeleteSingleFile`，按钮文案用自带的
/// 「删除文件」`:593`；确认框用「准备删除全部」`:483` +「个文件将被删除。」`:556`。
/// 钉住的三件事：行内有入口、**报的是文件数不是行数**（一行常代表一组文件，
/// 确认框里少报是要删用户东西的场合最不能出的错）、失败要逐条点名。
void main() {
  setUp(RunningTasks.instance.reset);

  Future<void> pumpScan(WidgetTester tester, List<CleanItem> items) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = StreamController<List<CleanItem>>();
    addTearDown(c.close);
    c.add(items);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanPageScaffold(
          title: '系统盘文件',
          subtitle: '测试',
          scan: () => c.stream,
          cancelKey: 'test_sysdisk',
          actionLabel: '系统盘文件',
          readOnly: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  test('一行代表一组文件时，确认框报的是文件数而不是行数', () {
    final item = CleanItem(
      path: '旧版安装包（3 个文件）',
      size: 120,
      paths: ['C:\\a.exe', 'C:\\b.exe', 'C:\\c.exe'],
    );
    // 这一条就是确认框里"将删除 N 个"的来源；用行数（1）就是少报
    expect(pathsOf(item).length, 3);
    expect(fileCountOf([item]), 3);
  });

  test('paths 为空的单文件行，按 1 个算', () {
    final item = CleanItem(path: 'C:\\single.log', size: 1);
    expect(pathsOf(item).length, 1);
    expect(fileCountOf([item]), 1);
  });

  testWidgets('只读扫描页每行都有「删除文件」入口', (tester) async {
    await pumpScan(tester, [
      CleanItem(path: 'C:\\tmp\\a.log', size: 3),
    ]);

    expect(find.byTooltip('删除文件'), findsOneWidget);
  });

  testWidgets('可勾选的扫描页不出现行内删除（走底部批量按钮）', (tester) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = StreamController<List<CleanItem>>();
    addTearDown(c.close);
    c.add([CleanItem(path: 'C:\\tmp\\a.log', size: 3)]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanPageScaffold(
          title: '大文件',
          subtitle: '测试',
          scan: () => c.stream,
          cancelKey: 'test_large',
          actionLabel: '删除大文件',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 批量页已经有底部按钮了，再加行内删除就是两套删法，容易让人删错范围
    expect(find.byTooltip('删除文件'), findsNothing);
  });

  testWidgets('扫出来本来就没有 → 「暂无可清理项」', (tester) async {
    await pumpScan(tester, const []);

    expect(find.text('暂无可清理项'), findsOneWidget);
    expect(find.text('系统盘清理已完成！'), findsNothing);
  });

  testWidgets('给页面配了 doneLabel 时，清完的空列表说"完成"', (tester) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = StreamController<List<CleanItem>>();
    addTearDown(c.close);
    c.add(const []);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanPageScaffold(
          title: '系统盘文件',
          subtitle: '测试',
          scan: () => c.stream,
          cancelKey: 'test_done',
          actionLabel: '系统盘文件',
          readOnly: true,
          doneLabel: '系统盘清理已完成！',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 扫描态没给过任何"完成"信号，就还是"本来就没有"——两者不能混
    expect(find.text('暂无可清理项'), findsOneWidget);
    expect(find.text('系统盘清理已完成！'), findsNothing);
  });
}
