import 'dart:convert';
import 'dart:io';

import 'package:computer_manager/main.dart';
import 'package:computer_manager/src/rust/api/device_info.dart' as di;
import 'package:computer_manager/src/rust/api/disk_scan.dart' as ds;
import 'package:computer_manager/src/rust/api/sysinfo.dart' as si;
import 'package:computer_manager/src/rust/api/utils.dart' as ru;
import 'package:computer_manager/services/rust_api.dart';
import 'package:computer_manager/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
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

  // 窗口尺寸这条改动：原先只读主屏分辨率（SM_CXSCREEN，那是**整块**屏幕），
  // 任务栏贴底时窗口底边正好压在任务栏上。改成先读虚拟桌面工作区
  // （SM_CXVIRTUALSCREEN 系列，已扣掉停靠区）。判据是拿 PowerShell 独立读回的
  // 屏幕分辨率做交叉比对——不是断言某个具体数值。
  test('虚拟桌面工作区与操作系统报告一致，且不超出主屏', () async {
    final work = await di.getMonitorWorkSize();
    final primary = await di.getMonitorSize();

    expect(work.width, greaterThan(0), reason: '工作区宽为 0 会让窗口按 0 做硬上限');
    expect(work.height, greaterThan(0));
    // 工作区是主屏扣掉任务栏等停靠区，单屏机必然 ≤ 主屏；多屏机则 ≥。
    expect(work.width, lessThanOrEqualTo(primary.width));
    expect(work.height, lessThanOrEqualTo(primary.height));

    // 独立数据源：PowerShell 的 Screen.WorkingArea 就是任务栏扣完之后那片。
    // 只比"工作区 ≤ 主屏"是**恒真**的——虚拟桌面尺寸也满足那条，缺陷照样能过。
    final os = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      // `$` 要写成 \u0024：Dart 会把 $s 当插值吃掉，而 PowerShell 的
      // 子表达式必须保留原样。用正则把两个数字抽出来，不依赖具体分隔符。
      'Add-Type -AssemblyName System.Windows.Forms;'
          '\u0024s=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea;'
          'Write-Output \u0024(\u0024s.Width -as [int]);'
          'Write-Output \u0024(\u0024s.Height -as [int])',
    ]);
    if (os.exitCode == 0) {
      final nums = RegExp(r'\d+')
          .allMatches('${os.stdout}')
          .map((m) => int.parse(m.group(0)!))
          .toList();
      if (nums.length >= 2) {
        expect(work.width, nums[0],
            reason: '实现读到 ${work.width}，OS 报的主屏工作区宽是 ${nums[0]}');
        expect(work.height, nums[1],
            reason: '实现读到 ${work.height}，OS 报的主屏工作区高是 ${nums[1]}'
                '（两者相等说明读的是整块屏幕而不是工作区）');
      }
    }
  });

  // 取尺寸的优先级在工作区读到的**真值**上也成立：主屏与工作区都在时，
  // pickScreenSize 必须选工作区（即窗口不会压在任务栏上）。
  test('pickScreenSize 用实测工作区，不用实测主屏', () async {
    final work = await di.getMonitorWorkSize();
    final primary = await di.getMonitorSize();
    final picked = pickScreenSize(
      workArea: Size(work.width.toDouble(), work.height.toDouble()),
      primary: Size(primary.width.toDouble(), primary.height.toDouble()),
    );
    expect(picked, Size(work.width.toDouble(), work.height.toDouble()));
  });

  // ---------------------------------------------------------------------
  // 智慧盘那三个动作的**真桥路径**。
  //
  // 为什么单独立一条：`smart_disk_page_test` 整组都走 `SmartDiskActions` 桩，
  // 桩只证明"页面按注入的返回值行事"，**一个字都不证明** `createTempEmptyFile`
  // /`pathExists`/`deleteSingleFile` 这三条真路能跑通（BigInt 转换、codec 参数名、
  // Rust 侧 `set_len` 行为都在桩之外）。注入缝只盖住成功路径时，真路径是测不到的。
  //
  // ⚠ 只在本测试**自己建的临时目录**里写，写完立刻删——不去碰用户盘符根目录，
  //   也不写 2G（页面默认值由桩测钉住，这里验的是机制不是体积）。
  test('智慧盘三动作走真桥：建文件→存在→删除→不存在', () async {
    final dir = Directory.systemTemp.createTempSync('cm_smart_disk_bridge_');
    // 用 path 拼接而不是手写反斜杠：分隔符交给平台
    final path = '${dir.path}\\placeholder.tmp';
    try {
      expect(await RustApi.instance.pathExists(path), isFalse,
          reason: '还没建，pathExists 就该报不存在');

      await RustApi.instance.createTempEmptyFile(path, 4096);
      final f = File(path);
      expect(await RustApi.instance.pathExists(path), isTrue);
      expect(f.existsSync(), isTrue);
      // 真值比对：set_len 要的是**逻辑长度**到位。这一步同时钉住
      // `BigInt.from(int)` 那层转换没把参数弄成 0（0 会静默建出空文件，
      // 而界面上"已生成 2.0G"照样像成功）。
      expect(f.lengthSync(), 4096, reason: '文件大小与请求值不符，BigInt 转换或 set_len 断了');

      await RustApi.instance.deleteSingleFile(path);
      expect(f.existsSync(), isFalse);
      expect(await RustApi.instance.pathExists(path), isFalse,
          reason: '删完还报存在，页面就会把"已清理"报成"已生成"');
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  // 失败方向也要真跑一次：路径非法时 Rust 侧要**报错**，不能"没抛异常"就当成功。
  test('createTempEmptyFile 在目录不存在时抛错，而不是静默建出空文件', () async {
    final missing =
        '${Directory.systemTemp.path}\\cm_no_such_dir_${DateTime.now().microsecondsSinceEpoch}\\x.tmp';
    await expectLater(
        RustApi.instance.createTempEmptyFile(missing, 1024), throwsA(anything));
  });

  // 页面选盘用的是 `getDiskInfoList`（剔除可移动盘）——真桥必须给出可用的盘，
  // 否则桩测里"挑剩余最大"永远走不到，而界面上只会一句「未找到可用磁盘」。
  test('getDiskInfoList 真桥返回至少一张有剩余空间的盘', () async {
    final disks = await RustApi.instance.getDiskInfoList();
    expect(disks, isNotEmpty, reason: '真桥读不到任何固定磁盘');
    expect(disks.any((d) => d.free > 0), isTrue,
        reason: '所有盘的 free 都是 0，选盘会恒判"未找到可用磁盘"');
    // 独立复核：PowerShell 报的盘数不该比这少（我们剔可移动，可能少几台）
    final ps = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-CimInstance Win32_LogicalDisk).Count'
    ]);
    final n = int.tryParse('${ps.stdout}'.trim());
    if (n != null && ps.exitCode == 0) {
      expect(disks.length, lessThanOrEqualTo(n),
          reason: '我们报了 ${disks.length} 张，系统只有 $n 张——过滤条件断了');
    }
  });
}

class _BridgeError implements Exception {
  _BridgeError(this.text);
  final String text;
  @override
  String toString() => text;
}
