import 'dart:async';

import 'package:computer_manager/pages/settings_page.dart';
import 'package:computer_manager/services/feedback_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FeedbackPage 的状态机验证（不碰 Rust 桥、不碰网络）：
/// 授权门控、空描述提示、提交过程中的阶段文案、成功态与失败态。
/// 真实 HTTP 报文由 feedback_flow_test.dart 覆盖，真实日志采集由
/// feedback_runtime_chain_test.dart 覆盖，三者合起来才是完整链路。
class _Call {
  _Call(this.content, this.payload, this.logZipPath);
  final String content;
  final Map<String, dynamic> payload;
  final String? logZipPath;
}

class _FakeClient extends FeedbackClient {
  _FakeClient(FeedbackTarget target, {this.reply}) : super(target: target);

  /// 后端回复文案；为 null 时抛 FeedbackException，模拟提交失败。
  final String? reply;
  final List<_Call> calls = [];

  @override
  Future<String> submit({
    required String content,
    required Map<String, dynamic> payload,
    String? logZipPath,
    void Function(FeedbackStage stage)? onStage,
  }) async {
    calls.add(_Call(content, payload, logZipPath));
    onStage?.call(FeedbackStage.submitting);
    if (logZipPath != null) onStage?.call(FeedbackStage.uploading);
    if (reply == null) throw FeedbackException('HTTP 500: gateway down');
    onStage?.call(FeedbackStage.done);
    return reply!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const target =
      FeedbackTarget(baseHost: 'https://gateway.invalid', machineId: 'mid-ui');
  late _FakeClient client;
  late List<String> infos;
  late List<String> errors;
  late FeedbackSubmitter submitter;
  late Future<String?> Function() collect;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = _FakeClient(target, reply: '感谢您的反馈，我们会尽快处理');
    infos = [];
    errors = [];
    collect = () async => 'cm_collect_1.zip';
    submitter = FeedbackSubmitter(
      collectLog: () => collect(),
      resolveTarget: () async => target,
      openClient: (_) => client,
      info: (m) async => infos.add(m),
      error: (m) async => errors.add(m),
    );
  });

  test('日志包收集失败：仍然把问题描述提交上去，只是没有附件', () async {
    // 附件是**可选**的。收集日志失败原来会一路冒到最外层 catch → 整次提交失败，
    // 用户写好的问题描述一起丢掉，看到的却是"提交失败"，真实原因只是"没带日志"。
    collect = () async => throw StateError('logs 目录不可写');
    await submitter.submit(content: '磁盘占用异常');

    expect(errors.join(), contains('收集日志包失败'));
    // 附件为 null 时**不报错**，也不该让提交失败
    expect(infos.any((m) => m.contains('附件=无')), isTrue,
        reason: '没带附件要如实写「无」，不能写成有');
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FeedbackPage(submitter: submitter)),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> agree(WidgetTester tester) async {
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
  }

  Future<void> typeContent(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> submitTap(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '提交反馈'));
    await tester.pumpAndSettle();
  }

  testWidgets('描述为空时只提示，不采集也不提交', (tester) async {
    var collected = 0;
    collect = () async {
      collected++;
      return null;
    };
    await pumpPage(tester);
    await agree(tester);
    await submitTap(tester);

    expect(find.text('请填写问题描述'), findsOneWidget);
    expect(collected, 0);
    expect(client.calls, isEmpty);
  });

  testWidgets('未勾选授权时提示「勾选同意」，不发请求', (tester) async {
    await pumpPage(tester);
    await typeContent(tester, '悬浮窗拖动卡顿');
    await submitTap(tester);

    expect(find.text('勾选同意'), findsOneWidget);
    expect(client.calls, isEmpty);
  });

  testWidgets('授权后提交：采集→提交→成功态，并记住授权', (tester) async {
    await pumpPage(tester);
    await typeContent(tester, '  睡眠后 CPU 占用飙升  ');
    await agree(tester);
    await submitTap(tester);
    await tester.pumpAndSettle();

    expect(find.text('反馈提交成功'), findsOneWidget);
    expect(find.text('感谢您的反馈，我们会尽快处理'), findsOneWidget);
    // 正文取 trim 后的内容，附件走 Rust collect_log 返回的 zip 路径
    expect(client.calls.single.content, '睡眠后 CPU 占用飙升');
    expect(client.calls.single.logZipPath, 'cm_collect_1.zip');
    expect(client.calls.single.payload['machine_id'], 'mid-ui');
    expect(client.calls.single.payload['version'], kClientVersion);
    expect(client.calls.single.payload['upload_log'], 1);
    expect(infos, ['反馈提交完成：${'睡眠后 CPU 占用飙升'.length} 字，附件=cm_collect_1.zip']);
    expect(
        SharedPreferences.getInstance()
            .then((p) => p.getBool('feedbackAgreeUploadLog')),
        completion(isTrue));
    // 成功后输入框被清空，回到表单即可再次提交
    expect(find.text('再次提交'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '再次提交'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('无日志可采集时仍然提交正文', (tester) async {
    collect = () async => null;
    await pumpPage(tester);
    await typeContent(tester, '只有文字描述');
    await agree(tester);
    await submitTap(tester);
    await tester.pumpAndSettle();

    expect(client.calls.single.logZipPath, isNull);
    expect(find.text('反馈提交成功'), findsOneWidget);
    expect(infos.single, contains('附件=无'));
  });

  testWidgets('提交过程中按钮显示阶段文案并锁住表单', (tester) async {
    final gate = Completer<String?>();
    collect = () => gate.future;
    await pumpPage(tester);
    await typeContent(tester, '网卡偶发掉线');
    await agree(tester);
    await submitTap(tester);

    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(find.text('日志采集中'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    gate.complete('cm_collect_2.zip');
    await tester.pumpAndSettle();
    expect(find.text('反馈提交成功'), findsOneWidget);
  });

  testWidgets('后端失败时落到失败态并把错误显示出来', (tester) async {
    client = _FakeClient(target, reply: null);
    await pumpPage(tester);
    await typeContent(tester, '清理后无法开机');
    await agree(tester);
    await submitTap(tester);
    await tester.pumpAndSettle();

    expect(find.text('反馈提交成功'), findsNothing);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
    expect(errors, [contains('HTTP 500: gateway down')]);
    // 失败后表单仍可用，用户可原地重试
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
