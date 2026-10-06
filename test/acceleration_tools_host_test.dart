import 'dart:ui' show Rect;

import 'package:computer_manager/services/acceleration_tools.dart';
import 'package:computer_manager/services/acceleration_tools_host.dart';
import 'package:flutter_test/flutter_test.dart';

/// 加速工具卡宿主：条目按实测占用算、先定位再显示、失败要能自愈。
/// 全程不碰真窗口，替身即契约。
void main() {
  List<AccelTool>? handed;
  Rect? handedBall;
  int shows = 0;
  bool broken = false;

  final fake = _FakeWindow(
    onSetSlot: (ball, tools) {
      if (broken) throw StateError('子窗口无响应');
      handedBall = ball;
      handed = tools;
    },
    onShow: () => shows++,
  );
  late int created;
  late List<String> log;
  late List<String> errors;
  late AccelToolsHost host;

  setUp(() {
    created = 0;
    shows = 0;
    broken = false;
    handed = null;
    handedBall = null;
    log = [];
    errors = [];
    host = AccelToolsHost(
      createWindow: () async {
        created++;
        return fake;
      },
      log: log.add,
      logError: errors.add,
    );
  });

  test('条目按实测占用算，并带着球的矩形交给子窗口，定位成功后才显示', () async {
    await host.openFor(
        ball: const Rect.fromLTWH(1824, 24, 200, 104),
        memoryRatio: 0.93,
        maxDiskRatio: 0.96);

    expect(handed!.map((t) => t.label), ['一键加速', '查看进程', '深度清理']);
    expect(handedBall, const Rect.fromLTWH(1824, 24, 200, 104));
    expect(shows, 1);
    expect(log.any((l) => l.startsWith('打开加速工具卡')), isTrue);
    expect(errors, isEmpty);
  });

  test('都不吃紧时只给「一键加速」一条', () async {
    await host.openFor(
        ball: const Rect.fromLTWH(0, 0, 200, 104),
        memoryRatio: 0.2,
        maxDiskRatio: 0.2);
    expect(handed!.map((t) => t.id), ['accelerate']);
  });

  test('窗口只创建一个，第二次开卡复用同一个', () async {
    await host.openFor(
        ball: const Rect.fromLTWH(0, 0, 200, 104),
        memoryRatio: 0.5,
        maxDiskRatio: 0.5);
    await host.openFor(
        ball: const Rect.fromLTWH(0, 0, 200, 104),
        memoryRatio: 0.5,
        maxDiskRatio: 0.5);
    expect(created, 1);
    expect(shows, 2);
    expect(host.isOpen, isTrue);
  });

  test('定位失败不抛给调用方，连续三次后丢弃窗口重建', () async {
    broken = true;
    for (var i = 0; i < 3; i++) {
      await host.openFor(
          ball: const Rect.fromLTWH(0, 0, 200, 104),
          memoryRatio: 0.5,
          maxDiskRatio: 0.5);
    }
    expect(errors.where((e) => e.startsWith('加速工具卡打开失败')).length, 3);
    expect(errors.any((e) => e.contains('丢弃后重建')), isTrue);
    expect(shows, 0, reason: '没定位成功就不该把窗口亮出来');
    expect(host.isOpen, isFalse, reason: '三次失败后应丢弃，下次重建');

    broken = false;
    await host.openFor(
        ball: const Rect.fromLTWH(0, 0, 200, 104),
        memoryRatio: 0.5,
        maxDiskRatio: 0.5);
    expect(created, 2);
    expect(shows, 1);
  });
}

class _FakeWindow implements AccelToolsWindow {
  _FakeWindow({required this.onSetSlot, required this.onShow});

  final void Function(Rect ball, List<AccelTool> tools) onSetSlot;
  final void Function() onShow;

  @override
  Future<Map<Object?, Object?>> setSlot(
      {required Rect ball, required List<AccelTool> tools}) async {
    onSetSlot(ball, tools);
    return const {'x': 1, 'y': 2, 'width': 3, 'height': 4};
  }

  @override
  Future<void> show() async => onShow();
}
