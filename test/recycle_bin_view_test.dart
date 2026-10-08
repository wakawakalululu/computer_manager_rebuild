import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回收站卡原来只摆容量，用户没法判断「有 3 GB 可清空」里那些是不是还要留的东西——
/// 能清空、能看容量，却**看不见里面是什么**。补一个「查看」入口
/// （`crateApiDiskScanDeepCleanROpenRecycleBinFolder` + 自带文案「查看」`:451`）。
///
/// 钉的是三件事：入口在、有实测容量、**回收站为空时也照样能点**——用户点「查看」要看的
/// 是"现在到底有什么"，不是"能不能省空间"，按容量把按钮置灰等于又替用户挡了一次。
void main() {
  Future<void> pump(WidgetTester tester,
      {String size = '3.00 GB',
      void Function()? onOpen,
      void Function()? onEmpty}) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: RecycleBinCard(
        loadSize: () async => size,
        openFolder: () async => onOpen?.call(),
        emptyBin: () async => onEmpty?.call(),
      ),
    )));
    await tester.pumpAndSettle();
  }

  TextButton viewButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, '查看'));

  testWidgets('读不到容量时不摆"0.00 B"，只写「回收站」', (tester) async {
    // 空串 = 没读到，与实测到的 "0.00 B"（回收站确实是空的）**是两件事**。
    // 原来两者都摆成空，于是"读失败"看起来像"回收站是空的"。
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: RecycleBinCard(loadSize: () async => throw StateError('读不到')),
    )));
    await tester.pumpAndSettle();

    expect(find.text('回收站'), findsOneWidget);
    expect(find.textContaining('0.00 B'), findsNothing);
  });

  testWidgets('卡上摆的是实测容量', (tester) async {
    await pump(tester, size: '3.00 GB');
    expect(find.textContaining('回收站'), findsOneWidget);
    expect(find.textContaining('3.00 GB'), findsOneWidget);
  });

  testWidgets('有「查看」入口，点得动', (tester) async {
    var opened = 0;
    await pump(tester, onOpen: () => opened++);

    expect(find.text('查看'), findsOneWidget);
    expect(viewButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(opened, 1, reason: '点了「查看」就该真的去打开回收站');
  });

  testWidgets('回收站是空的也照样能查看', (tester) async {
    var opened = 0;
    await pump(tester, size: '0.00 B', onOpen: () => opened++);

    expect(viewButton(tester).onPressed, isNotNull,
        reason: '空回收站时也应该能点开确认现在到底有什么');
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('打开失败要回报，而不是静悄悄', (tester) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: RecycleBinCard(
        loadSize: () async => '0.00 B',
        openFolder: () async => throw StateError('boom'),
      ),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.textContaining('打开回收站失败'), findsOneWidget);
  });

  testWidgets('清空之后容量要跟着刷新', (tester) async {
    var size = '3.00 GB';
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: RecycleBinCard(
        loadSize: () async => size,
        emptyBin: () async => size = '0.00 B',
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('3.00 GB'), findsOneWidget);

    await tester.tap(find.text('一键清理'));
    await tester.pumpAndSettle();
    // 确认框用的是参考实现自带的「确定要清空回收站吗？」，按钮是「确定」
    expect(find.text('确定要清空回收站吗？'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3.00 GB'), findsNothing);
    expect(find.textContaining('0.00 B'), findsOneWidget);
  });
}
