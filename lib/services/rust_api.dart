/// Rust 服务层 —— 页面与 frb 生成绑定之间的唯一适配缝。
///
/// 职责：调用 `flutter_rust_bridge_codegen` 生成的真实绑定，并把 Rust 侧的
/// 传输形态（`Vec<String>` 位置向量、`serde_json` 字符串、`BigInt` 字节数）
/// 收敛成页面使用的轻量 DTO。页面只依赖本文件，不直接依赖生成代码。
///
/// 每个方法的文档注释保留参考实现 frb codec 名（见 specs/api-map）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../src/rust/api/disk_scan.dart' as ds;
import '../src/rust/api/gui_log.dart' as gl;
import '../src/rust/api/sysinfo.dart' as si;
import '../src/rust/api/utils.dart' as ru;

class MemoryInfo {
  final int used;
  final int total;
  MemoryInfo({required this.used, required this.total});
  double get ratio => total == 0 ? 0 : used / total;
}

class CpuInfo {
  final double usage;
  final String name;
  final int cores;
  CpuInfo({required this.usage, required this.name, required this.cores});
}

class DiskInfo {
  final String letter;
  final int total;
  final int free;
  DiskInfo({required this.letter, required this.total, required this.free});
  double get ratio => total == 0 ? 0 : 1 - free / total;
}

class NetInfo {
  final String ipv4;
  final bool available;
  NetInfo({required this.ipv4, required this.available});
}

class ProcInfo {
  final int pid;
  final String name;

  /// 进程 exe 全路径，图标按它提取；无权限查询时为空
  final String exe;
  final double cpu;
  final int mem;
  ProcInfo(
      {required this.pid,
      required this.name,
      required this.exe,
      required this.cpu,
      required this.mem});
}

/// 启动项。Rust 侧无“发布者”字段，改暴露注册表位置（HKCU/HKLM/HKLM_WOW），
/// 它同时是 change_startup_status 的必需入参。
class StartupItem {
  final String name;
  final String location;
  final bool enabled;
  StartupItem(
      {required this.name, required this.location, required this.enabled});
}

class AppEntry {
  final String name;
  final String version;
  final String publisher;
  final String uninstallKey;

  /// 注册表 DisplayIcon 原值，图标提取的输入；很多应用不写该项，可能为空
  final String displayIcon;
  AppEntry(
      {required this.name,
      required this.version,
      required this.publisher,
      required this.uninstallKey,
      required this.displayIcon});
}

/// 应用图标原始像素（RGBA 行主序），由界面 ui.decodeImageFromPixels 解码成图片。
/// 服务层不依赖 dart:ui，只搬运 Rust 侧取到的字节。
class AppIcon {
  final int width;
  final int height;
  final Uint8List rgba;
  AppIcon({required this.width, required this.height, required this.rgba});
}

class PatchEntry {
  final String id;
  final String title;
  final String kind;
  PatchEntry({required this.id, required this.title, required this.kind});
}

class CleanItem {
  final String path;
  final int size;

  /// 该条目实际对应的文件路径集合。列表行可能是聚合展示（一条清理规则、
  /// 一组重复文件），此时 path 只用于显示，删除走 paths。
  final List<String> paths;
  bool checked;
  CleanItem(
      {required this.path,
      required this.size,
      List<String>? paths,
      this.checked = true})
      : paths = paths ?? const [];
}

/// 扫描失败/取消 —— 页面据此显示错误态而非“很干净”。
class ScanException implements Exception {
  ScanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 把桥层异常写成能直接给用户看的一行。
///
/// frb v2 会把 Rust 侧的 anyhow 错误包成 `AnyhowException(<原文>)`，页面原样插值
/// 就成了「扫描未完成：AnyhowException(未找到规则文件 …)」——实测深度清理页就是这么
/// 显示的。真实原因本来就在括号里，取出来；只剥这一层包装，不猜别的格式。
String bridgeErrorText(Object error) {
  final text = error.toString();
  final wrapped =
      RegExp(r'^\w*Exception\((.*)\)$', dotAll: true).firstMatch(text);
  final inner = wrapped?.group(1)?.trim();
  if (inner != null && inner.isNotEmpty) return inner;
  return text.replaceFirst('Exception: ', '');
}

/// 一次网络实测的换算结果。原始量来自 Rust：`rttMs` 是若干次 TCP 握手的往返耗时，
/// 收发字节是网卡计数器在采样窗口两端的差值，这里只做平均/极差/速率换算。
class NetSpeedResult {
  const NetSpeedResult(
      {required this.rttMs,
      required this.jitterMs,
      required this.downBps,
      required this.upBps,
      required this.probes});

