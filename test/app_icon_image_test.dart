import 'dart:typed_data';

import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AppIconImage 的两条路径：有像素就解码成 RawImage，取不到就回落成占位 Icon。
/// loader 注入假像素，整条链路不依赖 frb 桥与真实注册表。
AppIcon _blueSquare(int w, int h) => AppIcon(
    width: w,
    height: h,
    rgba: Uint8List.fromList(List<int>.generate(
        w * h * 4, (i) => i % 4 == 3 ? 255 : (i % 4 == 2 ? 255 : 0))));

void main() {
  testWidgets('解出 RGBA 后用 RawImage 画图标', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AppIconImage(
                  displayIcon: 'C:\\fake\\a.exe',
                  loader: (_) async => _blueSquare(2, 3)))));
      for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(Duration.zero);
      }
      expect(find.byType(RawImage), findsOneWidget);
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image, isNotNull, reason: '解码结果应挂到 RawImage 上');
      expect(raw.image!.width, 2);
      expect(raw.image!.height, 3, reason: '宽高须按像素实际值，不能写死 32');
    });
  });

  testWidgets('取不到图标回落成占位 Icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppIconImage(
                displayIcon: 'whatever', loader: (_) async => null))));
    await tester.pumpAndSettle();
    expect(find.byType(Icon), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('默认 loader：空 DisplayIcon 直接回落，不触碰 frb 桥', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: AppIconImage(displayIcon: '  '))));
    await tester.pumpAndSettle();
    expect(find.byType(Icon), findsOneWidget);
  });

  /// 进程列表每 3s 重排，ListView 按位置复用行：来源换了必须重新取图标，
  /// 否则这一行会一直挂着上一个进程的图标。
  testWidgets('同一行换了图标来源要重新提取', (tester) async {
    final asked = <String>[];
    Future<AppIcon?> loader(String key) async {
      asked.add(key);
      return key == 'second' ? _blueSquare(4, 5) : _blueSquare(2, 3);
    }

    Future<void> waitForSize(WidgetTester t, int w, int h) async {
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(Duration.zero);
        final found = find.byType(RawImage).evaluate();
        if (found.isNotEmpty) {
          final image = t.widget<RawImage>(find.byType(RawImage)).image;
          if (image != null && image.width == w && image.height == h) return;
        }
      }
      fail('未等到 ${w}x$h 的图标');
    }

    await tester.runAsync(() async {
      Widget page(String icon) => MaterialApp(
          home:
              Scaffold(body: AppIconImage(displayIcon: icon, loader: loader)));
      await tester.pumpWidget(page('first'));
      await waitForSize(tester, 2, 3);
      await tester.pumpWidget(page('second'));
      await waitForSize(tester, 4, 5);
    });
    expect(asked, ['first', 'second'], reason: '两次来源各提取一次，不能复用旧图');
  });
}
