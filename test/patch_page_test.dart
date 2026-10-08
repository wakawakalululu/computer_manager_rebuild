import 'dart:async';

import 'package:computer_manager/pages/tool_box_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 补丁页的两处措辞，都取参考实现文案表自带的说法：
/// 行内动作与它的确认框标题同一个词「卸载补丁」(:172)，空态是「暂无更新」(:430)。
///
/// 列表走 `patches` 注入而不是真桥：本机必然有已装补丁，"一条都没有"那一支
/// 真机上根本走不到，只能注入才测得到。
void main() {
  Future<void> pumpPage(WidgetTester tester, List<PatchEntry> patches) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) =>
                Scaffold(body: PatchTestPage(patches: patches))),
      ]),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('行内动作叫「卸载补丁」，与确认框标题同一个说法（:172）', (tester) async {
    await pumpPage(tester, [
      PatchEntry(id: 'KB5034441', title: 'KB5034441', kind: 'WUSA'),
    ]);
    expect(find.text('漏洞补丁检测'), findsOneWidget);
    expect(find.text('卸载补丁'), findsOneWidget);
    // 原来只写「卸载」，与确认框标题不是一个说法
    expect(find.text('卸载'), findsNothing);
    expect(find.text('暂无更新'), findsNothing);
  });

  testWidgets('读失败时不说「暂无更新」——那是在断言机器没补丁', (tester) async {
    // 补丁有没有装正是这个页要回答的问题。读不到却摆「暂无更新」，
    // 等于拿"没查到"当"查过了、没有"。
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) =>
                const Scaffold(body: PatchTestPage(loadFailed: true))),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('补丁列表读取失败'), findsOneWidget);
    expect(find.text('暂无更新'), findsNothing);

    // 这一支原来是个**死胡同**：只说"读失败"，什么都不让用户做。
    // 「重新加载」(`zh_strings.txt:225`) 是自带说法（同族「暂无内容，请刷新试试」`:181`、
    // 已用上的「重新测速」`:135`），动作是把抽出来的 `_load()` 再跑一次。
    final retry = find.widgetWithText(TextButton, '重新加载');
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull,
        reason: '挂着按钮却点不动＝假 affordance');
    await tester.tap(retry);
    await tester.pumpAndSettle();
    // 注入的就是失败态，重读还是失败：**不能**因为点了重试就把它说成"没有补丁"
    expect(find.text('补丁列表读取失败'), findsOneWidget);
    expect(find.text('暂无更新'), findsNothing);
  });

  testWidgets('一条补丁都没有时给空态，不留一张空白页（:430）', (tester) async {
    await pumpPage(tester, const []);
    expect(find.text('暂无更新'), findsOneWidget);
    expect(find.text('卸载补丁'), findsNothing);
  });

  netSpeedTests();
}

/// 网速测试页：重测按钮与结果区抬头。
/// 都取参考实现自带的说法——重测叫「重新测速」(:135)，结果区抬头是
/// 「当前网速」(:208)；「再测一次」是我们自造的。
void netSpeedTests() {
  const result = NetSpeedResult(
      rttMs: 12,
      jitterMs: 3,
      downBps: 1024 * 1024,
      upBps: 512 * 1024,
      probes: 5);

  Future<void> pump(WidgetTester tester, NetSpeedResult? r) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => Scaffold(body: NetSpeedTestPage(result: r))),
      ]),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('结果区有「当前网速」抬头，重测按钮叫「重新测速」（:208/:135）', (tester) async {
    await pump(tester, result);
    expect(find.text('当前网速'), findsOneWidget);
    expect(find.text('重新测速'), findsOneWidget);
    // 原来写「再测一次」，不是文案表里的说法
    expect(find.text('再测一次'), findsNothing);
    expect(find.text('下载速度'), findsOneWidget);
    expect(find.text('上传速度'), findsOneWidget);
  });

  testWidgets('还没测过时只给「开始测速」，不先摆一组空指标', (tester) async {
    await pump(tester, null);
    expect(find.text('开始测速'), findsOneWidget);
    expect(find.text('当前网速'), findsNothing);
    expect(find.text('重新测速'), findsNothing);
  });

  testWidgets('测速失败态给「重新测速」：点它清掉错误重新采样，第二轮出结果',
      (tester) async {
    // 这一支以前只能拔网线才看得到，所以"失败了界面上给不给出路"这件事没有用例钉着。
    // 两轮各用一个 Completer 手工放行：`pump()` 会把微任务队列排空，
    // 直接返回的 Future 会让"进行中"那一帧根本观测不到（第一版就是这么写失败的）。
    final first = Completer<NetSpeedResult>();
    final second = Completer<NetSpeedResult>();
    var calls = 0;
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NetSpeedTestPage(measure: () async {
          calls++;
          return await (calls == 1 ? first : second).future;
        }))));
    await tester.pump();
    expect(find.text('开始测速'), findsOneWidget);
    expect(find.text('重新测速'), findsNothing);

    await tester.tap(find.text('开始测速'));
    await tester.pump();
    expect(find.text('正在采样…'), findsOneWidget);

    first.completeError(Exception('探测点无响应'));
    await tester.pump();
    // 失败要明说失败，而且必须给出路（原来这一支一个按钮都没有）
    expect(find.textContaining('采样未完成：探测点无响应'), findsOneWidget);
    final retry = find.widgetWithText(TextButton, '重新测速');
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    // 第二轮进行中时，上一轮的「采样未完成」必须已经不在了——两句同时在屏上
    // 等于界面自相矛盾。
    expect(find.text('正在采样…'), findsOneWidget);
    expect(find.textContaining('采样未完成'), findsNothing);

    second.complete(const NetSpeedResult(
        rttMs: 12, jitterMs: 3, downBps: 1000, upBps: 2000, probes: 5));
    await tester.pump();
    expect(find.text('往返时延'), findsOneWidget);
    expect(calls, 2);
  });
}
