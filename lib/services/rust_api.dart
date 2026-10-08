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

import '../src/rust/api/device_info.dart' as di;
import '../src/rust/api/disk_scan.dart' as ds;
import '../src/rust/api/gui_log.dart' as gl;
import '../src/rust/api/pcas.dart' as pc;
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

/// 容量按一位小数显示。**不要用 `>> 30`**：那是整除，一张 500 MB 的盘会
/// 写成「0G」——比不显示更糟。
String formatCapacity(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}G';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)}M';
  return '$bytes B';
}

/// 一张盘的容量明细，三个标签逐字取自参考实现自带文案：「总容量」`:449`、
/// 「已用容量」`:113`、「剩余容量」`:109`——同句式三连、只出现在容量这一处。
String diskCapacityDetail(DiskInfo d) => '总容量 ${formatCapacity(d.total)} · '
    '已用容量 ${formatCapacity(d.total - d.free)} · '
    '剩余容量 ${formatCapacity(d.free)}';

/// 系统盘详情（比 DiskInfo 多"文件系统 / 可移动"两项）。
class RootDiskInfo {
  const RootDiskInfo({
    required this.letter,
    required this.mountPoint,
    required this.total,
    required this.free,
    required this.fileSystem,
    required this.removable,
  });

  final String letter;
  final String mountPoint;
  final int total;
  final int free;
  final String fileSystem;

  /// 可移动盘（U 盘/移动硬盘）。清理页给这类盘的建议不该和系统盘一样。
  final bool removable;
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

  /// 进程 exe 的发布者（PE CompanyName）；读不到时为空串。
  /// 进程名本身看不出是什么（svchost 之类），发布者才认得出是谁家的。
  final String publisher;

  /// 进程 exe 的文件说明（PE FileDescription）；读不到时为空串。
  /// 回答的是"它自称是什么"——与发布者（谁家的）互补，合成才认得出一个进程。
  final String description;
  final double cpu;
  final int mem;
  ProcInfo(
      {required this.pid,
      required this.name,
      required this.exe,
      required this.cpu,
      required this.mem,
      this.publisher = '',
      this.description = ''});
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

  /// 能直接启动的 `.exe` 全路径；null = 这个应用**推不出**启动目标
  /// （图标指向 .ico、只给文件名、或路径已失效）。界面据此不给「启动」入口，
  /// 而不是给一个点了会弹"选择打开方式"的按钮。
  final String? launchTarget;

  AppEntry(
      {required this.name,
      required this.version,
      required this.publisher,
      required this.uninstallKey,
      required this.displayIcon,
      this.launchTarget});
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

/// 网络现状的实测快照：DHCP 开关 + DNS 服务器。
class NetworkDiagnosis {
  const NetworkDiagnosis({required this.dhcpEnabled, required this.dnsServers});

  /// **null = 没读到**（一张网卡都没查到），不是"DHCP 关着"。
  ///
  /// 两者在界面上差别很大：`false` 会被摆成「DHCP 关」这个凭空结论，
  /// 而真实情况是"根本没查"。这与 [NetworkOverrides.allChecked] 同源。
  final bool? dhcpEnabled;
  final List<String> dnsServers;

  /// DNS 没配、或配的全是空白/0.0.0.0 这类无效值——上不了网最常见的一种。
  /// 空白串也要算无效：注册表里写一个"看着有、其实全空格"的 DNS 不比没有强。
  bool get dnsLooksBroken {
    if (dnsServers.isEmpty) return true;
    return dnsServers.every((s) {
      final t = s.trim();
      return t.isEmpty || t == '0.0.0.0';
    });
  }
}

/// 会让"有网卡却上不去"变成常态的两种人为改动。
///
/// 只描述事实，不下结论——修不修由用户决定（`fixHostsConfigured` 要管理员，
/// `disableProxy` 改的是他的代理设置，都必须先确认）。
class NetworkOverrides {
  /// 探针读不到时用这个——**不要**用它表达"没问题"。
  const NetworkOverrides.unknown()
      : hostsModified = false,
        manualProxy = false,
        allChecked = false;

  /// 两项都真读到（即便都是 false）。
  ///
  /// [allChecked] 默认 true：这个构造器只在"确实都读过"时用；
  /// 读不到时用 [NetworkOverrides.unknown]，别用 false 值混淆过去。
  const NetworkOverrides({
    required this.hostsModified,
    required this.manualProxy,
    this.allChecked = true,
  });

  /// hosts 里有非默认行（本机就有一行把 github.com 指到了 20.27.177.113）
  final bool hostsModified;

  /// 开着手动代理（HKCU ProxyEnable != 0）
  final bool manualProxy;

  /// 本次是否把**两项都**真读到了。
  ///
  /// 原来 `networkOverrides()` 把抛异常的那项也塞成 false，于是"读不到"和"确实
  /// 没问题"在界面上完全一样——探针失败时体检就少报一条最具体的线索
  /// （hosts / 代理），用户以为机器是好的。
  final bool allChecked;

  bool get any => hostsModified || manualProxy;
}

/// 大文件的判定门槛（MB）。取参考实现结果行自己写的那一句
/// 「超出 50MB 文件共」(`:559`)——门槛不在文案里另写一遍，扫描参数与结果行
/// 共用这一个常量，免得界面说 50MB、底下按别的数扫（原来扫的是自造的 100MB）。
const int kLargeFileMinMb = 50;

/// 大文件结果行的前缀，由门槛拼出来，与扫描参数同源。
String get kLargeFileSummaryPrefix => '超出 ${kLargeFileMinMb}MB 文件共';

class CleanItem {
  final String path;
  final int size;

