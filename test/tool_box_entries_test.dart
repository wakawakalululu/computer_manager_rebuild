import 'package:computer_manager/pages/tool_box_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工具箱那张清单：五张卡都得**点得动**，标题用参考实现自己的词。
///
/// 判据来源：
///  * 「外设检测」`docs/extracted/zh_strings.txt:478`、「智慧盘」`:140`、
///    「漏洞补丁检测」`:223`、「应用中心」`:596`（说明 `:486`）—— 这几张卡的标题是自带的。
///  * 「设备检测」在文案表里**零命中**，原来那张卡却写着它、而且 `onTap` 是 null：
///    卡上挂着"检测"两个字、点了什么都不发生——典型的假 affordance。
///
/// ⚠ **这台测的是"有没有去处"，不是"跳到哪一页"**：`EntryCard` 只在
/// `onTap != null` 时画那个「>」，所以四个箭头就等于四张卡都挂了回调。
/// 回调里 `context.go` 的目标对不对，得看 `lib/core/routes.dart` 那张表——
/// 那一层没并进这台测试：真 `buildRouter()` 的初始页会去加载 Rust 桥（要 dll），
/// 而临时搭的桩路由表在 widget 测试里起不来（实测两处异常，未深究）。
/// 每条跳转目标都写在 `tool_box_page.dart` 的注释里，可逐条对着路由表核。
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ToolBoxDashboardPage())));
    await tester.pump();
  }

  testWidgets('五张卡的标题都用参考实现自带的词', (tester) async {
    await pump(tester);
    expect(find.text('网速测试'), findsOneWidget);
    expect(find.text('漏洞补丁检测'), findsOneWidget); // :223
    expect(find.text('外设检测'), findsOneWidget); // :478
    expect(find.text('智慧盘'), findsOneWidget); // :140
    expect(find.text('应用中心'), findsOneWidget); // :596
    // 「设备检测」不是它的说法——文案表里搜不到这个词
    expect(find.text('设备检测'), findsNothing);
  });

  testWidgets('工具箱没有"点了什么都不发生"的卡', (tester) async {
    await pump(tester);
    // 「>」只在有 onTap 时才画：五张卡就该有五个，少一个说明那张是死的。
    // （从 4 改到 5 是因为加了「应用中心」这张真挂了回调的卡——
    //   这条判据问的是"每张卡都有去处"，卡数变了它就该跟着变，
    //   而不是把新卡藏起来让它继续绿。）
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(5));
  });
}
