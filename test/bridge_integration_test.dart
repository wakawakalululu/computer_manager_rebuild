import 'dart:convert';
import 'dart:io';

import 'package:computer_manager/src/rust/api/disk_scan.dart' as ds;
import 'package:computer_manager/src/rust/api/sysinfo.dart' as si;
import 'package:computer_manager/src/rust/api/utils.dart' as ru;
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// frb 桥的端到端验证 —— 真加载 rust/target/release/rust_lib.dll，
/// 并用 PowerShell（WMI/CIM）独立取同一台机器的数值做交叉比对。
///
/// 意义：证明 Flutter 拿到的不是占位/随机值，而是与操作系统一致的实测值。
/// 依赖本机已构建 release rust 库（`cd rust && cargo build --lib --release`）。
Future<num?> _cim(String className, String property) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "(Get-CimInstance -ClassName $className).$property",
  ]);
  if (result.exitCode != 0) return null;
  return num.tryParse('${result.stdout}'.trim());
}

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('内存总量与操作系统报告一致（±10%）', () async {
    final mem = await si.readMemory2();
    expect(mem.total, greaterThan(BigInt.zero));
    expect(mem.used <= mem.total, isTrue, reason: '已用不应超过总量');

    // Win32_OperatingSystem.TotalVisibleMemorySize 单位为 KB
    final osKb = await _cim('Win32_OperatingSystem', 'TotalVisibleMemorySize');
    if (osKb == null) return; // 无 PowerShell 环境时跳过交叉比对
    final osBytes = osKb.toInt() * 1024;
    final diff = (mem.total.toInt() - osBytes).abs();
    expect(diff / osBytes, lessThan(0.1),
        reason: 'Rust 侧总内存 ${mem.total} 与系统报告 $osBytes 偏差过大');
  });

  test('CPU 逻辑核数与操作系统一致', () async {
    final cpu = await si.readCupInfo(); // [名称, 核数, 使用率]
    expect(cpu.length, 3);
    expect(int.parse(cpu[1]), greaterThan(0));
    expect(double.parse(cpu[2]), inInclusiveRange(0, 100));

    final osCores =
        await _cim('Win32_ComputerSystem', 'NumberOfLogicalProcessors');
    if (osCores == null) return;
    expect(int.parse(cpu[1]), osCores.toInt());
  });

  test('磁盘列表含系统盘且数值自洽', () async {
    final disks = await si.getDiskInfoList();
    expect(disks, isNotEmpty);
    final c = disks.firstWhere((d) => d.name.startsWith('C'));
    expect(c.totalBytes > c.freeBytes, isTrue);
    expect(c.totalBytes > BigInt.zero, isTrue);
  });

  test('machine_id 取自注册表 MachineGuid 格式', () async {
    final id = await ru.getMachineId();
    expect(RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-').hasMatch(id), isTrue,
        reason: '应为 GUID：$id');
  });

  test('已安装应用枚举来自注册表（非硬编码三条）', () async {
    final apps = await si.checkApp2();
    expect(apps.length, greaterThan(3), reason: '本机注册表项应多于骨架阶段的 3 条假数据');
    expect(apps.any((a) => a.uninstallKey.isNotEmpty), isTrue);
  });

  /// DisplayIcon 必须是注册表原值（未展开 %VAR%、带 ,index、可能带引号）：
  /// 用 reg.exe 独立读同一个卸载键交叉比对，证明 Rust 侧没有加工过字符串。
  test('DisplayIcon 与注册表实际值一致', () async {
    final apps = (await si.checkApp2())
        .where((a) => a.displayIcon.trim().isNotEmpty)
        .toList();
    expect(apps, isNotEmpty, reason: '本机应存在带 DisplayIcon 的卸载项');
    final probe = apps.first;

    // reg.exe 在中文控制台输出 GBK，必须用 systemEncoding 解码，否则中文路径比对会假失败
    final out = await Process.run(
        'reg', ['query', probe.uninstallKey, '/v', 'DisplayIcon'],
        stdoutEncoding: systemEncoding);
    final line = '${out.stdout}'.split('\n').firstWhere(
        (l) => l.trimLeft().toLowerCase().startsWith('displayicon'),
        orElse: () => '');
    expect(out.exitCode, 0, reason: 'reg.exe 应能读到该卸载键');
    expect(line, isNotEmpty, reason: '该键应带 DisplayIcon 值行');
    // 行格式：`    DisplayIcon    REG_SZ    <原值>`，值本身可含空格
    final parts = line.trim().split(RegExp(r'\s{2,}'));
    expect(parts.length, greaterThanOrEqualTo(3));
    expect(probe.displayIcon, parts.sublist(2).join('    ').trim(),
        reason: '应与注册表原值逐字一致');
  });

  /// 图标提取端到端：shell 取到的像素必须自洽（长度=宽高*4）且不是全透明。
  test('应用图标像素提取（SHGetFileInfo → RGBA）', () async {
    final root = Platform.environment['SystemRoot']!;
    final cmd = [root, r'System32\cmd.exe'].join('\\');
    final pixels = await si.extractAppIcon(displayIcon: cmd);
    expect(pixels.width, greaterThanOrEqualTo(16));
    expect(pixels.rgba.length, pixels.width * pixels.height * 4);
    var opaque = 0;
    for (var i = 3; i < pixels.rgba.length; i += 4) {
      if (pixels.rgba[i] > 0) opaque++;
    }
    expect(opaque, greaterThan(0), reason: '全透明说明 alpha 通道处理有误');
  });

  /// 进程行的图标只能按 exe 路径提取，所以这条 codec 必须把路径带过桥。
  test('进程列表带 exe 路径', () async {
    final procs = await si.readProcessInfo();
    expect(procs, isNotEmpty);
    final existing = procs.where((p) => File(p.exe).existsSync()).toList();
    expect(existing.length * 2 >= procs.length, isTrue,
        reason: '过半进程没有可存在的 exe（${existing.length}/${procs.length}），'
            '字段映射或桥接断了');
  });

  test('深度清理规则引擎产出真实 JSON 结构', () async {
    final json = jsonDecode(await ds.scanDeepClean()) as Map<String, dynamic>;
    expect(json.containsKey('entries'), isTrue);
    expect(json.containsKey('remove_self_dirs'), isTrue);
    for (final e in (json['entries'] as List).cast<Map<String, dynamic>>()) {
      expect(e['hits'], isA<List>());
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 桥层错误的对外文案：frb 把 Rust 的 anyhow 错误包成 AnyhowException(<原文>)，
  // 页面直接插值就会把包装一起显示出来（深度清理页实测过）。
  test('桥层错误取回真实原因，不把 AnyhowException 包装丢给用户', () {
    expect(
        bridgeErrorText(
            _BridgeError('AnyhowException(未找到规则文件 DeepCleanCacheConfig.ini)')),
        '未找到规则文件 DeepCleanCacheConfig.ini');
    expect(bridgeErrorText(_BridgeError('Exception: 打开进程失败')), '打开进程失败');
    expect(bridgeErrorText(_BridgeError('网络超时')), '网络超时');
    // 只有外层是包装、且括号里确实有内容时才剥；空括号保持原样，别给出空文案。
    expect(bridgeErrorText(_BridgeError('AnyhowException()')),
        'AnyhowException()');
  });
}

class _BridgeError implements Exception {
  _BridgeError(this.text);
  final String text;
  @override
  String toString() => text;
}
