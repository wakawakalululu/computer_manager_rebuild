import 'package:computer_manager/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 关于页的两处"不许说谎"：
/// - 「检测更新」**不能**在没联网查过版本时报「当前已是最新版本」(:514)；
/// - 协议入口染成主题蓝像个能点的链接，实际没有 onTap，也不能抄原厂协议正文。
void main() {
  Future<void> pumpAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) =>
                const Scaffold(body: AppAboutPage(version: 'v1.0.0'))),
      ]),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('没真查过版本，就不报「当前已是最新版本」', (tester) async {
    await pumpAbout(tester);
    await tester.tap(find.text('检测更新'));
    await tester.pumpAndSettle();

    // 参考实现敢这么写是因为它真去比对了；我们没有比对，就不能这么说
    expect(find.text('当前已是最新版本'), findsNothing);
    expect(find.textContaining('无法检测'), findsOneWidget);
    expect(find.textContaining('本地版本 v1.0.0'), findsOneWidget);
  });

  testWidgets('协议那行不再是点不动的假链接', (tester) async {
    await pumpAbout(tester);
    final link = find.textContaining('用户协议');
    expect(link, findsOneWidget);
    expect(find.text('用户协议 · 隐私政策'), findsNothing);
    final text = tester.widget<Text>(link);
    // 主题蓝 = 看着可点；没有 onTap 的蓝色入口就是骗人的 affordance
    expect(text.style?.color, isNot(const Color(0xFF1A73E8)));
  });

  test('更新检查正文：镜像版本有就报、没有就不编；始终说清远程源没接', () {
    final withImage =
        updateCheckText(localVersion: 'v1.0', imageVersion: 'v1.2.3');
    expect(withImage, contains('本地版本 v1.0'));
    expect(withImage, contains('v1.2.3'));
    expect(withImage, contains('尚未接入'));

    // 没装镜像包就不提这茬（不写"镜像版本：无"这种占位）
    final noImage = updateCheckText(localVersion: 'v1.0');
    expect(noImage, isNot(contains('镜像')));
    expect(noImage, contains('尚未接入'));

    // 关键：不能说"已是最新"——没接远程源就比不出结论
    expect(withImage, isNot(contains('已是最新')));
  });
}
