import 'package:computer_manager/services/agent_process.dart';
import 'package:computer_manager/pages/settings_page.dart';
import 'package:computer_manager/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 卡片背景不能挡掉子控件的水波纹。
///
/// `Container(decoration: BoxDecoration(...))` 不是 Material：里面的 ListTile
/// 把 ink 画在"最近的 Material 祖先"上，中间这层彩色 DecoratedBox 会盖住它，
/// 点下去一点反馈都没有。Flutter 会为此抛断言
/// "ListTile background color or ink splashes may be invisible"。
///
/// 这里按"渲染出的树里 ListTile/InkWell 与最近的 Material 之间没有别的
/// DecoratedBox"来钉住，而不是靠断言消息——断言只在特定配置下才触发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 从 [leaf] 往上找最近的 Material；返回它到 leaf 之间的 widget 类型。
  List<Type> blockersBetween(WidgetTester tester, Finder leaf) {
    final blockers = <Type>[];
    tester.element(leaf).visitAncestorElements((a) {
      if (a.widget is Material) return false; // 到了最近的 Material 就停
      if (a.widget is DecoratedBox) blockers.add(DecoratedBox);
      return true;
    });
    return blockers;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
  }

  testWidgets('PageHeader 的返回箭头有可承载涟漪的 Material', (tester) async {
    await pump(tester, PageHeader(title: 'T', onBack: () {}));
    final back = find.byIcon(Icons.arrow_back_ios);
    expect(back, findsOneWidget);
    expect(blockersBetween(tester, back), isEmpty);
  });

  testWidgets('设置页分组里的 ListTile 不被装饰层挡住水波纹', (tester) async {
    await pump(tester, const AppSettingPage(residentStatus: _noResident));
    // 设置页很长，目标行要滚到底才被构建出来
    await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    final tile = find.text('打开系统代理设置');
    expect(tile, findsOneWidget);
    expect(blockersBetween(tester, tile), isEmpty);
  });
}

/// 常驻状态注入：测试环境没有 RustLib，问真守卫会直接抛。
Future<ResidentStatus?> _noResident() async => null;
