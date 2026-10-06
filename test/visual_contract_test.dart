import 'dart:async';

import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/src/rust/api/sysinfo.dart' as si;
import 'package:computer_manager/widgets/common.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真机截图（1020x700 逻辑 / 1275x875 物理，见 scripts/ui_probe.ps1 -Action shot）
/// 量出来的三条版式契约，钉在测试里，避免改回「看起来像溢出」的形态。
void main() {
  Future<void> pumpAtWindowSize(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  group('阈值弹窗', () {
    Future<void> pumpPopup(WidgetTester tester,
        {String actionLabel = '深度清理'}) async {
      await pumpAtWindowSize(
        tester,
        ThresholdPopupCard(
          title: '系统盘空间不足',
          body: '系统盘剩余空间过低，建议深度清理。',
          actionLabel: actionLabel,
          onAction: () {},
          onCancel: () {},
          onNever: () {},
        ),
      );
    }

    testWidgets('卡片宽度收紧到 420，三个按钮都留在窗口内', (tester) async {
      await pumpPopup(tester);
      final card = find.byKey(const ValueKey('threshold-popup-card'));
      expect(tester.getSize(card).width, 420);
      final rect = tester.getRect(card);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1020));
      for (final label in ['取消', '不再提示', '深度清理']) {
        expect(find.text(label), findsOneWidget);
        expect(tester.getRect(find.text(label)).right, lessThan(1020));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('正文与按钮同侧对齐，不出现整幅空白', (tester) async {
      await pumpPopup(tester);
      // 按钮行右缘贴着卡片内容右缘，左缘必须落在正文那一侧，
      // 否则就是「正文在左、按钮被推到屏幕右缘」的那种拉伸版式。
      final body = tester.getRect(find.text('系统盘剩余空间过低，建议深度清理。'));
      final never = tester.getRect(find.text('不再提示'));
      expect(never.left, greaterThan(body.left));
      expect(never.left - body.right, lessThan(200));
    });

    testWidgets('长动作名也不撑破卡片', (tester) async {
      await pumpPopup(tester, actionLabel: '打开进程管理并结束占用进程');
      final card =
          tester.getRect(find.byKey(const ValueKey('threshold-popup-card')));
      final action = tester.getRect(find.text('打开进程管理并结束占用进程'));
      expect(action.right, lessThanOrEqualTo(card.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消 / 不再提示 / 主动作分别回调', (tester) async {
      final hits = <String>[];
      await pumpAtWindowSize(
        tester,
        ThresholdPopupCard(
          title: '内存占用过高',
          body: '建议一键加速。',
          actionLabel: '立即加速',
          onAction: () => hits.add('action'),
          onCancel: () => hits.add('cancel'),
          onNever: () => hits.add('never'),
        ),
      );
      await tester.tap(find.text('取消'));
      await tester.tap(find.text('不再提示'));
      await tester.tap(find.text('立即加速'));
      expect(hits, ['cancel', 'never', 'action']);
    });
  });

  group('入口卡片', () {
    testWidgets('可点击才画「>」，未开放的卡片不给假 affordance', (tester) async {
      await pumpAtWindowSize(
        tester,
        Column(children: const [
          EntryCard(
              icon: 'icon_net_speed_test.webp',
              title: '有跳转',
              subtitle: '子标题',
              onTap: null),
        ]),
      );
      // onTap 为 null 的两张卡（设备检测 / 安全盘）不该显示前进箭头。
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('带 onTap 的卡片保留前进箭头', (tester) async {
      await pumpAtWindowSize(
        tester,
        Column(children: [
          EntryCard(
              icon: 'icon_net_speed_test.webp',
              title: '有跳转',
              subtitle: '子标题',
              onTap: () {}),
        ]),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });
  });

  group('破坏性动作确认', () {
    Future<bool?> run(WidgetTester tester, String tapLabel) async {
      bool? result;
      await pumpAtWindowSize(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await confirmDestructive(context,
                  title: '确定结束进程？', body: '所选项删除后不可恢复，请慎重清理');
            },
            child: const Text('触发'),
          ),
        ),
      );
      await tester.tap(find.text('触发'));
      await tester.pumpAndSettle();
      // 没点之前必须已经弹出来了：动作不能和确认在同一帧里发生。
      expect(find.text('所选项删除后不可恢复，请慎重清理'), findsOneWidget);
      await tester.tap(find.text(tapLabel));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('取消即返回 false，动作不执行', (tester) async {
      expect(await run(tester, '取消'), isFalse);
    });

    testWidgets('确认即返回 true', (tester) async {
      expect(await run(tester, '确认'), isTrue);
    });
  });

  group('扫描页三态', () {
    // 扫描中的那一格里有循环 Lottie，所以这里一律用 pump()：pumpAndSettle
    // 等不到动画停下来。
    Future<StreamController<List<CleanItem>>> pumpScanPage(WidgetTester tester,
        {bool readOnly = false}) async {
      final controller = StreamController<List<CleanItem>>();
      addTearDown(controller.close);
      tester.view.physicalSize = const Size(1020, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScanPageScaffold(
                  title: '重复文件',
                  subtitle: '基于内容指纹查找重复文件',
                  cancelKey: 'dup_file',
                  readOnly: readOnly,
                  stream: controller.stream))));
      await tester.pump();
      return controller;
    }

    testWidgets('结果没回来之前只有「正在检测…」，不许先判「很干净」', (tester) async {
      await pumpScanPage(tester);
      expect(find.text('正在检测…'), findsOneWidget);
      expect(find.text('很干净，没有发现可清理项'), findsNothing);
      expect(find.text('立即清理'), findsNothing);
      // 横幅收在中间，不拉成整幅：实机图上「正在检测…」贴左、「取消」贴右，
      // 中间一整条空白。
      final text = tester.getRect(find.text('正在检测…'));
      final cancel = tester.getRect(find.text('取消'));
      expect(cancel.left - text.right, lessThan(80));
      expect(cancel.right, lessThan(1020 - 100));
    });

    testWidgets('空结果才是「很干净」，且不给清理按钮', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.add([]);
      await tester.pump();
      await tester.pump();
      expect(find.text('很干净，没有发现可清理项'), findsOneWidget);
      expect(find.text('立即清理'), findsNothing);
    });

    testWidgets('有结果才出行目与清理按钮', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.add(
          [CleanItem(path: r'C:\Users\Admin\dup_probe_test\a.bin', size: 3)]);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('dup_probe_test'), findsOneWidget);
      expect(find.text('立即清理'), findsOneWidget);
      expect(find.text('很干净，没有发现可清理项'), findsNothing);
    });

    testWidgets('只读结果页不画勾选框、也不给清理按钮', (tester) async {
      final controller = await pumpScanPage(tester, readOnly: true);
      controller.add([
        CleanItem(path: r'C:\Windows', size: 15817),
        CleanItem(path: r'C:\Program Files', size: 6229),
      ]);
      await tester.pump();
      await tester.pump();
      // 系统盘文件页列的是 C:\Windows 这种目录，勾选框 +「立即清理」等于
      // 摆一个全选删系统的按钮。
      expect(find.text(r'C:\Windows'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('立即清理'), findsNothing);
    });

    testWidgets('扫描报错进错误态而不是空态', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.addError(ScanException('重复文件扫描已取消'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('扫描未完成：重复文件扫描已取消'), findsOneWidget);
      expect(find.text('很干净，没有发现可清理项'), findsNothing);
    });
  });

  group('已安装应用标题', () {
    test('DisplayName 自带版本号时不再重复一遍', () {
      expect(dedupTitle('Ditto 3.24.246.0', '3.24.246.0'), 'Ditto 3.24.246.0');
      expect(dedupTitle('腾讯文档 3.12.3', '3.12.3'), '腾讯文档 3.12.3');
    });

    test('名称里没有版本号时才拼接，空版本不留尾随空格', () {
      expect(dedupTitle('Git', '2.56.0'), 'Git  2.56.0');
      expect(dedupTitle('Git', ''), 'Git');
      expect(dedupTitle('Git', '   '), 'Git');
    });

    test('补丁行同样复用：KB 号与标题相同时只出现一次', () {
      expect(dedupTitle('KB5066130', 'KB5066130'), 'KB5066130');
      expect(dedupTitle('KB5066130', '累积更新'), 'KB5066130  累积更新');
    });

    test('写进整句文案时换成单空格，双空格只在列表行里用', () {
      expect(dedupTitle('Git', '2.56.0', sep: ' '), 'Git 2.56.0');
      expect(dedupTitle('Git', '', sep: ' '), 'Git');
    });
  });

  group('运行时长文案', () {
    test('实机测到的 54331.5 秒不再原样上屏', () {
      expect(formatDuration(54331500), '15 小时 5 分钟');
    });

    test('按量级取粗：不足 1 分钟 / 分钟 / 整点小时 / 跨天', () {
      expect(formatDuration(0), '不足 1 分钟');
      expect(formatDuration(45000), '不足 1 分钟');
      expect(formatDuration(9 * 60000), '9 分钟');
      expect(formatDuration(3 * 3600000), '3 小时');
      expect(formatDuration(2 * 86400000 + 5 * 3600000), '2 天 5 小时');
      expect(formatDuration(2 * 86400000), '2 天');
    });
  });

  group('网速实测换算', () {
    si.NetQuality quality(List<int> rtts,
            {int received = 0, int transmitted = 0, int windowMs = 1000}) =>
        si.NetQuality(
            rttMs: frb.Uint64List.fromList(rtts),
            receivedBytes: BigInt.from(received),
            transmittedBytes: BigInt.from(transmitted),
            windowMs: BigInt.from(windowMs));

    test('时延取平均、抖动取极差，速率按窗口秒数折算', () {
      final r = NetSpeedResult.from(
          quality([10, 20, 30], received: 3000, transmitted: 600));
      expect(r.rttMs, 20);
      expect(r.jitterMs, 20);
      expect(r.downBps, 3000);
      expect(r.upBps, 600);
      expect(r.probes, 3);
    });

    test('一次都没连上时是「不可达」，不是 0 ms 的假数据', () {
      final r = NetSpeedResult.from(quality([]));
      expect(r.reachable, isFalse);
      expect(r.probes, 0);
      expect(r.jitterMs, 0);
    });

    test('窗口不足 1 秒时按真实窗口折算', () {
      final r = NetSpeedResult.from(
          quality([5], received: 1000, transmitted: 500, windowMs: 500));
      expect(r.downBps, 2000);
      expect(r.upBps, 1000);
    });

    test('速率按量级换档，大数不留无意义小数', () {
      expect(formatRate(0), '0 B/s');
      expect(formatRate(512), '0.5 KB/s');
      expect(formatRate(3 * 1024), '3.0 KB/s');
      expect(formatRate(200 * 1024), '200 KB/s');
      expect(formatRate(3 * 1024 * 1024), '3.0 MB/s');
      expect(formatRate(1024.0 * 1024 * 1024), '1.0 GB/s');
    });
  });

  group('体检状态栏与结论徽标', () {
    test('从没体检过时不编一个时间出来', () {
      expect(formatLastExamination(null), '首次体检，检查过程不改动任何文件');
    });

    test('体检时间报到分钟，与参考实现「上次体检时间」同义', () {
      final at = DateTime(2026, 10, 6, 4, 5).millisecondsSinceEpoch;
      expect(formatLastExamination(at), contains('上次体检时间：2026-10-06 04:05'));
    });

    test('徽标措辞取参考实现文案表自带的「可优化」「已优化」', () {
      ExamineItem withVerdict(ExamineVerdict v) =>
          ExamineItem(key: 'k', title: 't', verdict: v, detail: 'd');
      expect(examineBadge(withVerdict(ExamineVerdict.ok)), '已优化');
      expect(examineBadge(withVerdict(ExamineVerdict.needFix)), '可优化');
      expect(examineBadge(withVerdict(ExamineVerdict.failed)), '未取到');
      // 「没配标准」既不是通过也不是待处理，得有自己的徽标
      expect(examineBadge(withVerdict(ExamineVerdict.skipped)), '未配置');
    });
  });

  group('重启挂起提示', () {
    test('没有挂起点时什么都不说', () {
      expect(rebootNotice([]), isNull);
    });

    test('组件服务或 Windows Update 在等重启，才用参考实现那句补丁措辞', () {
      expect(rebootNotice(['cbs']), '存在需要重启云电脑才生效的补丁');
      expect(rebootNotice(['wu', 'rename']), '存在需要重启云电脑才生效的补丁');
    });

    test('只有安装器留下的待替换文件时，不冒充「补丁」', () {
      expect(rebootNotice(['rename']), '有文件操作需要重启后才能完成');
    });
  });
}