  factory NetSpeedResult.from(si.NetQuality q) {
    // frb 把 Rust 的 u64 映射成 BigInt 列表，先统一收成 int 再算。
    final rtts = [for (final r in q.rttMs) r.toInt()];
    final sum = rtts.fold<int>(0, (a, b) => a + b);
    final secs = q.windowMs.toDouble() / 1000;
    return NetSpeedResult(
      rttMs: rtts.isEmpty ? 0 : (sum / rtts.length).round(),
      jitterMs: rtts.length < 2
          ? 0
          : rtts.reduce((a, b) => a > b ? a : b) -
              rtts.reduce((a, b) => a < b ? a : b),
      downBps: q.receivedBytes.toDouble() / secs,
      upBps: q.transmittedBytes.toDouble() / secs,
      probes: rtts.length,
    );
  }

  /// 平均往返时延；0 表示所有探测都没连上
  final int rttMs;

  /// 采样间的最大抖动（极差），单次采样给 0
  final int jitterMs;

  /// 采样窗口内网卡实收/实发速率，字节每秒
  final double downBps;
  final double upBps;

  /// 成功的 RTT 探测次数
  final int probes;

  bool get reachable => probes > 0;
}

class RustApi {
  RustApi._();
  static final instance = RustApi._();

  /// 最近一次深度清理扫描的原始 JSON，cleanDeepClean 需回传给 Rust
  String? _lastDeepCleanJson;

  static int _mb(int bytes) => bytes ~/ (1 << 20);

  /// 扫描根目录默认取当前用户目录（大文件/重复文件扫描范围）
  static String get _userProfile =>
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      r'C:\';

  // crateApiSysinfoMemoryRReadMemory2 → api::sysinfo::memory::read_memory2
  Future<MemoryInfo> readMemory2() async {
    final m = await si.readMemory2();
    return MemoryInfo(used: m.used.toInt(), total: m.total.toInt());
  }

  // crateApiSysinfoCupRReadCupInfo → api::sysinfo::cup::read_cup_info
  // Rust 返回 [名称, 核数, 使用率]
  Future<CpuInfo> readCupInfo() async {
    final v = await si.readCupInfo();
    return CpuInfo(
      name: v.isNotEmpty ? v[0] : '未知 CPU',
      cores: v.length > 1 ? int.tryParse(v[1]) ?? 0 : 0,
      usage: v.length > 2 ? double.tryParse(v[2]) ?? 0 : 0,
    );
  }

  // crateApiSysinfoDiskRGetDiskInfoList → api::sysinfo::disk::get_disk_info_list
  Future<List<DiskInfo>> getDiskInfoList() async {
    return [
      for (final d in await si.getDiskInfoList())
        if (!d.removable)
          DiskInfo(
              letter: d.name,
              total: d.totalBytes.toInt(),
              free: d.freeBytes.toInt())
    ];
  }

  // crateApiSysinfoNetworkRGetNetInfo → api::sysinfo::network::get_net_info
  Future<NetInfo> getNetInfo() async {
    final n = await si.getNetInfo();
    return NetInfo(ipv4: n.localIp, available: n.connected);
  }

  /// 网速实测（见 `measure_net_quality`）：RTT 用 TCP 握手耗时，收发用网卡计数器差值。
  Future<NetSpeedResult> measureNetSpeed({int samples = 5}) async =>
      NetSpeedResult.from(await si.measureNetQuality(samples: samples));

  // crateApiSysinfoProcessRReadProcessInfo → api::sysinfo::process::read_process_info
  Future<List<ProcInfo>> readProcessInfo() async {
    return [
      for (final p in await si.readProcessInfo())
        ProcInfo(
            pid: p.pid,
            name: p.name,
            exe: p.exe,
            cpu: p.cpu,
            mem: p.memMb.round())
    ];
  }

