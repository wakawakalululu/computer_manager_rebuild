import 'package:computer_manager/app.dart';
import 'package:computer_manager/services/click_report.dart';
import 'package:computer_manager/services/reminders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置—高负载提示」这一组的契约。
///
/// 参考实现里四类阈值弹窗各自配了一句「当…时，系统将自动触发此提示」
/// （zh_strings.txt:566/:597/:266/:192），加上 :466 点名「您可在PC Manager-设置 中
/// 再次开启」，可以确定设置页有对应开关。这里钉住的就是那几句原文：
/// 文案改动必须回到文案表里找证据，不能顺手改写。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    releaseAllReminders();
  });

  group('提醒类型表', () {
    test('四条描述逐字取参考实现文案表，不自己改写', () {
      expect(
        kReminderKinds.map((k) => k.description).toList(),
        [
          '当CPU使用率超过阈值时，系统将自动触发此提示。',
          '当内存使用率超过阈值时，系统将自动触发此提示，并支持一键释放内存。',
          '当系统盘使用率超过阈值时，系统将自动触发此提示，并支持深度清理。',
          '当安装不兼容应用时，系统将自动触发此提示。',
        ],
      );
      expect(kReminderSectionTitle, '高负载提示');
      expect(kReminderMutedNotice, '将关闭此类弹提醒功能，您可在PC Manager-设置 中再次开启');
    });

    test('键名就是参考实现点击事件里的窗口名，埋点才认得', () {
      final sent = <String>[];
      for (final k in kReminderKinds) {
        sent.add(clickEventFor(k.key, 'cancel'));
      }
      expect(sent, [
        'click_CPU_window_cancel',
        'click_RAM_window_cancel',
        'click_SystemDisk_window_cancel',
        'click_AppCompatibility_window_cancel',
      ]);
      expect(kReminderKinds.map((k) => k.title).toSet().length, 4);
    });
  });

  group('静音状态读写', () {
    test('默认没静音；弹窗上点「不再提示」写下的键，设置页读的是同一份', () async {
      expect(await isReminderMuted('RAM_window'), isFalse);
      await setReminderMuted('RAM_window', muted: true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('never_RAM_window'), isTrue);
      expect(await isReminderMuted('RAM_window'), isTrue);
    });

    test('设置页里重新打开会撤销本轮认领，不必重启进程', () async {
      expect(claimReminder('CPU_window'), isTrue);
      expect(claimReminder('CPU_window'), isFalse); // 本轮已经弹过
      releaseReminder('CPU_window');
      expect(claimReminder('CPU_window'), isTrue);
    });
  });

  group('弹窗读静音状态', () {
    Future<void> show(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SizedBox(width: 200, height: 200))));
    }

    testWidgets('已静音的类型直接返回，不排弹窗', (tester) async {
      await show(tester);
      await setReminderMuted('SystemDisk_window', muted: true);
      var acted = false;
      await ThresholdPopups.maybeShow(
        key: 'SystemDisk_window',
        title: kReminderKinds[2].title,
        body: 'x',
        actionLabel: '深度清理',
        actionId: 'deepclean',
        action: () => acted = true,
      );
      expect(find.text('深度清理'), findsNothing);
      expect(acted, isFalse);
    });

    testWidgets('同类提醒一次运行内只弹一次', (tester) async {
      await show(tester);
      // 预先认领，模拟本轮已经弹过；未认领的分支要真渲染 SmartDialog 覆盖层，
      // 版式由 visual_contract_test.dart 里的 ThresholdPopupCard 直接测。
      expect(claimReminder('RAM_window'), isTrue);
      await ThresholdPopups.maybeShow(
        key: 'RAM_window',
        title: '内存高负载提示',
        body: 'x',
        actionLabel: '立即加速',
        actionId: 'expedite',
        action: () {},
      );
      expect(find.text('立即加速'), findsNothing);
    });
  });
}
