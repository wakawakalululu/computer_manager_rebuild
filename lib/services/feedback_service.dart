/// 问题反馈提交链路（specs/routes_ui.txt）。
///
/// 规格整理依据：
/// - 接口路径两条都在 Dart 侧的 URI 清单里：`/report/feedback2`（正文）与
///   `/report/upload/feedfile`（附件）；
/// - frb 调用清单中与反馈相关的只有 `crateApiSysinfoLogsRCollectLog`，
///   即“收集/压缩日志”在 Rust、“发请求”在 Dart —— 所以这里用 dart:io 的
///   HttpClient 直接发送，不新增 Rust API，也不引第三方 http 包；
/// - 文案取自 zh_strings.txt：「授权上传日志与诊断数据」「日志采集中」「日志压缩中」
///   「反馈提交成功」「感谢您的反馈，我们会尽快处理」「勾选同意」。
///
/// 合规：baseHost 只从随包 `config.ini` 读取，代码里不硬编码任何网关域名
///（见 README 合规节）；未授权时不采集、不上传任何日志文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'rust_api.dart';

const String kFeedbackPath = '/report/feedback2';
const String kFeedFileUploadPath = '/report/upload/feedfile';

/// 客户端版本号，与 pubspec.yaml 的 version 主段一致（无 package_info_plus，参考实现亦未在运行时取版本）
const String kClientVersion = '0.1.0';

/// 提交阶段，UI 据此显示对应文案
enum FeedbackStage { idle, collecting, submitting, uploading, done, failed }

extension FeedbackStageX on FeedbackStage {
  String get label => switch (this) {
        FeedbackStage.idle => '',
        FeedbackStage.collecting => '日志采集中',
        FeedbackStage.submitting => '反馈提交中',
        FeedbackStage.uploading => '日志压缩中',
        FeedbackStage.done => '反馈提交成功',
        FeedbackStage.failed => '反馈提交失败',
      };
}

class FeedbackException implements Exception {
  FeedbackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 上报地址与设备标识。任一缺失即拒绝提交，避免把反馈发往错误主机或发出无 mid 的请求。
class FeedbackTarget {
  const FeedbackTarget({required this.baseHost, required this.machineId});
  final String baseHost;
  final String machineId;

  Uri uri(String path) => Uri.parse('$baseHost$path');

