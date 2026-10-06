import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:computer_manager/services/feedback_service.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实链路取证（非 mock）：
/// Rust collect_log 产出采集包 → FeedbackClient 用 dart:io 把正文与附件发到本地 HTTP 服务，
/// 服务端收到的附件字节必须与磁盘上的 zip 逐字节一致（MD5 相同）。
/// 这条用例覆盖“GUI 点提交之后发生的一切”，只不含按钮点击本身。
///
/// 依赖编译产物（rust_lib.dll）：原生库不可用的环境（如无产物的 CI runner）
/// 自动跳过；本地或构建后环境真跑。
bool _nativeReady = false;

void main() {
  setUpAll(() async {
    try {
      RustLib.init();
      _nativeReady = true;
    } catch (e) {
      // frb loader 找不到 rust_lib：环境没有编译产物，属预期而非缺陷
      _nativeReady = false;
    }
  });

  test('collect_log 的 zip 经 feedback 链路上传后字节一致', () async {
    if (!_nativeReady) {
      markTestSkipped('rust_lib 不可用（无编译产物的环境），真链路用例跳过');
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final captured = <String, List<int>>{};
    final paths = <String>[];
    server.listen((req) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in req) {
        builder.add(chunk);
      }
      paths.add(req.uri.path);
      captured[req.uri.path] = builder.takeBytes();
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"error":null,"data":"/store/ok"}');
      await req.response.close();
    });

    final zipPath = await RustApi.instance.collectLogPack();
    expect(zipPath, isNotNull, reason: 'collect_log 应返回 zip 路径');
    final zip = File(zipPath!);
    expect(zip.existsSync(), isTrue);
    final zipBytes = zip.readAsBytesSync();
    expect(zipBytes.sublist(0, 2), [0x50, 0x4b], reason: '应为 zip（PK 头）');

    final target = FeedbackTarget(
        baseHost: 'http://${server.address.host}:${server.port}',
        machineId: 'mid-runtime-1');
    final client = FeedbackClient(target: target);
    final stages = <FeedbackStage>[];
    await client.submit(
      content: '运行时链路取证',
      payload: feedbackPayload(
        content: '运行时链路取证',
        machineId: target.machineId,
        version: kClientVersion,
        channel: 'windows',
        logAuthorized: true,
      ),
      logZipPath: zipPath,
      onStage: stages.add,
    );
    client.close();
    await server.close(force: true);
    zip.deleteSync();

    expect(paths, ['/report/feedback2', '/report/upload/feedfile']);
    expect(stages.first, FeedbackStage.submitting);
    expect(stages.last, FeedbackStage.done);

    final jsonBody = jsonDecode(utf8.decode(captured['/report/feedback2']!))
        as Map<String, dynamic>;
    expect(jsonBody['content'], '运行时链路取证');
    expect(jsonBody['machine_id'], 'mid-runtime-1');

    final upload = captured['/report/upload/feedfile']!;
    expect(latin1.decode(upload),
        contains('filename="${zip.path.split('\\').last}"'));
    final marker = utf8.encode('Content-Type: application/zip\r\n\r\n');
    final start = _indexOf(upload, marker) + marker.length;
    final receivedZip = upload.sublist(start, start + zipBytes.length);
    expect(receivedZip, zipBytes, reason: '服务端收到的附件应与 zip 逐字节一致');
  });

  test('随包 config.ini 能被解析成可用地址（不含真实网关）', () {
    final shipped = File('build\\windows\\x64\\runner\\Release\\config.ini');
    if (!shipped.existsSync()) return;
    final host = readBaseHost(shipped);
    expect(host, isNotNull);
    expect(host, startsWith('https://'));
    expect(host, isNot(contains('127.0.0.1')), reason: '模板不应指向本机后端');
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