  // crateApiSysinfoProcessRTerminateProcess → api::sysinfo::process::terminate_process
  Future<void> terminateProcess(int pid) => si.terminateProcess(pid: pid);

  // crateApiSysinfoStartupRReadStartupList → api::sysinfo::startup::read_startup_list
  Future<List<StartupItem>> readStartupList() async {
    return [
      for (final s in await si.readStartupList())
        StartupItem(name: s.name, location: s.location, enabled: s.enabled)
    ];
  }

  // crateApiSysinfoStartupRChangeStartupStatus → …::startup::change_startup_status
  Future<void> changeStartupStatus(StartupItem item, bool enable) =>
      si.changeStartupStatus(
          itemName: item.name, enable: enable, location: item.location);

  // crateApiSysinfoStartupRGetSystemBootUpDuration → …::get_system_boot_up_duration
  Future<int> getSystemBootUpDuration() async {
    final v = await si.getSystemBootUpDuration();
    return v.isEmpty ? 0 : int.tryParse(v.first) ?? 0;
  }

  // crateApiSysinfoAppCheckRCheckApp2 → api::sysinfo::app_check::check_app2
  Future<List<AppEntry>> checkApp2() async {
    final out = [
      for (final a in await si.checkApp2())
        AppEntry(
            name: a.name,
            version: a.version,
            publisher: a.publisher,
            uninstallKey: a.uninstallKey,
            displayIcon: a.displayIcon)
    ];
    // 留痕：带 DisplayIcon 的条数直接决定列表有没有图标可画，为 0 说明注册表读取
    // 或字段映射断了，界面只会看到一排占位图。
    await logInfo('应用枚举 ${out.length} 项，带 DisplayIcon '
        '${out.where((e) => e.displayIcon.trim().isNotEmpty).length} 项');
    return out;
  }

  /// 取应用图标像素。没有 DisplayIcon 或文件取不到图标时返回 null，
  /// 界面据此回落成占位图标（图标缺失不该让整行信息不可用）。
  /// 参考实现的图标来自 rusthelp.dll 封装的 shell 接口，这里净室直连 SHGetFileInfoW
  /// （api::sysinfo::extract_app_icon，无对应 frb codec 名）。
  /// 图标像素缓存。进程列表每 3s 重建一次行、多个进程又共用同一个 exe，
  /// 不去重就会反复提取同一张图；取不到（null）同样缓存，免得坏路径一直重试。
  final Map<String, AppIcon?> _appIcons = {};

  Future<AppIcon?> appIcon(String displayIcon) async {
    final key = displayIcon.trim();
    if (key.isEmpty) return null;
    if (_appIcons.containsKey(key)) return _appIcons[key];
    // 缓存上限：换机、装卸软件后 key 会持续变多，宁可重新提取也不无限涨
    if (_appIcons.length > 512) _appIcons.clear();
    try {
      final p = await si.extractAppIcon(displayIcon: displayIcon);
      final icon = AppIcon(width: p.width, height: p.height, rgba: p.rgba);
      _appIcons[key] = icon;
      return icon;
    } catch (e) {
      // 图标缺失只影响观感，但必须留痕：否则现场只看到一排占位图，
      // 无从判断是注册表没写 DisplayIcon 还是桥/原生层挂了。
      await logError('图标提取失败 [$displayIcon]: $e');
      _appIcons[key] = null;
      return null;
    }
  }

  // crateApiSysinfoAppCheckRUninstallApp → api::sysinfo::app_check::uninstall_app
  Future<void> uninstallApp(String uninstallKey) =>
      si.uninstallApp(uninstallKey: uninstallKey);

  // crateApiSysinfoPatchesRGetInstalledPatchIds → …::patches::get_installed_patch_ids
  // Rust 侧仅返回 HotFixID 列表（WMI Win32_QuickFixEngineering）
  Future<List<PatchEntry>> getPatchList() async {
    return [
      for (final id in await si.getInstalledPatchIds())
        PatchEntry(id: id, title: id, kind: 'WUSA')
    ];
  }

  // crateApiSysinfoPatchesRWusaUninstallPatch → api::sysinfo::patches::wusa_uninstall_patch
  // 列表出自 get_installed_patch_ids，界面上能做的动作是卸载；返回 wusa 的输出文本。
  Future<String> uninstallPatch(PatchEntry p) =>
      si.wusaUninstallPatch(kbId: p.id);