  /// 该条目实际对应的文件路径集合。列表行可能是聚合展示（一条清理规则、
  /// 一组重复文件），此时 path 只用于显示，删除走 paths。
  final List<String> paths;

  /// 归类名（「垃圾清理」「系统无用文件」…），深度清理按它分组显示。
  /// 来自规则里的 `LangSecRef`，其余扫描页为空串。
  final String category;
  bool checked;
  CleanItem(
      {required this.path,
      required this.size,
      List<String>? paths,
      this.category = '',
      this.checked = true})
      : paths = paths ?? const [];
}

/// 地址是否是"能用"的：排除 APIPA、IPv6 链路本地与 0.0.0.0。
///
/// 与 [isRoutableGateway] 是两回事：那条问"是不是上游路由"，这条问
/// "这台网卡到底联没联上网"——没拿到 DHCP 时 Windows 会自己填一个 169.254.x，
/// 照单全收就会把一张没联上网的网卡算成在用。
bool isUsableIp(String ip) {
  final a = ip.trim().toLowerCase();
  if (a.isEmpty || a == '0.0.0.0' || a == '::') return false;
  if (a.startsWith('169.254.')) return false; // APIPA
  if (a.startsWith('fe80:')) return false; // IPv6 链路本地
  return true;
}

/// 网关是否是"真"的上游路由：排除链路本地与 0.0.0.0。
///
/// 抽成公开纯函数是为了能被测试直接钉住——之前这段逻辑藏在 adapterList 的
/// 闭包里，测不到，只能靠实机肉眼比对，那正是它一开始写错的原因。
bool isRoutableGateway(String gw) {
  final g = gw.trim().toLowerCase();
  if (g.isEmpty || g == '0.0.0.0') return false;
  if (g.startsWith('fe80:')) return false; // IPv6 链路本地
  if (g.startsWith('169.254.')) return false; // IPv4 链路本地（APIPA）
  return true;
}

/// winapp2 的 `LangSecRef` → 参考实现自带的归类名。
///
/// 这几个编号是 winapp2 社区规则库的既定分类（`winapp2.rs` 里也照抄了这个
/// 注释：3021=应用程序 / 3401=Windows / 3402=应用 / 3403=浏览器），
/// 归类名取参考实现文案表自带的「垃圾清理」`:248`、「系统无用文件」`:562`、
/// 「网络缓存」`:180`、「应用缓存」`:131`。编号不认识时返回空串——
/// 宁可不给归类，也不编一个名。
String deepCleanCategory(String langSecRef) => switch (langSecRef.trim()) {
      '3021' => '垃圾清理',
      '3401' => '系统无用文件',
      '3402' => '应用缓存',
      '3403' => '网络缓存',
      _ => '',
    };

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

/// 组件体检探针结果。项名照参考实现自带的：「外设检测」`zh_strings.txt:478`、
/// 「打印机配置」`:310`、「启动环境」`:164`。
class ComponentReport {
  const ComponentReport({
    required this.printerCount,
    required this.defaultPrinter,
    required this.offlinePrinters,
    required this.problemDevices,
    required this.problemDeviceCount,
    required this.bootMode,
  });

  final int printerCount;
  final String? defaultPrinter;

  /// 离线（WorkOffline）的打印机名
  final List<String> offlinePrinters;

  /// 带故障码的在位外设名（Rust 侧最多列 8 个，总数看 [problemDeviceCount]）
  final List<String> problemDevices;
  final int problemDeviceCount;

  /// "UEFI" / "Legacy BIOS" / "未知"
  final String bootMode;
}

/// 体检「网卡状态」要用的网卡摘要。只带判定用的三个字段，
/// 免得 frb 的 `AdapterInfo` 漏到服务层去（这一层其它地方都是本地模型）。
class Nic {
  const Nic({
    required this.description,
    required this.hasIp,
    required this.hasGateway,
    this.dnsServers = const [],
    this.netshName = '',
  });

  final String description;

  /// 这张网卡配置的 DNS 服务器（可能为空——虚拟网卡常常没有）
  final List<String> dnsServers;

  /// netsh 认的接口名。**改 DNS / 启停网卡只能用这个，不能用 description**：
  /// 两者不是一回事（本机实测 description 是 `Red Hat VirtIO Ethernet Adapter #3`，
  /// netsh 认的却是 `以太网实例 0 3`），拿 description 去跑 netsh 会静默失败。
  /// 空串 = 读不到，那张网卡不能拿去做 netsh 动作。
  final String netshName;

  /// 这张网卡上有没有配 IP（未连接的网卡在 WMI 里也会有一行）
  final bool hasIp;

  /// 是不是带**真**默认网关的网卡——同时有两张就说明出站路由在看运气。
  ///
  /// 只认非链路本地（link-local）的网关：WMI 里任何带 IPv6 的网卡都有一对
  /// `fe80::…` 的链路本地网关，那不是上游路由。本机实测云客户端的虚拟网卡
  /// 只有 `fe80::fcff:ffff:feff:ffff`，照单全收就会把"一张真网关"报成
  /// 「网卡数量异常」——又是一个假警报。
  final bool hasGateway;
}

/// 屏幕尺寸 / 屏幕矩形（逻辑像素）。
///
/// 服务层一律用纯 Dart 的小模型，不把 Flutter 的 `Size`/`Rect` 拖进来——
/// 这一层其它模型（`Nic`、`CleanItem`…）都是这么写的。
class ScreenSize {
  const ScreenSize(this.width, this.height);
  final double width;
  final double height;
}

class ScreenRect {
  const ScreenRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

/// 机型身份（Win32_ComputerSystem）。
class ComputerIdentity {
  const ComputerIdentity(
      {required this.systemType,
      required this.manufacturer,
      required this.model});
  final String systemType;
  final String manufacturer;
  final String model;

