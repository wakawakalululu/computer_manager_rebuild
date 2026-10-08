import 'package:computer_manager/pages/tool_box_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 智慧盘页：判据钉在**选盘规则**、**路径拼法**与**按磁盘实测状态开按钮**三件事上。
///
/// 出处（全部来自参考实现自带材料）：
///  * 标题「智慧盘」`docs/extracted/zh_strings.txt:140`，页面类 `_SecurityDiskPageState`
///  * 说明 `:456`「在运行内存不足时提升运行速度，清理后会在**剩余空间最大**的盘符再次生成」
///  * 机制 codec `crateApiUtilsRCreateTmepEmptyFileWhitSize`（`frb_calls.txt:86`）
void main() {
  DiskInfo disk(String letter, int total, int free) =>
      DiskInfo(letter: letter, total: total, free: free);

  group('选盘规则', () {
    test('挑剩余空间最大的那张，不是总容量最大、也不是使用率最低', () {
      // D 盘总容量最小但剩余最多 —— 按"总容量"会选 C，按"使用率"会选 E
      final picked = pickSmartDiskDrive([
        disk('C', 500 << 30, 40 << 30),
        disk('D', 120 << 30, 90 << 30),
        disk('E', 1000 << 30, 5 << 30),
      ]);
      expect(picked?.letter, 'D');
    });

    test('剩余为 0 的盘不参与（写 0 字节的"可用空间"上没有意义）', () {
      final picked = pickSmartDiskDrive([
        disk('C', 500 << 30, 0),
        disk('D', 120 << 30, 3 << 30),
      ]);
      expect(picked?.letter, 'D');
    });

    test('全部不可用返回 null，界面据此说"未找到可用磁盘"', () {
      expect(pickSmartDiskDrive([]), isNull);
      expect(pickSmartDiskDrive([disk('C', 100, 0)]), isNull);
    });
  });

  // 反斜杠是这里的关键：写成 `/` 或漏分隔符，路径会落到进程当前目录，
  // 而不是指定盘符的根——那既没生成在该盘，也没法按预期清理。
  group('占位文件路径', () {
    test('用反斜杠分隔并落在该盘根目录', () {
      expect(smartDiskPath('D'), r'D:\cm_smart_disk.tmp');
    });

    test('不含正斜杠', () {
      expect(smartDiskPath('C'), isNot(contains('/')));
    });
  });

  group('按钮开关跟的是磁盘实测状态，不是本次点过什么', () {
    SmartDiskActions actions({
      List<DiskInfo>? disks,
      bool exists = false,
      Object? throwError,
      List<String>? made,
      List<String>? removed,
    }) =>
        SmartDiskActions(
          listDisks: () async {
            if (throwError != null) throw throwError;
            return disks ?? [disk('D', 120 << 30, 90 << 30)];
          },
          makeFile: (path, size) async {
            (made ?? []).add(path);
            return path;
          },
          removeFile: (path) async => (removed ?? []).add(path),
          pathExists: (path) async => exists,
        );

    Future<void> pump(WidgetTester tester, SmartDiskActions a) async {
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: SecurityDiskPage(actions: a))));
      await tester.pumpAndSettle();
    }

    testWidgets('盘上已有占位文件时说「已生成」并开着清理、关掉生成', (tester) async {
      await pump(tester, actions(exists: true));
      expect(find.textContaining('已生成'), findsOneWidget);
      final clean = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(clean.onPressed, isNotNull, reason: '文件在盘上就必须能清掉');
      final gen = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(gen.onPressed, isNull, reason: '已经存在还让再点是假动作');
    });

    testWidgets('盘上没有时说「未生成」并开着生成、关掉清理', (tester) async {
      await pump(tester, actions(exists: false));
      expect(find.textContaining('未生成'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
      expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
          reason: '没有文件时给清理＝点了没反应的按钮');
    });

    testWidgets('读盘失败给「重新加载」：点它真的再读一次，错误消失并列出盘',
        (tester) async {
      // 上面那些用例都只用 helper 的 `throwError`——它每次都抛，所以钉得住"失败态长什么样"，
      // 但钉不住"失败了之后有没有出路"。这里要的是后者：第一次抛、第二次成功。
      var calls = 0;
      final a = SmartDiskActions(
        listDisks: () async {
          calls++;
          if (calls == 1) throw Exception('桥没通');
          return [disk('D', 120 << 30, 90 << 30)];
        },
        makeFile: (path, size) async => path,
        removeFile: (path) async {},
        pathExists: (path) async => false,
      );
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: SecurityDiskPage(actions: a))));
      await tester.pumpAndSettle();
      // 失败那一支原来只有一行红字，而它把下面整块（含生成/清理按钮）都顶掉了：
      // `_load()` 又只有 initState 调过，于是读盘失败后界面上没有任何能再读一次的东西。
      expect(find.textContaining('读取磁盘信息失败：桥没通'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      final retry = find.widgetWithText(TextButton, '重新加载');
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '「重新加载」必须真的再读一次，不是把红字再画一遍');
      expect(find.textContaining('读取磁盘信息失败'), findsNothing);
      expect(find.textContaining('目标磁盘：D'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('读盘失败时说出失败原因，不摆"未生成"当结论', (tester) async {
      await pump(tester, actions(throwError: StateError('枚举磁盘失败')));
      expect(find.textContaining('读取磁盘信息失败'), findsOneWidget);
      // 没读到就不该同时报"未生成"——那是在替一个没查过的问题下结论
      expect(find.textContaining('未生成'), findsNothing);
    });

    testWidgets('一张盘都挑不出来时说"未找到可用磁盘"', (tester) async {
      await pump(tester, actions(disks: const []));
      expect(find.text('未找到可用磁盘'), findsOneWidget);
    });

    testWidgets('点生成用的是剩余空间最大那张盘的路径', (tester) async {
      final made = <String>[];
      await pump(
          tester,
          actions(disks: [
            disk('C', 500 << 30, 1 << 30),
            disk('E', 200 << 30, 50 << 30)
          ], made: made));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(made, [r'E:\cm_smart_disk.tmp']);
    });
  });
}
