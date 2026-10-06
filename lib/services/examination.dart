import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_compatibility.dart';
import 'rust_api.dart';

/// 体检单项结论。
enum ExamineVerdict { ok, needFix, failed, skipped }

class ExamineItem {
  const ExamineItem({
    required this.key,
    required this.title,
    required this.verdict,
    required this.detail,
    this.route,
    this.actionLabel,
  });

  final String key;
  final String title;
  final ExamineVerdict verdict;

  /// 实测出来的一句话结论，界面上原样显示，不再套「检测完成」这类模板话
  final String detail;

  /// 需要处理时直达的二级页；为空表示这项没有可跳转的详情
  final String? route;

  /// 跳转按钮的文案（「去清理」「去管理」）
  final String? actionLabel;

  bool get needsAction => verdict == ExamineVerdict.needFix;
}

/// 常驻守护服务名，与 keep_alive 安装时一致。
const keepAliveService = 'CmKeepAlive';

/// 自启项超过这个数才提「可优化」：参考实现只说「可优化开机启动项」没给阈值，
/// 而几乎每台机器都有若干条自启，取 0 会让这一项永远是红的。
const startupSuggestThreshold = 6;

/// 上次体检时间的偏好键。camelCase，与 `feedbackAgreeUploadLog` 一致。
const lastExaminationKey = 'lastExaminationAt';

/// 结论徽标。措辞取参考实现文案表自带的「可优化」「已优化」
///（`specs/zh_strings.txt:82`、`:572`），不自己另造「待处理/正常」。
/// `skipped` 是「没配判定标准，这一项根本没检查」，不能说成「已优化」。
String examineBadge(ExamineItem item) => switch (item.verdict) {
      ExamineVerdict.ok => '已优化',
      ExamineVerdict.needFix => '可优化',
      ExamineVerdict.failed => '未取到',
      ExamineVerdict.skipped => '未配置',
    };

/// 读上次体检时间（毫秒）。没记录过时返回 null。
Future<int?> readLastExaminationAt() async =>
    (await SharedPreferences.getInstance()).getInt(lastExaminationKey);

/// 记一次体检完成的时间。
Future<void> writeLastExaminationAt(int millis) async =>
    (await SharedPreferences.getInstance()).setInt(lastExaminationKey, millis);

/// 面板状态栏那一行。参考实现首页状态栏就写着「上次体检时间」
///（`specs/zh_strings.txt:282`），从没跑过时不拿假时间糊上去。
String formatLastExamination(int? millis) => millis == null
    ? '首次体检，检查过程不改动任何文件'
    : '上次体检时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(millis))} · 检查不改动文件';

/// 体检数据源。默认全部走 Rust 桥；单测注入假实现，避免为了跑通流程依赖真机。
class ExamineSource {
  ExamineSource({
    required this.netAvailable,
    required this.recycleBin,
    required this.startupList,
    required this.memoryInfo,
    required this.diskList,
    required this.serviceStatus,
    required this.incompatibleApps,
  });

  factory ExamineSource.fromBridge() => ExamineSource(
        netAvailable: RustApi.instance.netAvailable,
        recycleBin: RustApi.instance.getRecycleBin,
        startupList: RustApi.instance.readStartupList,
        memoryInfo: RustApi.instance.readMemory2,
        diskList: RustApi.instance.getDiskInfoList,
        serviceStatus: RustApi.instance.serviceStatus,
        incompatibleApps: () async {
          final patterns = await loadIncompatiblePatterns();
          // null 表示「没配判定标准」，与「配了且一个都不命中」是两回事
          if (patterns.isEmpty) return null;
          return findIncompatibleApps(
              await RustApi.instance.checkApp2(), patterns);
        },
      );

  final Future<bool> Function() netAvailable;

  /// `[字节数, 人类可读]`，判空用字节那一位
  final Future<List<String>> Function() recycleBin;
  final Future<List<StartupItem>> Function() startupList;
  final Future<MemoryInfo> Function() memoryInfo;
  final Future<List<DiskInfo>> Function() diskList;
  final Future<String> Function(String serviceName) serviceStatus;

  /// 命中不兼容清单的应用；`null` = 清单没配，这一项不做判定
  final Future<List<AppEntry>?> Function() incompatibleApps;
}

/// 全面体检：逐项实测，逐项出结论。
///
/// 只做「检查」。修复动作一律不在这里执行——参考实现的体检页也是给出「修复方法」
/// 并跳进对应二级页，删除类动作在那里还要过一次二次确认。
class ExaminationRunner {
  ExaminationRunner(this._source);

  final ExamineSource _source;

  /// 顺序跑完全部检查项，每完成一项回调一次，界面据此把「正在检查…」逐行点亮。
  Future<List<ExamineItem>> run(
      {void Function(List<ExamineItem> done)? onProgress}) async {
    final done = <ExamineItem>[];
    for (final check in [
      _component,
      _network,
      _memory,
      _startup,
      _recycleBin,
      _disk,
      _app,
    ]) {
      done.add(await check());
      onProgress?.call(done);
    }
    return done;
  }