  /// 机型身份**读到了没有**。厂商与型号双双为空才算没读到，只空一边也是残缺。
  bool get identityRead =>
      manufacturer.trim().isNotEmpty || model.trim().isNotEmpty;

  /// 是不是"自研云电脑"(:503 是自研云电脑 / :549 组件】云电脑类型为自研)。
  ///
  /// 判据只能落在 Manufacturer/Model 上：自研云电脑的机型标识是认得的
  /// （本机 RDO / KVM），而公共云 PC/虚拟机给的是 QEMU/VirtualBox/Microsoft
  /// 之类。**这里不做穷举白名单**——认不出的机型宁可说"不是"，也不往"是"上靠：
  /// 这是上报给网关的判断，报错了会被当成另一种云电脑类型处理。
  bool get looksLikeCloudMachine {
    final maker = manufacturer.trim().toLowerCase();
    final model_ = model.trim().toLowerCase();
    // 两边都空才算读不到；只空一边也是残缺，同样认不出
    if (maker.isEmpty && model_.isEmpty) return false;
    final id = '$maker $model_';
    return !const [
      'qemu',
      'virtualbox',
      'vmware',
      'innotek', // VirtualBox 的厂商名，只写 manufacturer 也会命中
      'microsoft corporation',
      'parallels',
      'bochs',
      'xen',
    ].any(id.contains);
  }
}

/// Windows 详细版本。
class WindowsVersion {
  const WindowsVersion({
    required this.productName,
    required this.displayVersion,
    required this.build,
    required this.revision,
    required this.editionId,
  });
  final String productName;
  final String displayVersion;
  final String build;
  final int revision;
  final String editionId;