  // 净室新增入口（原二进制无对应导出符号）：读 Windows 自己写下的重启挂起点。
  // 返回值是来源标识列表（cbs / wu / rename），空列表即没有挂起。
  Future<List<String>> rebootPendingReasons() => si.rebootPendingReasons();

  // crateApiDiskScanDeepCleanRGetRecycleBinSize → …::deep_clean::get_recycle_bin_size
  // Rust 返回 [总字节数, 人类可读]。界面上要的就是展示那一位：原来只取 [0] 再自己
  // 除 1<<30，10 MB 的回收站被写成「0.01G」。
  Future<String> getRecycleBinSize() async {
    final v = await ds.getRecycleBinSize();
    return v.length > 1 ? v[1] : '0 B';
  }

  Future<void> emptyRecycleBin() => ds.emptyRecycleBin();

  /// 回收站原始两位：`[字节数, 人类可读]`。要判阈值就得拿字节那一位——
  /// 展示串是 `format_size` 出的，0 字节是「0.00 B」而不是「0 B」，比字符串必错。
  Future<List<String>> getRecycleBin() => ds.getRecycleBinSize();

  // crateApiDiskScanDeepCleanRScanDeepClean → …::deep_clean::scan_deep_clean
  // Rust 返回 ScanResult JSON：{entries:[{name,size,hits:[{path,size}]}], remove_self_dirs:[]}
  Stream<List<CleanItem>> scanDeepClean() => _runScan(() async {
        final json = await ds.scanDeepClean();
        _lastDeepCleanJson = json;
        final result = jsonDecode(json) as Map<String, dynamic>;
        final grouped = <CleanItem>[];
        for (final e
            in (result['entries'] as List).cast<Map<String, dynamic>>()) {
          final hits = (e['hits'] as List).cast<Map<String, dynamic>>();
          if (hits.isEmpty) continue;
          // 按规则条目聚合展示（参考实现即按规则名分组，条目大小 = 命中总大小）
          grouped.add(CleanItem(
              path: '${e['name']}（${hits.length} 个文件）',
              size: _mb(_asInt(e['size'])),
              paths: [for (final h in hits) h['path'] as String]));
        }
        return grouped;
      });

  /// 深度清理执行：把扫描结果原样交回 Rust 的 clean_deep_clean
  Future<void> cleanDeepClean() async {
    final json = _lastDeepCleanJson;
    if (json == null) return;
    await ds.cleanDeepClean(resultJson: json);
    _lastDeepCleanJson = null;
  }

  // crateApiDiskScanLargeFileScanRLargeFileScan → …::large_file_scan::large_file_scan
  // Rust 返回 Vec<FileHit> JSON：[{path,size}]
  Stream<List<CleanItem>> largeFileScan() => _runScan(() async {
        final json = await ds.largeFileScan(
            root: _userProfile, minSizeMb: BigInt.from(100));
        return [
          for (final h
              in (jsonDecode(json) as List).cast<Map<String, dynamic>>())
            CleanItem(path: h['path'] as String, size: _mb(_asInt(h['size'])))
        ];
      });

  // crateApiDiskScanDuplicateFileScanRDuplicateFileScan → …::duplicate_file_scan
  // Rust 返回 Vec<DupGroup> JSON：[{group_id, items:[{path,size}]}]
  Stream<List<CleanItem>> duplicateFileScan() => _runScan(() async {
        final json = await ds.duplicateFileScan(root: _userProfile);
        final items = <CleanItem>[];
        for (final g
            in (jsonDecode(json) as List).cast<Map<String, dynamic>>()) {
          final files = (g['items'] as List).cast<Map<String, dynamic>>();
          final size = _asInt(files.first['size']);
          items.add(CleanItem(
              path: '${files.length} 份重复：${files[1]['path']}',
              size: _mb(size),
              // 保留第一份，删除其余
              paths: [for (final f in files.skip(1)) f['path'] as String]));
        }
        return items;
      });

