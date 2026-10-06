import 'dart:io';

import 'package:computer_manager/services/app_compatibility.dart';
import 'package:computer_manager/services/feedback_service.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 兼容性判定的纯逻辑：清单从随包 config.ini 读，匹配只看 DisplayName。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cm_compat_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeConfig(String body) =>
      File('${tmp.path}\\config.ini')..writeAsStringSync(body);

  AppEntry app(String name, {String version = ''}) => AppEntry(
      name: name,
      version: version,
      publisher: 'p',
      uninstallKey: 'k\\$name',
      displayIcon: '');

  group('清单解析', () {
    test('逗号与分号都算分隔符，去空白、转小写、空项丢弃', () {
      final f = writeConfig('[config]\nbaseHost = gw.invalid\n'
          '[compat]\nincompatible = DingTalk, 企业微信 ;git,，\n');
      expect(readIncompatiblePatterns(f), ['dingtalk', '企业微信', 'git']);
    });

    test('没配、留空、或整段缺失都是「没有判定标准」', () {
      expect(readIncompatiblePatterns(writeConfig('[config]\n')), isEmpty);
      expect(
          readIncompatiblePatterns(writeConfig('[compat]\nincompatible =\n')),
          isEmpty);
      expect(readIncompatiblePatterns(File('${tmp.path}\\none.ini')), isEmpty);
    });

    test('别的段里的 incompatible 不算数，baseHost 也不被 compat 段污染', () {
      final f = writeConfig('[compat]\nincompatible = git\n'
          '[other]\nincompatible = should-be-ignored\n');
      expect(readIncompatiblePatterns(f), ['git']);
      expect(readBaseHost(f), isNull);
    });
  });

  group('匹配', () {
    test('按 DisplayName 做大小写不敏感的子串匹配，保持列表顺序', () {
      final apps = [app('Git'), app('DingTalk'), app('腾讯文档')];
      expect(
          findIncompatibleApps(
                  apps,
                  readIncompatiblePatterns(
                      writeConfig('[compat]\nincompatible = dingtalk,GIT\n')))
              .map((a) => a.name),
          ['Git', 'DingTalk']);
    });

    test('一条规则命中多个应用时各算一项，不重复', () {
      final hits = findIncompatibleApps(
          [app('Visual Studio 2022'), app('Visual Studio Code')], ['visual']);
      expect(hits.map((a) => a.name),
          ['Visual Studio 2022', 'Visual Studio Code']);
    });

    test('清单为空时不返回任何命中（哪怕应用名里真有那个词）', () {
      expect(findIncompatibleApps([app('git')], const []), isEmpty);
    });
  });

  group('弹窗正文', () {
    test('第一行是原话，最多列三个名字，再多只报数量', () {
      final hits = [app('A'), app('B'), app('C'), app('D'), app('E')];
      expect(compatBody(hits).split('\n'), [
        kCompatBodyHead,
        'A',
        'B',
        'C',
        '…等 5 项',
      ]);
    });

    test('三句文案都取参考实现自带的串', () {
      expect(kCompatBodyHead, '以下应用可能存在兼容性问题，建议卸载');
      expect(kCompatCleanMessage, '已安装应用兼容云电脑环境');
    });
  });
}
