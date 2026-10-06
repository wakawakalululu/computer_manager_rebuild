import 'dart:convert';
import 'dart:io';

import 'package:computer_manager/services/click_report.dart';
import 'package:computer_manager/services/feedback_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 点击埋点的离线验证：不起 Rust 桥、不连真实网关。
/// 本地 HttpServer 实测 `/report/click/count` 的 method/path/头/请求体，
/// 事件名则逐条对着 `specs/click_events.txt` 抄下来的表核。
void main() {
  group('事件名', () {
    test('弹窗动作按 click_<窗口>_<动作> 拼，与 AOT 里的形状一致', () {
      expect(
          clickEventFor('RAM_window', 'expedite'), 'click_RAM_window_expedite');
      expect(clickEventFor('SystemDisk_window', 'cancel'),
          'click_SystemDisk_window_cancel');
      expect(clickEventFor('CPU_window', 'never'), 'click_CPU_window_never');
    });

    test('我们接上的每个事件都在参考实现的事件表里', () {
      // 接错一个字母，后台收到的就是一个从没有过的新事件名，没人会发现。
      const wired = [
        'click_RAM_window_expedite',
        'click_RAM_window_cancel',
        'click_RAM_window_never',
        'click_CPU_window_ProcessManagement',
        'click_CPU_window_cancel',
        'click_CPU_window_never',
        'click_SystemDisk_window_deepclean',
        'click_SystemDisk_window_cancel',
        'click_SystemDisk_window_never',
        'click_ball',
      ];
      for (final e in wired) {
        expect(kKnownClickEvents, contains(e), reason: '$e 不在事件表里');
      }
      expect(kKnownClickEvents.length, 15); // click_events.txt 共 15 行
    });
  });

  test('请求体带事件名、机器标识、版本与时间', () {
    final p = clickPayload(
        event: 'click_ball', machineId: 'MID-1', atMillis: 1767000000000);
    expect(p, {
      'event': 'click_ball',
      'machine_id': 'MID-1',
      'version': kClientVersion,
      'time': 1767000000000,
    });
  });

  test('真发一次：POST /report/click/count，JSON 体与 mid 都对得上', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <String, String>{};
    final done = server.listen((req) async {
      received['method'] = req.method;
      received['path'] = req.uri.path;
      received['type'] = req.headers.contentType?.mimeType ?? '';
      received['body'] = await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      await req.response.close();
    }).asFuture<void>();

    final reporter = ClickReporter(
      resolveTarget: () async => FeedbackTarget(
          baseHost: 'http://127.0.0.1:${server.port}', machineId: 'MID-9'),
      now: () => 1767000000000,
    );
    await reporter.report('click_RAM_window_expedite');
    await server.close(force: true);
    await done.catchError((_) {});

    expect(received['method'], 'POST');
    expect(received['path'], '/report/click/count');
    expect(received['type'], 'application/json');
    final body = jsonDecode(received['body']!) as Map<String, dynamic>;
    expect(body['event'], 'click_RAM_window_expedite');
    expect(body['machine_id'], 'MID-9');
    expect(body['time'], 1767000000000);
  });

  test('网关不可达也不抛：只留一行痕，用户点的动作照旧', () async {
    final errors = <String>[];
    final reporter = ClickReporter(
      resolveTarget: () async =>
          throw FeedbackException('未配置上报地址（config.ini 缺少 [config] baseHost）'),
      onError: errors.add,
    );
    await reporter.report('click_ball');
    expect(errors, hasLength(1));
    expect(errors.single, contains('click_ball'));
    expect(errors.single, contains('未配置上报地址'));
  });

  test('后端回 5xx 也只留痕', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((req) {
      req.response.statusCode = 500;
      req.response.close();
    });
    final errors = <String>[];
    ClickReporter(
      resolveTarget: () async => FeedbackTarget(
          baseHost: 'http://127.0.0.1:${server.port}', machineId: 'M'),
      onError: errors.add,
    ).report('click_SystemDisk_window_deepclean');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    await server.close(force: true);
    expect(errors.single, contains('点击上报接口返回错误状态'));
  });
}
