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

  testWidgets('点球上报 click_ball 并释放内存，球上回报释放了几个进程', (tester) async {
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
    // 「加速完成」只说明"做完了"，不说明**做了什么**——修剪了几个进程是唯一的证据。
    // 「加速球耗时」`:127` 是自带的说法，两者一起摆出来。
    expect(find.textContaining('1 进程'), findsOneWidget);
    expect(find.textContaining('耗时'), findsOneWidget);

    // 提示两秒后自己收回去，球回到占用读数
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('耗时'), findsNothing);
  });

  testWidgets('一个进程都没释放时不谎报"释放 0 个"，只报耗时', (tester) async {
    final prev = defaultClickReporter;
    defaultClickReporter = recorder(<String>[]);
    addTearDown(() => defaultClickReporter = prev);

    await pumpBall(tester, accelerate: () async => 0, hide: () async {});
    await tester.tap(find.byType(FloatingWindowBody));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('释放 0'), findsNothing);
    expect(find.textContaining('耗时'), findsOneWidget);
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
    expect(find.textContaining('耗时'), findsNothing);
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

  testWidgets('球上只给百分比，且必须由真实字节算出来（不是整除出来的 0）',
      (tester) async {
    // 这条原来是钉「0G / 0G」的：`>> 30` 整除会把 512 MB 写成 0G，而球面**常驻可见**，
    // 写错一眼就看到。2026-10-08 按实机取证把球改成"只显示内存百分比"（#106），
    // GB 行没了 ⇒ 判据**迁到百分比上**而不是删掉：512/768 必须算出 67%，
    // 且任何时候都不许出现 0%（0% 是"一条都没占"这个假结论，和当年的 0G 同一类错）。
    final data = FloatingData.placeholder()
      ..update(
          usedMemory: 512 * 1024 * 1024,
          totalMemory: 768 * 1024 * 1024,
          cpuUsage: 12);
    await pumpBall(tester,
        data: data, accelerate: () async => 1, hide: () async {});

    expect(find.textContaining('0G', findRichText: true), findsNothing);
    expect(find.textContaining('67', findRichText: true), findsOneWidget);
    expect(find.textContaining('0%', findRichText: true), findsNothing);
  });

  testWidgets('正常大小的内存同样折算成百分比（8G/16G → 50%）', (tester) async {
    final data = FloatingData.placeholder()
      ..update(
          usedMemory: 8 * 1024 * 1024 * 1024,
          totalMemory: 16 * 1024 * 1024 * 1024,
          cpuUsage: 40);
    await pumpBall(tester,
        data: data, accelerate: () async => 1, hide: () async {});

    expect(find.textContaining('50', findRichText: true), findsOneWidget);
  });

  testWidgets('还没收到数据时给「--」，不摆 0% 这个假结论', (tester) async {
    await pumpBall(tester, accelerate: () async => 1, hide: () async {});

    expect(find.text('--'), findsOneWidget);
    expect(find.textContaining('0%', findRichText: true), findsNothing);
  });

  testWidgets('水的高度必须等于内存占用比（钉住关系，不是钉住某个像素值）',
      (tester) async {
    // #106 把球改成"从底部填到 ratio 高度的水"。文字读数已有用例钉住，
    // 但**形状与比例**没有——那才是这条改动的全部风险所在：
    // 谁把 86 改成别的数、或把 ratio 写成 used/total 之外的口径，界面照样"看着像球"。
    // 所以这里钉的是**关系**：水高 / 球高 == 占用比。
    // ⚠ 这条钉的是"我们自己的实现遵守这个关系"，不等于"参考实现的水位就跟占用比走"——
    //   后者仍未定死（三次取证都是 51%），见 #106。
    double waterHeight(WidgetTester t) {
      final positioned = t
          .widgetList<Positioned>(find.byType(Positioned))
          .where((p) => p.bottom == 0 && p.left == 0 && p.right == 0);
      expect(positioned, isNotEmpty,
          reason: '找不到那层水：球的填充不再是"贴底的一条"了');
      return positioned.first.height!.toDouble();
    }

    Future<void> pumpWith(WidgetTester t, int used, int total) async {
      final data = FloatingData.placeholder()
        ..update(usedMemory: used, totalMemory: total, cpuUsage: 20);
      await pumpBall(t,
          data: data, accelerate: () async => 1, hide: () async {});
    }

    final g = 1 << 30;
    await pumpWith(tester, 2 * g, 8 * g);
    expect(waterHeight(tester) / 86.0, closeTo(0.25, 0.001));

    await pumpWith(tester, 8 * g, 8 * g);
    expect(waterHeight(tester) / 86.0, closeTo(1.0, 0.001));
    // 满占用时读数最长（三位数 + %），这一档最容易撑爆
    expect(tester.takeException(), isNull);

    await pumpWith(tester, 7 * g, 8 * g);
    expect(waterHeight(tester) / 86.0, closeTo(0.875, 0.001));
  });
}
