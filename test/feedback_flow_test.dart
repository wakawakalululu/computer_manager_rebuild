import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:computer_manager/services/feedback_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 反馈链路离线验证：不起 Rust 桥、不连真实网关。
/// 用本地 HttpServer 实测两个接口（/report/feedback2、/report/upload/feedfile）
/// 的 method / path / mid 头 / multipart 字段与字节，证明请求确实按规格整理规格发出。
class _Recorded {
  _Recorded(this.method, this.path, this.contentType, this.mid, this.body);
  final String method;
  final String path;
  final String? contentType;
  final String? mid;
  final List<int> body;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('cm_feedback_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('config.ini 解析', () {
    test('取 [config] 段 baseHost，补协议、去尾斜杠', () {
      final f = File('${tmp.path}\\config.ini')..writeAsStringSync('''
[config]
env = prod
baseHost = https://gateway.invalid/cm/
channel = windows

[other]
baseHost = https://should-be-ignored.invalid
''');
      expect(readBaseHost(f), 'https://gateway.invalid/cm');
    });

    test('裸域名按 https 补齐；缺键或空值返回 null', () {
      final f = File('${tmp.path}\\config.ini')
        ..writeAsStringSync('[config]\nbaseHost = gateway.invalid\n');
      expect(readBaseHost(f), 'https://gateway.invalid');
      final empty = File('${tmp.path}\\empty.ini')
        ..writeAsStringSync('[config]\nbaseHost =\n');
      expect(readBaseHost(empty), isNull);
      expect(readBaseHost(File('${tmp.path}\\missing.ini')), isNull);
    });

    test('运维用 GBK 保存过也不炸：ASCII 键值照旧读得出', () {
      // 中文 Windows 的记事本默认按 ANSI(GBK) 存盘，注释里的中文不是合法 UTF-8。
      // 实机就撞过一次：整份按 UTF-8 硬解会抛 FormatException，
      // 把反馈与兼容性检查一起打死。
      final f = File('${tmp.path}\\gbk.ini')
        ..writeAsBytesSync([
          ...'; '.codeUnits,
          ...[0xD6, 0xD0, 0xCE, 0xC4],
          ...'\r\n'.codeUnits,
          ...'[config]\r\nbaseHost = gateway.invalid\r\n'.codeUnits,
        ]);
      expect(readBaseHost(f), 'https://gateway.invalid');
    });

    test('随包模板 deploy/config.ini 可被解析（不含真实网关）', () {
      final file = File('deploy/config.ini');
      if (!file.existsSync()) return;
      final host = readBaseHost(file);
      expect(host, startsWith('https://'));
      expect(host, isNot(contains('127.0.0.1')));
    });
  });

  test('multipart 体：附件部件带 name/filename，字节原样且不截断', () {
    final zipBytes = [
      0x50,
      0x4b,
      3,
      4,
      ...List<int>.generate(300, (i) => i % 251)
    ];
    final body = buildMultipartBody(
      boundary: 'BND',
      fields: [('machine_id', 'mid-1')],
      fileField: 'feedfile',
      fileName: 'cm_collect_1.zip',
      fileBytes: zipBytes,
    );
    final text = latin1.decode(body);
    expect(
        text,
        contains(
            'Content-Disposition: form-data; name="feedfile"; filename="cm_collect_1.zip"'));
    expect(text, contains('Content-Type: application/zip'));
    expect(text,
        contains('--BND\r\nContent-Disposition: form-data; name="machine_id"'));
    expect(text, endsWith('\r\n--BND--\r\n'));
    // 尾部剥离后应等于原始 zip 字节
    final tail = utf8.encode('\r\n--BND--\r\n');
    expect(body.sublist(body.length - tail.length), tail);
    final head = utf8.encode('Content-Type: application/zip\r\n\r\n');
    final start = _indexOf(body, head) + head.length;
    expect(body.sublist(start, start + zipBytes.length), zipBytes);
  });

  test('提交：先 feedback2 再 feedfile，头带 mid，正文为 JSON', () async {
    final received = <_Recorded>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final bytes = await consolidateStream(req);
      received.add(_Recorded(
        req.method,
        req.uri.path,
        req.headers.value(HttpHeaders.contentTypeHeader),
        req.headers.value('mid'),
        bytes,
      ));
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"error":null,"data":"/store/cm_collect.zip"}');
      await req.response.close();
    });

    final zip = File('${tmp.path}\\cm_collect_9.zip')
      ..writeAsBytesSync([0x50, 0x4b, 3, 4, 1, 2, 3, 4]);
    final target = FeedbackTarget(
        baseHost: 'http://${server.address.host}:${server.port}',
        machineId: 'mid-42');
    final stages = <FeedbackStage>[];
    final client = FeedbackClient(target: target);

    final msg = await client.submit(
      content: '悬浮窗拖动卡顿',
      payload: feedbackPayload(
        content: '悬浮窗拖动卡顿',
        machineId: target.machineId,
        version: kClientVersion,
        channel: 'windows',
        logAuthorized: true,
      ),
      logZipPath: zip.path,
      onStage: stages.add,
    );
    client.close();
    await server.close(force: true);

    expect(msg, '感谢您的反馈，我们会尽快处理');
    expect(stages, [
      FeedbackStage.submitting,
      FeedbackStage.uploading,
      FeedbackStage.done
    ]);
    expect(received.map((r) => r.path),
        ['/report/feedback2', '/report/upload/feedfile']);
    expect(received.every((r) => r.method == 'POST'), isTrue);
    expect(received.every((r) => r.mid == 'mid-42'), isTrue);

    final json =
        jsonDecode(utf8.decode(received.first.body)) as Map<String, dynamic>;
    expect(json['content'], '悬浮窗拖动卡顿');
    expect(json['machine_id'], 'mid-42');
    expect(json['version'], kClientVersion);
    expect(json['upload_log'], 1);

    final upload = received.last;
    expect(upload.contentType, startsWith('multipart/form-data; boundary='));
    // 头里的 boundary 必须与体内分隔符一致，否则真实后端无法切分部件
    final boundary =
        RegExp(r'boundary=(.+)$').firstMatch(upload.contentType!)!.group(1)!;
    final uploadText = latin1.decode(upload.body);
    expect(uploadText, contains('--$boundary\r\n'));
    expect(
        uploadText, contains('name="feedfile"; filename="cm_collect_9.zip"'));
    expect(uploadText, contains('name="machine_id"'));
    expect(upload.body, containsAll([0x50, 0x4b, 3, 4]));
  });

  test('未授权日志时只发正文，不读日志文件', () async {
    final paths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      paths.add(req.uri.path);
      await consolidateStream(req);
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
    });
    final client = FeedbackClient(
        target: FeedbackTarget(
            baseHost: 'http://${server.address.host}:${server.port}',
            machineId: 'm'));
    await client.submit(content: '只有文字', payload: {'content': '只有文字'});
    client.close();
    await server.close(force: true);
    expect(paths, ['/report/feedback2']);
  });

  test('后端 500 时抛 FeedbackException，UI 可据此落到失败态', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await consolidateStream(req);
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('gateway down');
      await req.response.close();
    });
    final client = FeedbackClient(
        target: FeedbackTarget(
            baseHost: 'http://${server.address.host}:${server.port}',
            machineId: 'm'));
    await expectLater(
      client.submit(content: 'x', payload: {'content': 'x'}),
      throwsA(isA<FeedbackException>()
          .having((e) => e.message, 'message', contains('HTTP 500'))),
    );
    client.close();
    await server.close(force: true);
  });

  test('阶段文案与规格整理文案一致', () {
    expect(FeedbackStage.collecting.label, '日志采集中');
    expect(FeedbackStage.uploading.label, '日志压缩中');
    expect(FeedbackStage.done.label, '反馈提交成功');
  });
}

Future<List<int>> consolidateStream(HttpRequest req) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in req) {
    builder.add(chunk);
  }
  return builder.takeBytes();
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
