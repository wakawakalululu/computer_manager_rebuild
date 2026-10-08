import 'dart:async';

import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/pages/tool_box_page.dart';
import 'package:computer_manager/services/examination.dart';
import 'package:computer_manager/services/running_tasks.dart';
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
      // ⚠ 这张测试**自己造卡**，不读真工具箱页：上面那台只放了一张 `onTap: null`
      // 的卡，所以「没有 >」这件事是被这台自己保证的（阴性/阳性对照用下面那条）。
      // 真的工具箱页现在四张卡**都有去处**——原来「外设检测」是 null，已接上体检页；
      // 「智慧盘」原来也无跳转，已接 /tool_box_dashboard/security_disk。
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

    testWidgets('确定即返回 true（按钮标签用自带的「确定」:555，不是「确认」）', (tester) async {
      expect(await run(tester, '确定'), isTrue);
    });
  });

  group('关窗去向确认', () {
    Future<List<String>> pumpClose(WidgetTester tester) async {
      final hits = <String>[];
      await pumpAtWindowSize(
        tester,
        CloseWindowCard(
          onMinimize: () => hits.add('minimize'),
          onClose: () => hits.add('close'),
          onCancel: () => hits.add('cancel'),
          onNever: () => hits.add('never'),
        ),
      );
      return hits;
    }

    testWidgets('弹窗开着时任务跑完，:89 那句提醒要跟着收回去', (tester) async {
      // 原来是打开弹窗那一刻的字符串快照：扫描在弹窗开着的时候跑完，
      // 提醒还留着，用户点关闭时那句"会取消任务"已经是假话。
      addTearDown(RunningTasks.instance.reset);
      RunningTasks.instance.reset();
      RunningTasks.instance.begin('deep_clean');
      await pumpAtWindowSize(
        tester,
        CloseWindowCard(
          liveRunningTask: true,
          onMinimize: () {},
          onClose: () {},
          onCancel: () {},
          onNever: () {},
        ),
      );
      expect(find.text(kRunningTaskCloseNotice), findsOneWidget);

      // 任务在弹窗还开着的时候结束了
      RunningTasks.instance.end('deep_clean');
      await tester.pump();
      expect(find.text(kRunningTaskCloseNotice), findsNothing);
    });

    testWidgets('四个去向都是参考实现自带的标签', (tester) async {
      final hits = await pumpClose(tester);
      for (final label in ['是否要关闭窗口', '是否最小化', '取消', '不再提示', '最小化', '关闭']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
      final card =
          tester.getRect(find.byKey(const ValueKey('close-window-card')));
      expect(card.width, 420);
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(1020));
      expect(hits, isEmpty);
    });

    testWidgets('每个按钮只回调自己那一个动作', (tester) async {
      final hits = await pumpClose(tester);
      await tester.tap(find.text('取消'));
      await tester.tap(find.text('不再提示'));
      await tester.tap(find.text('最小化'));
      await tester.tap(find.text('关闭'));
      expect(hits, ['cancel', 'never', 'minimize', 'close']);
    });
  });

  group('扫描页三态', () {
    // 扫描中的那一格里有循环 Lottie，所以这里一律用 pump()：pumpAndSettle
    // 等不到动画停下来。
    Future<StreamController<List<CleanItem>>> pumpScanPage(WidgetTester tester,
        {bool readOnly = false,
        String? summaryPrefix = '存在重复文件共',
        String itemUnit = '组'}) async {
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
                  actionLabel: '删除重复文件',
                  readOnly: readOnly,
                  summaryPrefix: summaryPrefix,
                  itemUnit: itemUnit,
                  scan: () => controller.stream))));
      await tester.pump();
      return controller;
    }

    testWidgets('结果没回来之前只有「正在检测…」，不许先判「很干净」', (tester) async {
      await pumpScanPage(tester);
      expect(find.text('正在检测…'), findsOneWidget);
      expect(find.text('暂无可清理项'), findsNothing);
      expect(find.text('删除重复文件'), findsNothing);
      // 横幅收在中间，不拉成整幅：实机图上「正在检测…」贴左、「取消」贴右，
      // 中间一整条空白。
      final text = tester.getRect(find.text('正在检测…'));
      final cancel = tester.getRect(find.text('取消'));
      expect(cancel.left - text.right, lessThan(80));
      expect(cancel.right, lessThan(1020 - 100));
    });

    testWidgets('汇总行报真实条数，「全选」一次勾满也一次取消干净', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.add([
        CleanItem(path: 'a', size: 10, paths: const ['a']),
        CleanItem(path: 'b', size: 20, paths: const ['b'], checked: false),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('存在重复文件共 2 组'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('取消全选'), findsOneWidget);
      expect(
          tester
              .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
              .every((t) => t.value == true),
          isTrue);

      await tester.tap(find.text('取消全选'));
      await tester.pump();
      expect(
          tester
              .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
              .every((t) => t.value == false),
          isTrue);
    });

    testWidgets('只读页不给「全选」——系统盘那页不能摆删系统的按钮', (tester) async {
      final controller = await pumpScanPage(tester, readOnly: true);
      controller.add([CleanItem(path: r'C:\Windows', size: 100)]);
      await tester.pump();
      await tester.pump();
      expect(find.text('存在重复文件共 1 组'), findsOneWidget);
      expect(find.text('全选'), findsNothing);
      expect(find.text('删除重复文件'), findsNothing);
    });

    testWidgets('大文件结果行按参考实现那句报门槛，且与扫描参数同源', (tester) async {
      final controller = await pumpScanPage(tester,
          summaryPrefix: kLargeFileSummaryPrefix, itemUnit: '个');
      controller.add([
        CleanItem(path: r'C:\Users\Admin\big.bin', size: 80),
        CleanItem(path: r'C:\Users\Admin\big2.bin', size: 120),
      ]);
      await tester.pump();
      await tester.pump();
      // 「超出 50MB 文件共」(:559)：门槛必须出现在这一行里
      expect(find.text('超出 50MB 文件共 2 个'), findsOneWidget);
      // 前缀由门槛常量拼出来，扫的时候也是同一个常量——两处不允许各写一个数
      expect(kLargeFileMinMb, 50);
      expect(kLargeFileSummaryPrefix, contains('${kLargeFileMinMb}MB'));
    });

    testWidgets('空结果才是「很干净」，且不给清理按钮', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.add([]);
      await tester.pump();
      await tester.pump();
      expect(find.text('暂无可清理项'), findsOneWidget);
      expect(find.text('删除重复文件'), findsNothing);
    });

    testWidgets('有结果才出行目与清理按钮', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.add(
          [CleanItem(path: r'C:\Users\Admin\dup_probe_test\a.bin', size: 3)]);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('dup_probe_test'), findsOneWidget);
      expect(find.text('删除重复文件'), findsOneWidget);
      expect(find.text('暂无可清理项'), findsNothing);
    });

    testWidgets('只读结果页不画勾选框、也不给清理按钮', (tester) async {
      final controller = await pumpScanPage(tester, readOnly: true);
      controller.add([
        CleanItem(path: r'C:\Windows', size: 15817),
        CleanItem(path: r'C:\Program Files', size: 6229),
      ]);
      await tester.pump();
      await tester.pump();
      // 系统盘文件页列的是 C:\Windows 这种目录，勾选框 +「删除重复文件」等于
      // 摆一个全选删系统的按钮。
      expect(find.text(r'C:\Windows'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('删除重复文件'), findsNothing);
    });

    testWidgets('扫描报错进错误态而不是空态', (tester) async {
      final controller = await pumpScanPage(tester);
      controller.addError(ScanException('重复文件扫描已取消'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('扫描未完成：重复文件扫描已取消'), findsOneWidget);
      expect(find.text('暂无可清理项'), findsNothing);
    });
  });

  group('结果页可释放合计与删除进行中', () {
    test('合计只算勾选项，GB/MB 按量级换档', () {
      expect(reclaimableText(0), '0 MB');
      expect(reclaimableText(812), '812 MB');
      expect(reclaimableText(1024), '1.0 GB');
      expect(reclaimableText(2457), '2.4 GB');
      final items = [
        CleanItem(path: 'a', size: 300),
        CleanItem(path: 'b', size: 500, checked: false),
      ];
      expect(selectedTotalMb(items), 300);
      items[1].checked = true;
      expect(selectedTotalMb(items), 800);
    });

    Future<void> pumpResults(WidgetTester tester,
        {List<CleanItem>? items,
        bool readOnly = false,
        Future<void> Function(List<CleanItem>)? onClean}) async {
      tester.view.physicalSize = const Size(1020, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = StreamController<List<CleanItem>>();
      addTearDown(c.close);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScanPageScaffold(
                  title: '重复文件',
                  subtitle: '清理电脑中的重复文件',
                  cancelKey: 'dup_file',
                  actionLabel: '删除重复文件',
                  readOnly: readOnly,
                  summaryPrefix: '存在重复文件共',
                  itemUnit: '组',
                  onClean: onClean,
                  scan: () => c.stream))));
      c.add(items ??
          [
            CleanItem(path: r'C:\a.bin', size: 300),
            CleanItem(path: r'C:\b.bin', size: 500),
          ]);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('「清理所选项可释放」跟着勾选状态走（:569 + 实测合计）', (tester) async {
      await pumpResults(tester);
      expect(find.text('清理所选项可释放 800 MB'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      expect(find.text('清理所选项可释放 300 MB'), findsOneWidget);
      expect(find.text('清理所选项可释放 800 MB'), findsNothing);
    });

    testWidgets('一个都没勾时不给这行，也不编一个 0 MB 出来', (tester) async {
      await pumpResults(tester, items: [
        CleanItem(path: r'C:\a.bin', size: 300, checked: false),
      ]);
      expect(find.textContaining('清理所选项可释放'), findsNothing);
    });

    testWidgets('只读的系统盘页不给这一行', (tester) async {
      await pumpResults(tester, readOnly: true);
      expect(find.textContaining('清理所选项可释放'), findsNothing);
    });

    testWidgets('删除确认按「个文件将被删除」报数，一组重复算多份（:556）', (tester) async {
      // 两行：一行是单文件，一行是 3 份重复——按"项"数会少报要删的文件数
      await pumpResults(tester, items: [
        CleanItem(path: r'C:\a.bin', size: 300, paths: const [r'C:\a.bin']),
        CleanItem(
            path: '3 份重复：b.bin',
            size: 100,
            paths: const [r'C:\b1.bin', r'C:\b2.bin', r'C:\b3.bin']),
      ]);
      await tester.tap(find.text('删除重复文件'));
      await tester.pumpAndSettle();
      expect(
          find.text('4 个文件将被删除。'
              '所选项删除后不可恢复，请慎重清理'),
          findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('删除进行中按钮换成「正在删除」并禁用（:235）', (tester) async {
      final gate = Completer<void>();
      await pumpResults(tester, onClean: (_) => gate.future);
      expect(find.text('删除重复文件'), findsOneWidget);

      await tester.tap(find.text('删除重复文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump();

      expect(find.text('正在删除'), findsOneWidget);
      // 按标签找页面自己那颗：确认框此时还在退场动画里，byType 会多算一个
      expect(
          tester
              .widget<FilledButton>(find.ancestor(
                  of: find.text('正在删除'), matching: find.byType(FilledButton)))
              .enabled,
          isFalse);
      // 删除中要算"进行中任务"，关窗那句 :89 才对删除也成立
      expect(RunningTasks.instance.running, contains('delete:dup_file'));

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(RunningTasks.instance.anyRunning, isFalse);
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

  group('存储空间头卡', () {
    test('汇总把各盘的用量加起来，比例按真实字节算', () {
      final disks = [
        DiskInfo(letter: 'C', total: 100 << 30, free: 4 << 30),
        DiskInfo(letter: 'D', total: 50 << 30, free: 40 << 30),
      ];
      // 容量一位小数（`>> 30` 那种整除会把不足 1G 的盘写成「0G」），
      // 具体规则见 capacity_format_test.dart
      expect(storageSummaryText(disks), '已用存储空间 106.0G / 150.0G（71%）');
    });

    test('没有盘时说实话，不显示 0G / 0G 假装读到了', () {
      expect(storageSummaryText(const []), '未检测到磁盘');
    });
  });

  group('进程页计数行', () {
    test('没读到数据时不给「0 个」这种假数据', () {
      expect(processCountLine(null), isNull);
    });

    test('读到几条报几条，措辞取参考实现自带的「个应用进程运行中」', () {
      expect(processCountLine(0), '0 个应用进程运行中');
      expect(processCountLine(37), '37 个应用进程运行中');
    });
  });

  group('网速页时延口径', () {
    test('亚毫秒链路不写成「0 ms」，没连上不报 0', () {
      expect(latencyText(0, reachable: true), '<1 ms');
      expect(latencyText(12, reachable: true), '12 ms');
      expect(latencyText(0, reachable: false), '不可达');
    });
  });

  group('进行中任务与关窗提醒', () {
    setUp(RunningTasks.instance.reset);

    Future<void> pumpScan(
        WidgetTester tester, StreamController<List<CleanItem>> c) async {
      tester.view.physicalSize = const Size(1020, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScanPageScaffold(
                  title: '重复文件',
                  subtitle: '基于内容指纹查找重复文件',
                  cancelKey: 'dup_file',
                  actionLabel: '删除重复文件',
                  scan: () => c.stream))));
      await tester.pump();
    }

    test('按 cancelKey 去重登记，重复销记不报错', () {
      expect(RunningTasks.instance.anyRunning, isFalse);
      RunningTasks.instance.begin('dup_file');
      RunningTasks.instance.begin('dup_file');
      expect(RunningTasks.instance.running, {'dup_file'});
      RunningTasks.instance.end('dup_file');
      RunningTasks.instance.end('dup_file');
      expect(RunningTasks.instance.anyRunning, isFalse);
    });

    testWidgets('扫描中算"有任务在跑"，出结果后销记', (tester) async {
      final c = StreamController<List<CleanItem>>();
      addTearDown(c.close);
      await pumpScan(tester, c);
      expect(RunningTasks.instance.anyRunning, isTrue);

      c.add([]);
      await tester.pump();
      await tester.pump();
      expect(RunningTasks.instance.anyRunning, isFalse);
    });

    testWidgets('扫描失败点「重新加载」：真的再起一轮，旧一轮的迟到回调抹不掉登记',
        (tester) async {
      final rounds = <StreamController<List<CleanItem>>>[];
      addTearDown(() {
        for (final c in rounds) {
          if (!c.isClosed) c.close();
        }
      });
      tester.view.physicalSize = const Size(1020, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScanPageScaffold(
                  title: '重复文件',
                  subtitle: '基于内容指纹查找重复文件',
                  cancelKey: 'dup_file',
                  actionLabel: '删除重复文件',
                  scan: () {
                    final c = StreamController<List<CleanItem>>();
                    rounds.add(c);
                    return c.stream;
                  }))));
      await tester.pump();

      rounds.first.addError(ScanException('重复文件扫描已取消'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('扫描未完成：重复文件扫描已取消'), findsOneWidget);
      expect(rounds.length, 1);

      await tester.tap(find.widgetWithText(TextButton, '重新加载'));
      await tester.pump();
      // 「重新加载」必须真的重新执行扫描（新建一条流），不是把同一句失败再画一遍。
      expect(rounds.length, 2);
      expect(find.text('正在检测…'), findsOneWidget);
      expect(find.textContaining('扫描未完成'), findsNothing);
      expect(RunningTasks.instance.running, contains('dup_file'));

      // 上一轮的订阅已经断掉：它晚到的结果不能再按同一个键把正在跑的这轮销掉，
      // 否则关窗时那句「关闭窗口将会取消正在进行中的任务」就落空了。
      rounds.first.add([CleanItem(path: 'stale', size: 1, paths: const ['stale'])]);
      await tester.pump();
      await tester.pump();
      expect(RunningTasks.instance.running, contains('dup_file'));
      expect(find.text('正在检测…'), findsOneWidget);

      rounds[1].add([
        CleanItem(
            path: 'dup_probe_test', size: 10, paths: const ['dup_probe_test'])
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('dup_probe_test'), findsOneWidget);
      expect(RunningTasks.instance.anyRunning, isFalse);
    });

    testWidgets('结果没回来就离开页面，登记必须撤掉（同时取消扫描）', (tester) async {
      final c = StreamController<List<CleanItem>>();
      addTearDown(c.close);
      await pumpScan(tester, c);
      expect(RunningTasks.instance.anyRunning, isTrue);

      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();
      expect(RunningTasks.instance.anyRunning, isFalse);
    });

    testWidgets('关窗确认只在真有任务时带 :89 那句提醒', (tester) async {
      Future<void> show(WidgetTester tester) => pumpAtWindowSize(
          tester,
          CloseWindowCard(
            notice: RunningTasks.instance.anyRunning
                ? kRunningTaskCloseNotice
                : null,
            onMinimize: () {},
            onClose: () {},
            onCancel: () {},
            onNever: () {},
          ));

      await show(tester);
      expect(find.text('关闭窗口将会取消正在进行中的任务。'), findsNothing);

      RunningTasks.instance.begin('deep_clean');
      await show(tester);
      expect(find.text('关闭窗口将会取消正在进行中的任务。'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