  Future<ExamineItem> _guard(
      String key, String title, Future<ExamineItem> Function() body) async {
    try {
      return await body();
    } catch (e) {
      // 单项取不到数不能整轮报废：报出是哪项、为什么。
      return ExamineItem(
          key: key,
          title: title,
          verdict: ExamineVerdict.failed,
          detail: '未取得数据：${bridgeErrorText(e)}');
    }
  }

  Future<ExamineItem> _component() => _guard('component', '常驻组件', () async {
        final s = await _source.serviceStatus(keepAliveService);
        if (s == 'RUNNING') {
          return _ok('component', '常驻组件', '守护服务运行中');
        }
        return _fix(
            key: 'component',
            title: '常驻组件',
            detail: s == 'STOPPED' ? '守护服务已安装但未运行' : '未检测到守护服务',
            route: '/app_setting_route',
            actionLabel: '去设置');
      });

  Future<ExamineItem> _network() => _guard('network', '网络', () async {
        return await _source.netAvailable()
            ? _ok('network', '网络', '外网探测可达')
            : _fix(
                key: 'network',
                title: '网络',
                detail: '外网探测无响应',
                route: '/tool_box_dashboard/net_speed_test',
                actionLabel: '看实测');
      });

  Future<ExamineItem> _memory() => _guard('memory', '内存', () async {
        final m = await _source.memoryInfo();
        final pct = (m.ratio * 100).round();
        return m.ratio < 0.8
            ? _ok('memory', '内存', '占用 $pct%')
            : _fix(
                key: 'memory',
                title: '内存',
                detail: '占用 $pct%，后台进程可释放',
                route: '/app_manage_dashboard/process_info',
                actionLabel: '看进程');
      });

  Future<ExamineItem> _startup() => _guard('startup', '开机启动项', () async {
        final items = await _source.startupList();
        final on = items.where((e) => e.enabled).length;
        if (on <= startupSuggestThreshold) {
          return _ok('startup', '开机启动项', on == 0 ? '没有开机自启项' : '$on 项开机自启');
        }
        return _fix(
            key: 'startup',
            title: '开机启动项',
            detail: '$on 项开机自启，可关掉不常用的',
            route: '/app_manage_dashboard/startup_manage',
            actionLabel: '去管理');
      });

  Future<ExamineItem> _recycleBin() => _guard('litter', '回收站', () async {
        final v = await _source.recycleBin();
        final bytes = int.tryParse(v.isEmpty ? '' : v.first) ?? 0;
        if (bytes == 0) return _ok('litter', '回收站', '回收站已清空');
        return _fix(
            key: 'litter',
            title: '回收站',
            detail: '占用 ${v.length > 1 ? v[1] : '$bytes B'}',
            route: '/disk_clean_dashboard',
            actionLabel: '去清理');
      });

  Future<ExamineItem> _disk() => _guard('disk', '磁盘空间', () async {
        final disks = await _source.diskList();
        if (disks.isEmpty) {
          return _ok('disk', '磁盘空间', '未检测到磁盘');
        }
        final tight = disks.where((d) => d.ratio >= 0.9).toList();
        if (tight.isEmpty) {
          final worst = disks.reduce((a, b) => a.ratio >= b.ratio ? a : b);
          return _ok('disk', '磁盘空间',
              '最满的是 ${worst.letter} 盘，已用 ${(worst.ratio * 100).round()}%');
        }
        final first = tight.first;
        return _fix(
            key: 'disk',
            title: '磁盘空间',
            detail:
                '${tight.map((d) => d.letter).join('、')} 盘已用 ${(first.ratio * 100).round()}%',
            route: '/disk_clean_dashboard/deep_clean_scan',
            actionLabel: '去清理');
      });

  /// 参考实现体检页第五张卡 `_ExaminationAnimatedAppItemCard` 对应的「应用」。
  /// 判定复用 #20 那条兼容性检查：清单没配时这一项是「未配置」，
  /// 既不算通过也不算待处理——没有标准就没有结论。
  Future<ExamineItem> _app() => _guard('app', '应用兼容性', () async {
        final hits = await _source.incompatibleApps();
        if (hits == null) {
          return ExamineItem(
              key: 'app',
              title: '应用兼容性',
              verdict: ExamineVerdict.skipped,
              detail: '未配置不兼容应用清单，未做判定');
        }
        if (hits.isEmpty) {
          return _ok('app', '应用兼容性', kCompatCleanMessage);
        }
        return _fix(
            key: 'app',
            title: '应用兼容性',
            detail: '${hits.length} 个应用$kCompatBodyTail',
            route: '/app_manage_dashboard',
            actionLabel: '去处理');
      });

  static ExamineItem _ok(String key, String title, String detail) =>
      ExamineItem(
          key: key, title: title, verdict: ExamineVerdict.ok, detail: detail);

  static ExamineItem _fix(
          {required String key,
          required String title,
          required String detail,
          required String route,
          required String actionLabel}) =>
      ExamineItem(
          key: key,
          title: title,
          verdict: ExamineVerdict.needFix,
          detail: detail,
          route: route,
          actionLabel: actionLabel);
}
