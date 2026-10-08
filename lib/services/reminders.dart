import 'package:shared_preferences/shared_preferences.dart';

/// 阈值弹窗提醒的读写处 —— 「弹窗上点不再提示」和「设置里重新开启」共用这一份状态。
///
/// 证据：参考实现文案表里有一批「当…超过阈值时，系统将自动触发此提示」的句子
/// （zh_strings.txt:566/:597/:266/:192）。这种第三人称描述不会出现在弹窗正文里
/// （弹窗正文是「您的电脑CPU使用率已达」:291 那种第二人称），只会出现在描述
/// 某项开关干什么的位置上；再加上 :466「将关闭此类弹提醒功能，您可在
/// PC Manager-设置 中再次开启」直接点名了设置页，可以确定参考实现的设置页
/// 有一组按提醒类型分行的开关。分区名取自带的「高负载提示」:236。
class ReminderKind {
  const ReminderKind({
    required this.key,
    required this.title,
    required this.description,
  });

  /// 与参考实现点击事件里的窗口键名同一套（click_AppCompatibility_window_* 等）。
  final String key;

  /// 行标题：能对上参考实现自带弹窗标题的用原文（:262/:148），
  /// 对不上的（CPU）沿用我们弹窗里已有的标题，不在这里另造一个新叫法。
  final String title;

  /// 行描述，逐字取参考实现文案表。
  final String description;
}

const String kReminderSectionTitle = '高负载提示';

/// 「不再提示」按下去之后给用户的落点说明，逐字取 zh_strings.txt:466。
const String kReminderMutedNotice = '将关闭此类弹提醒功能，您可在PC Manager-设置 中再次开启';

/// 顺序与首页阈值巡检顺序一致（CPU → 内存 → 系统盘 → 应用兼容性）；
/// 参考实现没留下这四项的排列证据。
const List<ReminderKind> kReminderKinds = [
  ReminderKind(
    key: 'CPU_window',
    title: 'CPU 占用过高',
    description: '当CPU使用率超过阈值时，系统将自动触发此提示。',
  ),
  ReminderKind(
    key: 'RAM_window',
    title: '内存高负载提示',
    description: '当内存使用率超过阈值时，系统将自动触发此提示，并支持一键释放内存。',
  ),
  ReminderKind(
    key: 'SystemDisk_window',
    title: '系统盘空间不足提示',
    description: '当系统盘使用率超过阈值时，系统将自动触发此提示，并支持深度清理。',
  ),
  ReminderKind(
    key: 'AppCompatibility_window',
    title: '应用兼容性',
    description: '当安装不兼容应用时，系统将自动触发此提示。',
  ),
];

String reminderPrefKey(String kindKey) => 'never_$kindKey';

Future<bool> isReminderMuted(String kindKey) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(reminderPrefKey(kindKey)) ?? false;
}

Future<void> setReminderMuted(String kindKey, {required bool muted}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(reminderPrefKey(kindKey), muted);
}

/// 一次运行内同类提醒只弹一次：首页每 2s 巡检一轮，不拦住的话同一个弹窗会排队刷屏。
final Set<String> _shownThisRun = {};

/// 认领这次弹窗。返回 true 表示本轮还没弹过；false 表示已经弹过，调用方应直接返回。
bool claimReminder(String kindKey) => _shownThisRun.add(kindKey);

/// 撤销认领，用于「不再提示」之后的状态复位，以及设置里重新开启。
void releaseReminder(String kindKey) => _shownThisRun.remove(kindKey);

void releaseAllReminders() => _shownThisRun.clear();