  // crateApiDiskScanSystemDiskScanRSystemDiskScan → …::system_disk_scan
  // Rust 返回 Vec<DirStat> JSON：[{path,size}]
  Stream<List<CleanItem>> systemDiskScan() => _runScan(() async {
        final json = await ds.systemDiskScan();
        return [
          for (final d
              in (jsonDecode(json) as List).cast<Map<String, dynamic>>())
            CleanItem(path: d['path'] as String, size: _mb(_asInt(d['size'])))
        ];
      });

  // crateApiDiskScanDiskToolsRDeleteFile → …::disk_tools::delete_file
  Future<void> deleteFile(List<CleanItem> items) => ds.deleteFile(paths: [
        for (final i in items)
          if (i.paths.isEmpty) i.path else ...i.paths
      ]);

  // crateApiUtilsRGetMachineId → api::utils::get_machine_id
  Future<String> getMachineId() => ru.getMachineId();

  // crateApiSysinfoWindowsInfoRGetVersionInfo → api::sysinfo::windows_info::get_version_info
  Future<String> getVersionInfo() async {
    final v = await si.getVersionInfo();
    return v.join(' ');
  }

  // crateApiSysinfoLogsRCollectLog → api::sysinfo::logs::collect_log
  /// 采集并压缩日志，返回 zip 路径（Rust 侧已把 logs\ 近 7 天文件打包到 %TEMP%）
  Future<String?> collectLogPack() async {
    final zips = await si.collectLog();
    return zips.isEmpty ? null : zips.first;
  }

  // crateApiGuiLogRInfo/Warn/Error → api::gui_log::{info,warn,error}
  Future<void> logInfo(String msg) => gl.info(msg: msg);
  Future<void> logWarn(String msg) => gl.warn(msg: msg);
  Future<void> logError(String msg) => gl.error(msg: msg);

  // crateApiDiskScan*RCancel* → …::cancel_xxx
  Future<void> cancel(String key) async {
    switch (key) {
      case 'deep_clean':
        await ds.cancelDeepCleanScan();
      case 'large_file':
        await ds.cancelLargeFileScan();
      case 'dup_file':
        await ds.cancelDuplicateFileScan();
      case 'system_disk':
        await ds.cancelSystemDiskScan();
    }
  }

  // crateApiSysinfoMemoryRProcessesMemoryOptimization → …::memory::processes_memory_optimization
  // Rust 返回 "trimmed=<数量>"
  Future<int> processesMemoryOptimization() async {
    final out = await si.processesMemoryOptimization();
    return int.tryParse(out.split('=').last) ?? 0;
  }

  // crateApiSysinfoAdapterR* 网络修复族 → api::sysinfo::adapter::*
  Future<bool> netAvailable() => si.netAvailable();
  Future<void> setNetworkFix() => si.setNetworkFix();
  Future<void> openSettingNetworkProxyPage() =>
      si.openSettingNetworkProxyPage();

  // crateApiSysinfoComponentDetectRServiceStatus → …::component_detect::service_status
  // 返回 RUNNING/STOPPED/UNKNOWN（UNKNOWN 即服务未安装或不可查询）
  Future<String> serviceStatus(String serviceName) =>
      si.serviceStatus(serviceName: serviceName);

  // crateApiSysinfoComponentDetectRInstallStartService → …::install_start_service
  // sc create + sc start，需管理员权限
  Future<void> installStartService(String serviceName, String binPath) =>
      si.installStartService(serviceName: serviceName, binPath: binPath);

  /// 统一扫描执行：Rust 侧为阻塞式一次性返回（在线程池执行，不阻塞 UI），
  /// 这里包成页面所需的 Stream；取消/出错抛 ScanException 供页面进入错误态。
  ///
  /// 不要在结果之前先 `yield []`：页面的「空列表」就是「很干净」这个结论，
  /// 扫描还在跑时抢跑一个空列表，整页会从「正在检测…」直接跳到「很干净，
  /// 没有发现可清理项」，用户读到的是一个还没发生的判断（实测重复文件页：
  /// 首帧空态，等结果回来才列出 240 MB / 209 MB … 若干组）。
  Stream<List<CleanItem>> _runScan(
      Future<List<CleanItem>> Function() body) async* {
    try {
      yield await body();
    } catch (e) {
      throw ScanException(bridgeErrorText(e));
    }
  }

  static int _asInt(dynamic v) => v is int ? v : (v as num).toInt();
}