  /// 从随包 config.ini + 注册表机器标识解析提交目标。
  /// [configDir] 默认取 GUI exe 同目录，测试时可注入临时目录。
  static Future<FeedbackTarget> resolve(
      {String? machineId, String? configDir}) async {
    final dir = configDir ?? File(Platform.resolvedExecutable).parent.path;
    final host = readBaseHost(File('$dir\\config.ini'));
    final mid = machineId ?? await RustApi.instance.getMachineId();
    if (host == null) {
      throw FeedbackException('未配置上报地址（config.ini 缺少 [config] baseHost）');
    }
    if (mid.isEmpty) throw FeedbackException('未取到机器标识，无法提交反馈');
    return FeedbackTarget(baseHost: host, machineId: mid);
  }
}

/// 只认 `[config]` 段的 baseHost（同段还有 env/channel，反馈链路用不到）。
/// 无协议前缀时按 https 补齐 —— 与 deploy/config.ini 的模板写法一致。
/// 取某个 INI 段的键值对。键统一小写返回；`;`/`#` 开头的行与空行跳过，
/// `key = a = b` 只在第一个 `=` 处切。段名按大小写不敏感匹配。
///
/// 解码用 `allowMalformed`：这份文件是给运维手改的，中文 Windows 的记事本默认
/// 按 GBK 保存，整份按 UTF-8 硬解会抛 `FormatException`，让反馈与兼容性检查
/// 一起哑掉。注释里的中文坏掉不影响任何键值，ASCII 的段名/键名照旧可读；
/// 值本身要写中文时请按 UTF-8 保存（见 deploy/config.ini 的说明）。
Map<String, String> readIniSection(File file, String section) {
  final out = <String, String>{};
  if (!file.existsSync()) return out;
  String? current;
  for (final raw in const LineSplitter()
      .convert(utf8.decode(file.readAsBytesSync(), allowMalformed: true))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    final match = RegExp(r'^\[(.*)\]$').firstMatch(line);
    if (match != null) {
      current = match.group(1);
      continue;
    }
    if ((current ?? '').toLowerCase() != section.toLowerCase()) continue;
    final kv = line.split('=');
    if (kv.length < 2) continue;
    out[kv[0].trim().toLowerCase()] = kv.sublist(1).join('=').trim();
  }
  return out;
}

/// GUI 与 cm_agent 共用的随包配置：与 exe 同目录的 `config.ini`。
File shippedConfigFile() =>
    File('${File(Platform.resolvedExecutable).parent.path}\\config.ini');

String? readBaseHost(File file) {
  final value = readIniSection(file, 'config')['basehost'];
  if (value == null || value.isEmpty) return null;
  final withScheme = value.startsWith('http') ? value : 'https://$value';
  return withScheme.endsWith('/')
      ? withScheme.substring(0, withScheme.length - 1)
      : withScheme;
}

/// 反馈正文载荷。
/// TODO(假设)：规格清单只给出接口路径，字段名按接口语义推断，真实字段待联调确认。
Map<String, dynamic> feedbackPayload({
  required String content,
  required String machineId,
  required String version,
  required String channel,
  required bool logAuthorized,
}) =>
    {
      'content': content,
      'machine_id': machineId,
      'version': version,
      'channel': channel,
      'upload_log': logAuthorized ? 1 : 0,
    };

/// 手工拼 multipart 体：附件部件排在表单字段之后、结束边界之前。
/// 纯函数，便于离线断言字节而不起服务器。
Uint8List buildMultipartBody({
  required String boundary,
  required List<(String, String)> fields,
  required String fileField,
  required String fileName,
  required List<int> fileBytes,
}) {
  final builder = BytesBuilder(copy: false);
  for (final (name, value) in fields) {
    builder.add(utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
  }
  builder.add(utf8.encode('--$boundary\r\n'
      'Content-Disposition: form-data; name="$fileField"; filename="$fileName"\r\n'
      'Content-Type: application/zip\r\n\r\n'));
  builder.add(fileBytes);
  builder.add(utf8.encode('\r\n--$boundary--\r\n'));
  return builder.takeBytes();
}

class FeedbackClient {
  FeedbackClient({required this.target, HttpClient? http})
      : _http = http ??
            (HttpClient()..connectionTimeout = const Duration(seconds: 8));

  final FeedbackTarget target;
  final HttpClient _http;

  /// 提交反馈；[logZipPath] 非空时再上传采集包（调用方只在用户已授权时才传）。
  /// 返回给用户看的一句话；两个接口任一失败都抛 FeedbackException。
  /// 这里不写日志：日志由调用方落到 gui_log，客户端保持无副作用便于离线测试。
  Future<String> submit({
    required String content,
    required Map<String, dynamic> payload,
    String? logZipPath,
    void Function(FeedbackStage)? onStage,
  }) async {
    onStage?.call(FeedbackStage.submitting);
    await _post(target.uri(kFeedbackPath), utf8.encode(jsonEncode(payload)),
        'application/json');

    if (logZipPath != null) {
      onStage?.call(FeedbackStage.uploading);
      final bytes = await File(logZipPath).readAsBytes();
      final boundary = '----CmFeedback${DateTime.now().millisecondsSinceEpoch}';
      final body = buildMultipartBody(
        boundary: boundary,
        fields: [
          ('machine_id', target.machineId),
          ('content', content),
        ],
        fileField: 'feedfile',
        // 平台无关的 basename：日志 zip 路径可能来自 Windows（\）或 POSIX（/）
        fileName: logZipPath.split(RegExp(r'[\\/]')).last,
        fileBytes: bytes,
      );
      await _post(target.uri(kFeedFileUploadPath), body,
          'multipart/form-data; boundary=$boundary');
    }
    onStage?.call(FeedbackStage.done);
    return '感谢您的反馈，我们会尽快处理';
  }

  Future<void> _post(Uri uri, List<int> body, String contentType) async {
    final req = await _http.openUrl('POST', uri);
    req.headers.set('mid', target.machineId);
    req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    req.headers.contentLength = body.length;
    req.add(body);
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw FeedbackException('HTTP ${resp.statusCode}: ${_cut(text, 200)}');
    }
  }

  void close() => _http.close(force: true);
}

String _cut(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// 反馈提交编排：日志采集（Rust collect_log）→ 上报地址解析（config.ini）→
/// feedback2 正文 + feedfile 附件，并把结果写进 gui_log。
///
/// 界面只依赖本类，协作者全部可注入：生产用 [FeedbackSubmitter.production]，
/// 测试用本地 HttpServer + 假采集，即可在没有 Rust 桥的 `flutter test` 里跑完整状态流。
class FeedbackSubmitter {
  const FeedbackSubmitter({
    required this.collectLog,
    required this.resolveTarget,
    required this.openClient,
    required this.info,
    required this.error,
  });

  factory FeedbackSubmitter.production() {
    final api = RustApi.instance;
    return FeedbackSubmitter(
      collectLog: api.collectLogPack,
      resolveTarget: FeedbackTarget.resolve,
      openClient: (target) => FeedbackClient(target: target),
      info: api.logInfo,
      error: api.logError,
    );
  }

  final Future<String?> Function() collectLog;
  final Future<FeedbackTarget> Function() resolveTarget;
  final FeedbackClient Function(FeedbackTarget target) openClient;
  final Future<void> Function(String msg) info;
  final Future<void> Function(String msg) error;

  /// 成功返回给用户看的文案；失败原样抛出，由界面落到失败态。
  Future<String> submit({
    required String content,
    void Function(FeedbackStage stage)? onStage,
  }) async {
    String? zipPath;
    try {
      onStage?.call(FeedbackStage.collecting);
      // 附件是**可选**的：打包日志失败不该让用户写好的问题描述一起丢掉。
      // 原来 collectLog 抛出去会一路冒到最外层 catch → 整次提交失败，
      // 用户看到的是"提交失败"，而真实情况只是"没带日志"。降级成"没附件"并记一条。
      try {
        zipPath = await collectLog();
      } catch (e) {
        await error('收集日志包失败，本次反馈将不带附件: $e');
      }
      final target = await resolveTarget();
      final client = openClient(target);
      try {
        final receipt = await client.submit(
          content: content,
          payload: feedbackPayload(
            content: content,
            machineId: target.machineId,
            version: kClientVersion,
            channel: 'windows',
            logAuthorized: true,
          ),
          logZipPath: zipPath,
          onStage: onStage,
        );
        await info('反馈提交完成：${content.length} 字，附件=${zipPath ?? '无'}');
        return receipt;
      } finally {
        client.close();
      }
    } catch (e) {
      await error('反馈提交失败: $e');
      rethrow;
    }
  }
}