  /// 「Windows 10 Enterprise LTSC 2021 21H2 (Build 19044.7058)」这种完整串。
  String get fullVersion {
    final b = build;
    final r = revision > 0 ? '.$revision' : '';
    final buildPart = (b + r).isEmpty ? '' : ' (Build $b$r)';
    final ver = displayVersion.isEmpty ? '' : ' $displayVersion';
    return '$productName$ver$buildPart';
  }
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
            publisher: await processPublisher(p.exe),
            description: await processFileDescription(p.exe),
            cpu: p.cpu,
            mem: p.memMb.round())
    ];
  }

  /// 进程 exe 的发布者（PE VERSIONINFO 的 CompanyName）。
  /// `crateApiSysinfoProcessProcessInfoGetProcessPublisher`。
  ///
  /// 逐个进程读 PE 头有成本（几十个进程 = 几十次文件读），所以：同一 exe 路径
  /// 只读一次，读不到就当没有——列表里不写"未知发布者"这种占位话。
  final Map<String, String> _publisherCache = {};

  Future<String> processPublisher(String exe) async {
    if (exe.isEmpty) return '';
    final hit = _publisherCache[exe];
    if (hit != null) return hit;
    var value = '';
    try {
      final r = await si.getProcessPublisher(exePath: exe);
      if (r.isNotEmpty) value = r.first.trim();
    } catch (_) {
      // 读不到（无权限 / 不是 PE）就不是发布者，不影响列表其余内容
    }
    _publisherCache[exe] = value;
    return value;
  }

  /// 进程 exe 的**文件说明**（PE VERSIONINFO 的 FileDescription）。
  /// `crateApiSysinfoProcessProcessInfoGetProcessFileDescription`。
  ///
  /// 和 [processPublisher] 读的是同一份 VERSIONINFO（同一段手写解析器），
  /// 区别只在于**这个字段回答的是"它自称是什么"**：
  /// 进程名 `svchost` / `RuntimeBroker` 认不出是什么，公司名（CompanyName）认得出是谁家的，
  /// 而文件说明给出的是产品自己的全称——「Microsoft® Windows® Operating System」这类。
  /// 三个字段合起来才认得出一个进程是什么，所以这里把它也接出来。
  ///
  /// 同样按 exe 路径缓存：几十个进程常常指向同一个 exe，不缓存就是几十次文件读。
  /// 读不到就不写（留空），**不编一个"未知说明"之类的占位话**。
  final Map<String, String> _descriptionCache = {};

  Future<String> processFileDescription(String exe) async {
    if (exe.isEmpty) return '';
    final hit = _descriptionCache[exe];
    if (hit != null) return hit;
    var value = '';
    try {
      final r = await si.getProcessFileDescription(exePath: exe);
      if (r.isNotEmpty) value = r.first.trim();
    } catch (_) {
      // 无权限 / 不是 PE 文件 → 就没有文件说明，与列表其余内容无关
    }
    _descriptionCache[exe] = value;
    return value;
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

  /// 上一次开机**花了多久**（毫秒）。数据源是 Windows 自己的启动诊断事件
  /// （`Diagnostic-Performance/Operational` 的 EventID 100，字段 `BootTime`）。
  ///
  /// `null` = 这台机器读不到（通道被关、无权限、从没写过这条事件）。
  /// 调用方**必须**按"没有这一行"处理，不能把 null 当 0 显示成"开机耗时 0 秒"——
  /// 那是把"没查到"报成一个结论，本项目反复在扫的那类缺陷。
  /// 也别拿 [getSystemBootUpDuration]（开机后累计运行时长）顶替它：两个量不是一回事。
  Future<int?> getBootTimeMs() async {
    try {
      final ms = await si.getBootTimeMs();
      return ms?.toInt();
    } catch (e) {
      await logWarn('读取开机启动耗时失败（界面不显示该项）: $e');
      return null;
    }
  }

  // crateApiSysinfoStartupRGetSystemBootUpDuration → …::get_system_boot_up_duration
  Future<int> getSystemBootUpDuration() async {    final v = await si.getSystemBootUpDuration();
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
            displayIcon: a.displayIcon,
            launchTarget: a.launchTarget)
    ];
    // 留痕：带 DisplayIcon 的条数直接决定列表有没有图标可画，为 0 说明注册表读取
    // 或字段映射断了，界面只会看到一排占位图。顺带记下能启动的条数——
    // 「启动」入口的数量全靠它，为 0 说明 DisplayIcon 整体不可用。
    await logInfo('应用枚举 ${out.length} 项，带 DisplayIcon '
        '${out.where((e) => e.displayIcon.trim().isNotEmpty).length} 项，'
        '可启动 ${out.where((e) => e.launchTarget != null).length} 项');
    return out;
  }

  // crateApiSysinfoWindowsInfoROpenApp → api::sysinfo::windows_info::open_app
  /// 按路径启动应用（`ShellExecuteW`，不经 cmd 解析，所以目标里的 `&`、`|`
  /// 不会被当命令分隔符）。Rust 侧对返回值有检查：`<=32` 一律抛错，
  /// 不会"以为起来了其实没有"。
  Future<void> openApp(String target) => si.openApp(target: target);

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

  // crateApiDiskScanDeepCleanROpenRecycleBinFolder → …::deep_clean::open_recycle_bin_folder
  /// 在资源管理器里打开回收站。
  ///
  /// 回收站卡上写着容量却**看不到里面有什么**——用户被告知「有 3.2 GB 可清空」，
  /// 却没有一个入口能确认那些是不是他还要的东西。空回收站也照样开：
  /// 点「查看」要看的是"现在到底有什么"，不是"能不能省空间"。
  Future<void> openRecycleBinFolder() => ds.openRecycleBinFolder();

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
              category: deepCleanCategory('${e['lang_sec_ref'] ?? ''}'),
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
            root: _userProfile, minSizeMb: BigInt.from(kLargeFileMinMb));
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

  // crateApiDiskScanDiskToolsRDeleteSingleFile → …::disk_tools::delete_single_file
  /// 删**一个**文件。批量删走 [deleteFile]（它会合并错误、一次报全），
  /// 这里供只读的扫描页逐条删：单条失败不该让其它条目一起点不着。
  Future<void> deleteSingleFile(String path) => ds.deleteSingleFile(path: path);

  // crateApiUtilsRCreateTmepEmptyFileWhitSize → …::utils::create_tmep_empty_file_whit_size
  /// 按指定字节数建一个空文件（保留原工程拼写 tmep/whit 以对齐 codec）。
  ///
  /// 这是「智慧盘」那条路的机制：生成一块占空间的文件给系统腾物理内存用
  /// （参考实现说明 `:456`「在运行内存不足时提升运行速度，清理后会在
  /// 剩余空间最大的盘符再次生成」）。
  ///
  /// ⚠ 这会在磁盘上**真的写满 size 字节**（`set_len` 落稀疏文件）。调用方必须
  /// 确认过剩余空间——直接给一个来路不明的 size 会把盘写满。
  Future<void> createTempEmptyFile(String path, int sizeBytes) =>
      ru.createTmepEmptyFileWhitSize(path: path, size: BigInt.from(sizeBytes));

  // crateApiSysinfoComputerTypeRIsPathExits → …::computer_type::is_path_exits
  /// 路径是否存在（保留原拼写 exits）。
  ///
  /// 智慧盘页进页面要先查一次占位文件在不在：上次生成的文件留在盘上，
  /// 不查就会把"有"报成"未生成"，而「清理」按钮也就点不出来了。
  Future<bool> pathExists(String path) => si.isPathExits(path: path);

  // crateApiDiskScanDiskToolsROpenFileDir → …::disk_tools::open_file_dir
  /// 在资源管理器里打开这个文件所在目录并选中它。
  ///
  /// 清理结果页列的本来就是路径，用户看得见却点不开——这是"扫出来的一大堆文件"
  /// 唯一能验证的入口。Rust 侧用 explorer `/select,` 并以 raw_arg 传参，
  /// 免得含空格的路径被 std 自动加引号后又被 explorer 二次改写。
  Future<void> openFileDir(String path) => ds.openFileDir(path: path);

  // crateApiDiskScanDiskToolsRCheckFilesExists → …::disk_tools::check_files_exists
  /// 这些路径此刻还在不在（逐个判定，结果与入参同序）。
  ///
  /// 用途：扫描结果会**过期**——扫完到点删除之间，文件可能被别的程序移走/删掉。
  /// 那时按扫描时的条数报"释放了 1.8 GB"就是拿旧账说新话；先探一遍活的，才知道
  /// 真正删掉多少、少了多少。参照实现也留了「文件不存在」(:58) 这句。
  Future<List<bool>> checkFilesExist(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final r = await ds.checkFilesExists(paths: paths);
    // frb 回等长向量；真对不上就全当"存在"，宁可少报也不谎报
    if (r.length != paths.length) return List.filled(paths.length, true);
    return r;
  }

  // crateApiUtilsRGetMachineId → api::utils::get_machine_id
  Future<String> getMachineId() => ru.getMachineId();

  // crateApiSysinfoWindowsInfoRGetVersionInfo → api::sysinfo::windows_info::get_version_info
  Future<String> getVersionInfo() async {
    final v = await si.getVersionInfo();
    return v.join(' ');
  }

  // crateApiSysinfoProcessRLogProcessPortUsage → api::sysinfo::process::log_process_port_usage
  /// 采一份端口表（`netstat -ano`）写进日志，返回逐行文本；失败返回空表且只打一条 WARN。
  ///
  /// 为什么要在打包前采：参考实现调用同一个 codec，Rust 侧把每一行 `log::info!` 出去，
  /// 于是问题反馈的日志包里自带「当时谁占着哪个端口」。我们此前只有自己的日志，
  /// 这条诊断一个字都没有——现象是同一份反馈，对面拿到的信息比我们少一截。
  /// 失败不抛：端口表是可选诊断，不能因为 netstat 起不来就把整次反馈提交带崩
  /// （同「日志附件收集失败不该让提交失败」那条判据）。
  Future<List<String>> snapshotPortUsage() async {
    try {
      return await si.logProcessPortUsage();
    } catch (e) {
      await logWarn('端口表采集失败（不影响日志打包）: $e');
      return const [];
    }
  }

  // crateApiSysinfoLogsRCollectLog → api::sysinfo::logs::collect_log
  /// 采集并压缩日志，返回 zip 路径（Rust 侧已把 logs\ 近 7 天文件打包到 %TEMP%）
  Future<String?> collectLogPack() async {
    // 先采端口表再压：写日志是同步落盘（gui_log 每行 flush），所以这一轮的
    // `[port-usage]` 行一定进得到包里。
    await snapshotPortUsage();
    final zips = await si.collectLog();
    return zips.isEmpty ? null : zips.first;
  }

  /// 把 Rust 侧那些 `log::info!/warn!/error!` 接上落盘。
  ///
  /// 原来 Rust 里有 10 处 `log::` 调用，但**从来没有 `log::set_logger`**——
  /// 没有 logger 时 log crate 会把每条记录直接丢掉。于是问题反馈打包
  /// 「近 7 天日志」时，那些 Rust 侧诊断一个字都拿不到，而现象是"目录可能都没建"。
  /// 这个函数装上那座桥（复用 gui_log 的写入器，不引第三方 logger）。
  /// 装不上也不抛：第二次调用会返回 false（全局 logger 已被占用），那是正常的。
  Future<void> initLogBridge() => gl.initLogBridge();

  // crateApiUtilsRRustBackendInit → api::utils::rust_backend_init
  /// 启动时确保 exe 目录下的 `logs\` 存在。
  ///
  /// 为什么必要：`gui_log` 第一次写日志时才 `create_dir_all`，若那个目录建不出来
  ///（权限不足 / 目录被删），**每一条日志都会静默失败**——诊断信息一个字都不留，
  /// 而现象只是"没有 logs 目录"。启动时先建一次，把这个失败挪到**看得见的时候**。
  /// 失败不抛：日志是辅助，起不来不该拦住程序启动。
  Future<void> initBackendDirs() async {
    try {
      await ru.rustBackendInit();
    } catch (e) {
      // logError 本身已保证不抛（见它的注释）
      await logError('创建日志目录失败（后续日志可能写不进去）: $e');
    }
  }

  // crateApiGuiLogRInfo/Warn/Error → api::gui_log::{info,warn,error}
  //
  // 这三个**永不抛**：桥未初始化时 `RustLib.api` 是同步抛 StateError，而调用点有 20 多处
  // `unawaited(...logXxx(...))`（错误处理里、timer 回调里、子进程入口里）。逐处套 try/catch
  // 既漏得掉又难读，所以在**这一层**兜住——记日志失败绝不该把调用方正在做的事带崩
  // （典型场景：进程页每 3s 刷新时一次 logError 同步抛，把"这一轮读失败"升级成
  // "整个定时回调炸掉"）。
  Future<void> logInfo(String msg) => _neverThrows(() => gl.info(msg: msg));
  Future<void> logWarn(String msg) => _neverThrows(() => gl.warn(msg: msg));
  Future<void> logError(String msg) => _neverThrows(() => gl.error(msg: msg));

  static Future<void> _neverThrows(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {
      // 连日志都写不了：静默到此为止，这是日志路径的终点
    }
  }

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

  /// ipconfig /flushdns + netsh winsock reset。
  ///
  /// **它不重置 DNS 也不重置 DHCP**——flushdns 只是丢缓存，winsock reset 重置的是
  /// 套接字目录。DNS 服务器被手改成不可用的地址时，这两步跑完照样上不了网，
  /// 所以界面不能拿它冒充「DNS/DHCP 重置」（原来就是这么标的，见 setAdapterDhcp）。
  Future<void> setNetworkFix() => si.setNetworkFix();

  // crateApiSysinfoAdapterRSetAdapterDhcp → …::adapter::set_adapter_dhcp
  /// 把指定网卡恢复成 DHCP 自动获取 DNS（netsh，需管理员权限）。
  ///
  /// 这是真正在修 DNS 的那一步——网卡被改成静态 DNS（手改的、失效的、
  /// 云环境里运营商早就换了的）时，只有回到自动获取才可能拿回可用解析。
  ///
  /// [adapterName] 必须是 [Nic.netshName]，不是 description。
  Future<void> setAdapterDhcp(String adapterName) async {
    _requireNetshName(adapterName);
    await si.setAdapterDhcp(adapterName: adapterName);
  }

  // ⚠ `set_adapter_dns`（写静态 DNS）**故意不给出口**：文案表里没有任何
  // "自定义 DNS / DNS 服务器"一类的界面文案（`zh_strings.txt` 搜 DNS 为零命中），
  // 参考实现有没有这个设置界面无从确认。要给它做入口就得自己编标题、输入框、
  // 校验与提示每一句话——那是**凭空造一个控件**，不是对齐。所以这里只留
  // `setAdapterDhcp`（恢复 DHCP 自动获取 DNS），那条有文案依据也真有用户场景。
  // Rust 侧实现仍在，需要时按 `crateApiSysinfoAdapterRSetAdapterDns` 接即可。

  // crateApiSysinfoAdapterREnableAdapter → …::adapter::enable_adapter
  /// 启用一张被禁用的网卡（netsh admin=enable，需管理员权限）。
  ///
  /// 网卡被禁用时 WMI 里仍有一行、但没有 IP——体检那条「未检测到在用网卡」
  /// 指的就是这种。只报不给出路等于让用户自己去设备管理器翻。
  ///
  /// [adapterName] 同上，必须是 [Nic.netshName]。
  Future<void> enableAdapter(String adapterName) async {
    _requireNetshName(adapterName);
    await si.enableAdapter(adapterName: adapterName);
  }

  /// 空名字 / 空白名字在这里就挡住，不发那条 netsh 命令。
  ///
  /// netsh 拿到不认识的接口名会回「找不到指定的路径」，**退出码还是 0**——
  /// 于是上层看不出任何异常，只会以为"改完了"。这正是静默失败，所以在边界上拦。
  static void _requireNetshName(String name) {
    if (name.trim().isEmpty) {
      throw ArgumentError('缺少 netsh 接口名（不能用网卡描述代替）');
    }
  }

  // crateApiSysinfoAdapterRNotepadOpenHost → …::adapter::notepad_open_host
  /// 用记事本打开 hosts 文件，返回打开的路径。
  ///
  /// hosts 被改写时，用户要看的不是"恢复默认"（那会丢了他自己加的映射），
  /// 而是先看见是谁写了什么。改之前必须先能打开看。
  Future<String> notepadOpenHost() => si.notepadOpenHost();

  Future<void> openSettingNetworkProxyPage() =>
      si.openSettingNetworkProxyPage();

  // crateApiSysinfoComponentProbe → api::sysinfo::component_probe
  // 组件体检探针：打印机（「打印机配置」:310）、带故障码的在位外设
  // （「外设检测」:478）、启动环境（「启动环境」:164）。
  Future<ComponentReport> componentProbe() async {
    final p = await si.componentProbe();
    return ComponentReport(
      printerCount: p.printers.length,
      defaultPrinter: p.defaultPrinter,
      offlinePrinters: p.offlinePrinters,
      problemDevices: p.problemDevices,
      problemDeviceCount: p.problemDeviceCount,
      bootMode: p.bootMode,
    );
  }

  // crateApiSysinfoAdapterRGetAdapterinfoList → …::adapter::get_adapterinfo_list
  /// 网卡列表摘要，体检的「网卡状态」(`:529`) 按它判「网卡数量异常」(`:66`)。
  Future<List<Nic>> adapterList() async {
    final rows = await si.getAdapterinfoList();
    return [
      for (final r in rows)
        Nic(
          description: r.description,
          // 只认"能用的地址"：APIPA(169.254/16) 是没拿到 DHCP 时自己编的，
          // IPv6 链路本地 fe80::/10 也只在本网段内。本机那张虚拟网卡就只有
          // 169.254.241.240 却被算成"在用网卡"，同样是假警报。
          hasIp: r.ipAddresses.any(isUsableIp),
          // 链路本地（fe80::/10、169.254/16）不是上游路由，算进"多网卡在用"只会误报
          hasGateway: r.gateways.any(isRoutableGateway),
          dnsServers: r.dnsServers,
          netshName: r.netshName,
        ),
    ];
  }

  // crateApiSysinfoDiskRGetRootDiskInfo → …::sysinfo::disk::get_root_disk_info
  /// 系统盘（SystemDrive，通常 C:）的容量/文件系统/是否可移动。
  ///
  /// `getDiskInfoList` 只给盘符与容量，读不到**文件系统**和**可移动标记**——
  /// 这两个是解释"为什么这个盘不能动/怎么清理"的必要事实。读不到返回 null。
  Future<RootDiskInfo?> getRootDiskInfo() async {
    final d = await si.getRootDiskInfo();
    if (d == null) return null;
    return RootDiskInfo(
      letter: d.name,
      mountPoint: d.mountPoint,
      total: d.totalBytes.toInt(),
      free: d.freeBytes.toInt(),
      fileSystem: d.fileSystem,
      removable: d.removable,
    );
  }

  // crateApiSysinfoComponentDetectRServiceStatus → …::component_detect::service_status
  // 返回 RUNNING/STOPPED/UNKNOWN（UNKNOWN 即服务未安装或不可查询）
  Future<String> serviceStatus(String serviceName) =>
      si.serviceStatus(serviceName: serviceName);

  // crateApiSysinfoComponentDetectRInstallStartService → …::install_start_service
  // sc create + sc start，需管理员权限
  Future<void> installStartService(String serviceName, String binPath) =>
      si.installStartService(serviceName: serviceName, binPath: binPath);

  // crateApiSysinfoComponentDetectRKillRestartService → …::component_detect::kill_restart_service
  /// 先 stop 再 start 一个服务（sc.exe），需管理员权限。
  ///
  /// 「杀掉进程并启动服务」(`:311`) 是参考实现自带的说法。用来处理**已安装但停了**
  /// 的守护服务：那种情况下 `serviceStatus` 会如实报 STOPPED，可界面上只有
  /// 「安装并启动守护服务」——对一个已经装好的服务再点一次 sc create 是错的。
  Future<void> restartService(String serviceName) =>
      si.killRestartService(serviceName: serviceName);

  /// 拉起 PCAS 认证客户端（`crateApiPcasClientApiToolROpenPcasClient` → …::pcas::client_api_tool）。
  ///
  /// 原来 Rust 侧实现了、适配层却没有出口，整条能力界面上够不着——而 wiring
  /// 检查只看"适配层方法有没有被引用"，看不见"适配层压根没这个方法"，所以
  /// 一直报 0。先把出口补上（是否给 UI 入口另说），接线面才盖得住。
  ///
  /// 返回值如实区分"拉起了客户端"与"什么都没起"（客户端不存在时**不再**开兜底网页）。
  /// 界面上应先问 [pcasClientInstalled]，未安装就不必调这里。
  Future<pc.PcasLaunchOutcome> openPcasClient() => pc.openPcasClient();

  /// 认证客户端是否装在默认位置。
  ///
  /// `null` = 探测本身失败，**不等于"未安装"**——把"读不到"说成"没装"
  /// 是本项目反复在扫的那类缺陷（同一个函数在 Rust 侧是 `is_file()`，
  /// 它不会区分"路径不存在"和"没权限查"）。
  Future<bool?> pcasClientInstalled() async {
    try {
      return await pc.pcasClientInstalled();
    } catch (e) {
      await logWarn('探测认证客户端是否安装失败（按"无法确认"处理）: $e');
      return null;
    }
  }

  // ---- 网络排障：hosts / 代理（Rust 侧已实现，此前没有出口也没有界面）----

  // crateApiSysinfoAdapterRHostConfiged → …::adapter::host_configed
  /// hosts 里是否被塞过非默认行（本机实测就有一行 `20.27.177.113 github.com`）。
  /// 这类改写是"明明有网却上不去"最难查的一种原因，值得单独报出来而不是
  /// 一句"上不了网"了事。只读，不改文件。
  Future<bool> hostsConfigured() => si.hostConfiged();

  // crateApiSysinfoAdapterRFixHostConfiged → …::adapter::fix_host_configed
  /// 恢复 hosts 为默认内容（保留空行/注释/localhost），先备份再改，随后
  /// `ipconfig /flushdns`。**需要管理员权限**，属改系统文件——调用前必须确认。
  /// 返回是否真的执行了修复（本来就没被改过就返回 false，不白动手）。
  Future<bool> fixHostsConfigured() => si.fixHostConfiged();

  // crateApiSysinfoAdapterRGetDhcpAndDnsStatus → …::adapter::get_dhcp_and_dns_status
  /// DHCP / DNS 现状，用来解释"为什么上不了网"：重置只是治标，先把现状摆出来。
  ///
  /// 不用 `getDhcpAndDnsStatus` 的返回值：它只取**第一张**有 IP 的适配器。
  /// 实测本机 WMI 里第一张是 VirtIO（云客户端的虚拟网卡，没有 DNS），
  /// 真正在用的那张（#3）DNS 是正常的——照它报就会喊"DNS 没配"，
  /// 那是**假警报**，比不报更坏。这里按"所有在用网卡合起来看"：任一张有有效 DNS
  /// 就算正常，全都没有才判异常。
  Future<NetworkDiagnosis> diagnoseNetwork() async {
    final rows = await si.getDhcpAndDnsStatus();
    final nics = await adapterList();
    final allDns = [
      for (final n in nics)
        if (n.hasIp) ...n.dnsServers,
    ];
    final servers =
        allDns.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    // Rust 侧一张网卡都没有时回**空列表**（原来回 "false"，等于宣称"DHCP 关着"，
    // 而真实情况是"根本没查到网卡"）。所以 rows 为空 = **没读到**，
    // 这时 dhcpEnabled 必须是 null 而不是 false —— 后者会被界面摆成
    // 「DHCP 关」这种凭空结论。三态：true 开 / false 关 / null 没查到。
    final dhcp = rows.isEmpty ? null : rows.first.trim() == 'true';
    // 兜底：适配器列表里一条 IP 都没有时，用 Rust 那份读数，别空手而归
    return NetworkDiagnosis(
      dhcpEnabled: dhcp,
      dnsServers: servers.isNotEmpty
          ? servers
          : rows
              .skip(1)
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
    );
  }

  // crateApiSysinfoAdapterRHasManualProxy → …::adapter::has_manual_proxy
  /// 是否开了手动代理（HKCU\…\Internet Settings\ProxyEnable != 0）。
  Future<bool> hasManualProxy() => si.hasManualProxy();

  // crateApiSysinfoAdapterRDisableProxy → …::adapter::disable_proxy
  /// 关掉手动代理。同样要用户确认——这是改他的系统设置。
  Future<void> disableProxy() => si.disableProxy();

  /// 两个"有网卡却上不去"的事实合成一个探针。
  ///
  /// **读失败不等于干净**：原来两项各自 `catch (_) {}` 之后一律塞 false，
  /// 于是"没读到"和"确实没问题"在界面上完全一样——探针失败时体检就少报一条
  /// 最具体的线索，用户以为机器是好的。任一项读不到就返回 `NetworkOverrides.unknown()`。
  Future<NetworkOverrides> networkOverrides() async {
    bool? hosts;
    bool? proxy;
    try {
      hosts = await hostsConfigured();
    } catch (e) {
      await logError('查询 hosts 状态失败: $e');
    }
    try {
      proxy = await hasManualProxy();
    } catch (e) {
      await logError('查询手动代理失败: $e');
    }
    if (hosts == null || proxy == null) return const NetworkOverrides.unknown();
    return NetworkOverrides(hostsModified: hosts, manualProxy: proxy);
  }

  // ---- 机型与 Windows 版本（关于页 / 体检报机型用）----

  // crateApiSysinfoComputerTypeRGetComputerType → …::computer_type::get_computer_type
  /// 机型：[PCSystemType, Manufacturer, Model]。
  ///
  /// 参考实现靠它判断「云电脑类型为自研」(:549)——自研云电脑的
  /// Manufacturer/Model 是认得的（本机实测 RDO / KVM），公共云则不是。
  /// 判断规则在 [ComputerIdentity.looksLikeCloudMachine]，先看
  /// [ComputerIdentity.identityRead]：读不到时那句"不是"是"查不到"，不是结论。
  Future<ComputerIdentity> computerIdentity() async {
    final rows = await si.getComputerType();
    if (rows.isEmpty) {
      return const ComputerIdentity(
          systemType: '', manufacturer: '', model: '');
    }
    return ComputerIdentity(
      systemType: rows[0].trim(),
      manufacturer: rows.length > 1 ? rows[1].trim() : '',
      model: rows.length > 2 ? rows[2].trim() : '',
    );
  }

  // crateApiSysinfoComputerTypeRGetWinDetialVer → …::computer_type::get_win_detial_ver
  /// Windows 详细版本：[ProductName, DisplayVersion, CurrentBuild, UBR, EditionID]。
  Future<WindowsVersion> windowsVersion() async {
    final r = await si.getWinDetialVer();
    String at(int i) => r.length > i ? r[i].trim() : '';
    return WindowsVersion(
        productName: at(0),
        displayVersion: at(1),
        build: at(2),
        revision: int.tryParse(at(3)) ?? 0,
        editionId: at(4));
  }

  // ---- 显示器 / 屏幕工作区（窗口尺寸按实测屏幕算，不写死）----

  /// 主屏分辨率（逻辑像素）。`crateApiDeviceInfoStructsMonitorInfoGetMonitorSize`
  /// → …::structs_monitor_info::get_monitor_size。
  Future<ScreenSize> primaryScreenSize() async {
    final m = await di.getMonitorSize();
    return ScreenSize(m.width.toDouble(), m.height.toDouble());
  }

  /// 主显示器的工作区（**已扣掉**任务栏等停靠区）。
  /// `crateApiDeviceInfoStructsMonitorInfoGetMonitorWorkSize`。
  ///
  /// ⚠ 这里**不是**「多显示器合起来的那一片」：`SPI_GETWORKAREA` 给的是主显示器的
  /// 工作区，坐标以主屏左上角为原点。各显示器自己的工作区要枚举
  /// `EnumDisplayMonitors` 才是，那条路没做，别按多屏的语义用它。
  Future<ScreenRect> primaryWorkArea() async {
    final m = await di.getMonitorWorkSize();
    return ScreenRect(m.x.toDouble(), m.y.toDouble(), m.width.toDouble(),
        m.height.toDouble());
  }

  // ---- 存储感知（HKCU\…\StoragePolicy 的 "01"，0=关 1=开）----
  // crateApiSysinfoUpgradeImageRGetImageVersion → …::upgrade_image::get_image_version
  /// 本机镜像升级包的版本（读 C:\ProgramData\ImageUpgradeersion.txt）。
  /// 空串 = 没装镜像包 / 读不到。
  ///
  /// 顺带一提：这个路径原先写成 raw string 又手写 `\`，永远不存在，于是这里
  /// 恒返回空——升级镜像这条路是死的。已修（见 sysinfo.rs 的回归测试）。
  Future<String> getImageVersion() async {
    final v = await si.getImageVersion();
    return v.isEmpty ? '' : v.first.trim();
  }

  // crateApiSysinfoComponentDetectRJudgeVersion → …::component_detect::judge_version
  /// 比两个版本号：a 高于 b 返回 1，等于 0，低于 -1。
  ///
  /// Rust 侧回的是字符串码，这里收成 int 并把不认识的值归 0（"没有结论"
  /// 不能当"相等"之外的任何一种）。版本号按 `.` `-` `_` 分段，逐段比；
  /// 非数字段退化成字符串比（"1.0.0-beta" vs "1.0.0-alpha"）。
  Future<int> judgeVersion(String a, String b) async {
    final r = await si.judgeVersion(versionA: a, versionB: b);
    if (r.isEmpty) return 0;
    return int.tryParse(r.first.trim()) ?? 0;
  }

  // crateApiSysinfoStorageSenseRGetStrogeSense → …::storage_sense::get_stroge_sense
  /// 读存储感知开关：**null = 没读到**（键不存在 / 取值失败）。
  ///
  /// 原实现把"读不到"一律收成 `false`——那是在说"存储感知关着"，
  /// 而真实情况是"查不到"。设置页那盏开关靠 `null` 决定**不可拨**
  /// （先显示"关"等于替用户报了个没读过的状态），所以这里必须把两态分开。
  Future<bool?> storageSenseEnabled() async {
    final v = await si.getStrogeSense();
    if (v.isEmpty) return null;
    final raw = v.first.trim();
    if (raw.isEmpty) return null;
    return raw == '1';
  }

  // crateApiSysinfoStorageSenseRSetStrogeSense → …::storage_sense::set_stroge_sense
  /// 写存储感知开关（写 HKCU，不需要管理员）。
  Future<void> setStorageSense(bool enabled) =>
      si.setStrogeSense(enabled: enabled);

  // crateApiSysinfoStorageSenseRShowStrogeSense → …::storage_sense::show_stroge_sense
  /// 打开系统自带的「存储感知」设置页（ms-settings:storagesense），
  /// 用户想看官方那一份说明时用得上。
  Future<void> openStorageSenseSettings() => si.showStrogeSense();

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
