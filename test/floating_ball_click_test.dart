import 'dart:convert';

import 'package:computer_manager/services/click_report.dart';
import 'package:computer_manager/services/feedback_service.dart';
import 'package:computer_manager/windows/floating_window.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 悬浮球 = 参考实现的「加速球」：实时看内存占用，点一下释放内存。
/// 单独成文件：`TestWidgetsFlutterBinding` 会接管 HttpClient（所有真实请求一律回
/// 400），真 socket 的上测与 widget 测试放一起必然互相打架。
void main() {
  ClickReporter recorder(List<String> sent) => ClickReporter(
        resolveTarget: () async =>
            FeedbackTarget(baseHost: 'http://gateway.invalid', machineId: 'M'),
        send: (uri, body) async {
          sent.add(uri.path);
          sent.add((jsonDecode(body) as Map)['event'] as String);
        },
        onError: (_) {},
      );

  Future<void> pumpBall(WidgetTester tester,
      {required Future<int> Function() accelerate,
      required Future<void> Function() hide,
      Future<void> Function(FloatingData)? openCard,
      FloatingData? data}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FloatingWindowBody(
            data: data ?? FloatingData.placeholder(),
            accelerate: accelerate,
            hide: hide,
            openCard: openCard),
      ),
    ));
  }

  testWidgets('点球上报 click_ball 并释放内存，球上回一句「加速完成」', (tester) async {
    final sent = <String>[];
    final prev = defaultClickReporter;
    defaultClickReporter = recorder(sent);
    addTearDown(() => defaultClickReporter = prev);

    var calls = 0;
    await pumpBall(tester, accelerate: () async => ++calls, hide: () async {});
    await tester.tap(find.byType(FloatingWindowBody));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls, 1, reason: '点球应当真的去释放内存');
    expect(sent, ['/report/click/count', 'click_ball']);
    expect(find.text('加速完成'), findsOneWidget);

    // 提示两秒后自己收回去，球回到占用读数
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('加速完成'), findsNothing);
  });

  testWidgets('释放失败在球上说实话，不假装加速完成', (tester) async {
    final prev = defaultClickReporter;
    defaultClickReporter = recorder(<String>[]);
    addTearDown(() => defaultClickReporter = prev);

    await pumpBall(tester,
        accelerate: () async => throw Exception('SetProcessWorkingSetSize 失败'),
        hide: () async {});
    await tester.tap(find.byType(FloatingWindowBody));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('内存优化错误！'), findsOneWidget); // zh_strings.txt:305
    expect(find.text('加速完成'), findsNothing);
  });

  testWidgets('右键关球把动作交给宿主，且期间不重复触发加速', (tester) async {
    final prev = defaultClickReporter;
    defaultClickReporter = recorder(<String>[]);
    addTearDown(() => defaultClickReporter = prev);

    var accelerated = 0, hid = 0;
    await pumpBall(tester,
        accelerate: () async => ++accelerated, hide: () async => ++hid);
    await tester.tap(find.byType(FloatingWindowBody),
        buttons: kSecondaryButton);
    await tester.pump();

    expect(hid, 1);
    expect(accelerated, 0, reason: '右键只做关球');
  });

  testWidgets('长按把开卡请求交给宿主，顺带带上当前占用数据', (tester) async {
    FloatingData? handed;
    var accelerated = 0;
    final data = FloatingData.placeholder()
      ..update(
          usedMemory: 930, totalMemory: 1000, cpuUsage: 30, maxDiskRatio: 0.96);
    await pumpBall(tester,
        data: data,
        accelerate: () async => ++accelerated,
        hide: () async {},
        openCard: (d) async => handed = d);
    await tester.longPress(find.byType(FloatingWindowBody));
    await tester.pump();

    // 球自己不再画列表（卡片是另一个子窗口），但要把算得动条目用的数据交出去
    expect(find.text('加速工具'), findsNothing);
    expect(handed, same(data));
    expect(handed!.maxDisk.value, 0.96);
    expect(accelerated, 0, reason: '长按只开卡，不重复触发加速');
  });
}
