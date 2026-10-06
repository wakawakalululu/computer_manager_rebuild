/// 应用兼容性检查（原程序的 `AppCompatibility_window`）。
///
/// 逆向依据：
/// - 事件表里的 `click_AppCompatibility_window_uninstall` / `_cancel` / `_never`
///   （`docs/extracted/click_events.txt`）证明原程序有一个会弹窗、可一键卸载的
///   兼容性检查；
/// - 三句原话：「以下应用可能存在兼容性问题，建议卸载」（`zh_strings.txt:588`）、
///   「当安装不兼容应用时，系统将自动触发此提示。」（`:192`）、
///   「已安装应用兼容云电脑环境」（`:151`，全干净时的状态行）。
///
/// 关于「不兼容清单从哪来」：原程序那份在运营方后端，逆向产物里没有任何一份
/// 清单能证明哪些应用被判为不兼容。净室分支**不假装知道这份清单**——判定标准
/// 改由部署方在随包 `config.ini` 的 `[compat] incompatible` 里给出（与 baseHost
/// 同一个文件、同一种「运维填」的处理方式）。清单为空时这一项就是「未配置」，
/// 界面上既不报问题，也不说「兼容」——没检查过就没有结论。
library;

import 'dart:io';

import 'feedback_service.dart';
import 'rust_api.dart';

/// 命中清单里的关键字（子串、大小写不敏感）即视为不兼容应用。
/// 分隔符同时收半角与全角逗号分号：这份清单是给人手填的，中文输入法打出来就是
/// `，`/`；`，只认半角会让整条配置变成一个匹配不到任何东西的长串。
List<String> readIncompatiblePatterns(File file) =>
    (readIniSection(file, 'compat')['incompatible'] ?? '')
        .split(RegExp(r'[,;，；]'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();

Future<List<String>> loadIncompatiblePatterns({String? configDir}) async =>
    readIncompatiblePatterns(
        File('${configDir ?? File(Platform.resolvedExecutable).parent.path}'
            '\\config.ini'));

/// 按注册表 DisplayName 匹配。保持列表原有顺序，同一条规则命中多个应用时不重复。
List<AppEntry> findIncompatibleApps(
    List<AppEntry> apps, List<String> patterns) {
  if (patterns.isEmpty) return const [];
  final names = patterns.map((p) => p.toLowerCase()).toList();
  return apps
      .where((a) => names.any((p) => a.name.toLowerCase().contains(p)))
      .toList();
}

/// 弹窗正文。标题与那句「建议卸载」都用原程序自带的串。
/// 只列名字不列版本：弹窗正文只有三行余地，版本号在这里没有判断价值。
const String kCompatTitle = '应用兼容性';
const String kCompatBodyHead = '以下应用可能存在兼容性问题，建议卸载';

/// 同一句原话的后半截，给体检那种单行结论用（「N 个应用可能存在兼容性问题」）。
const String kCompatBodyTail = '可能存在兼容性问题';

/// 全干净时的状态行（原话，`:151`）。只有真的配了清单才允许说这句话。
const String kCompatCleanMessage = '已安装应用兼容云电脑环境';

String compatBody(List<AppEntry> hits) => [
      kCompatBodyHead,
      for (final a in hits.take(3)) a.name,
      if (hits.length > 3) '…等 ${hits.length} 项',
    ].join('\n');
