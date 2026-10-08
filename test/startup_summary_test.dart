import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 开机启动项页原来三个坑叠在一起：
/// ① `_items` 初始化成**空列表**而不是 null，于是"读失败"与"确实没有"长得一模一样——
///    界面会说「暂无可管理的开机启动项」，而那句话的意思是"查过了、没有"。
///    （这条是 `flutter analyze` 的 unnecessary_null_comparison 顺带查出来的。）
/// ② `_load()` 两个 await 都没接异常，一抛就整页空白，**连一句解释都没有**。
/// ③ 没有任何汇总：十几条启动项摆在那儿，用户不知道能关几条。
///
/// 钉住的是"读不到 ≠ 没有"这条线，以及汇总只报实测数。
void main() {
  StartupItem item(String name, bool enabled) =>
      StartupItem(name: name, location: 'HKCU', enabled: enabled);

  test('没读到（null）不报"共 0 个"——那是拿没查过的结果当结论', () {
    expect(startupSummaryText(null), isNull);
  });

  test('读到了但是空的，如实说 0 个', () {
    expect(startupSummaryText(const []), '共 0 个启动项，0 个已启用');
  });

  test('汇总按实测数：总数与已启用数', () {
    final s = startupSummaryText([
      item('a', true),
      item('b', true),
      item('c', false),
    ]);
    expect(s, contains('共 3 个启动项'));
    expect(s, contains('2 个已启用'));
  });

  test('有可关的项时才摆收益说明（自带「减少开机启动项可以提升开机速度」:61）', () {
    final some = startupSummaryText([item('a', true), item('b', false)]);
    expect(some, contains('减少开机启动项可以提升开机速度'));

    // 全都开着时说什么都像在劝用户做没用的事
    final all = startupSummaryText([item('a', true), item('b', true)]);
    expect(all, isNot(contains('减少开机启动项')));
    expect(all, '共 2 个启动项，2 个已启用');
  });

  test('空列表不带收益说明——没有东西可关', () {
    expect(startupSummaryText(const []), isNot(contains('减少开机启动项')));
  });

  testWidgets('读失败：明说失败 + 给「重新加载」，不说「暂无可管理的启动项」', (tester) async {
    // 这一支**不用注入就能测到**：测试环境没有 RustLib，`readStartupList()` 抛错，
    // 走的就是"读失败"那条路（与存储感知那条同一个道理）。
    // 原来它画 `SizedBox.shrink()`：整页空白 + 一条会自己消失的 snackbar，
    // 于是"读失败"看起来像"这台机器什么都没有"，而且没有任何可做的动作。
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: StartupManagePage())),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('获取开机启动项出错'), findsOneWidget);
    expect(find.text('暂无可管理的开机启动项'), findsNothing,
        reason: '没查到 ≠ 没有：那句是"查过了，确实没有"的意思');
    final retry = find.widgetWithText(TextButton, '重新加载');
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull,
        reason: '挂着按钮却点不动＝假 affordance');
  });
}
