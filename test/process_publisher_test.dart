import 'package:computer_manager/pages/app_manage_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进程页副标题：读得到发布者就带上，读不到就不占那一格。
///
/// 进程名本身认不出是什么（svchost / RuntimeBroker 一堆同名的），
/// PE 的 CompanyName 才认得出是谁家的——参考实现对应
/// `crateApiSysinfoProcessProcessInfoGetProcessPublisher`，一直没人用。
/// 同源的还有 FileDescription（`…GetProcessFileDescription`）：回答"它自称是什么"，
/// 与"谁家的"互补，两个合起来才认得出一个进程。
void main() {
  test('有发布者：放在 CPU/内存前面', () {
    final p = ProcInfo(
        pid: 1,
        name: 'svchost',
        exe: r'C:\Windows\System32\svchost.exe',
        publisher: 'Microsoft Corporation',
        cpu: 0.5,
        mem: 40);
    expect(processSubtitle(p), 'Microsoft Corporation   CPU 0.5%   内存 40 MB');
  });

  test('读不到发布者：不写"未知发布者"这种占位话', () {
    final p = ProcInfo(pid: 2, name: 'foo', exe: '', cpu: 1.5, mem: 8);
    expect(processSubtitle(p), 'CPU 1.5%   内存 8 MB');
    expect(processSubtitle(p), isNot(contains('未知')));
    expect(processSubtitle(p), isNot(contains('undefined')));
  });

  test('有文件说明时它认得出这个进程是什么', () {
    final p = ProcInfo(
        pid: 3,
        name: 'svchost',
        exe: r'C:\Windows\System32\svchost.exe',
        publisher: 'Microsoft Corporation',
        description: 'Microsoft® Windows® Operating System',
        cpu: 0.5,
        mem: 40);
    final s = processSubtitle(p);
    expect(s, contains('Microsoft Corporation'));
    expect(s, contains('Windows'));
    expect(s, contains('CPU 0.5%'));
  });

  test('发布者与文件说明是同一句时不写两遍', () {
    // 很多程序 CompanyName 与 FileDescription 填的是同一句话
    final p = ProcInfo(
        pid: 4,
        name: 'x',
        exe: '',
        publisher: 'Acme Tool',
        description: 'Acme Tool',
        cpu: 1,
        mem: 2);
    expect(processSubtitle(p), 'Acme Tool   CPU 1.0%   内存 2 MB');
  });

  test('只有文件说明、没有发布者也照样写出来', () {
    final p = ProcInfo(
        pid: 5,
        name: 'y',
        exe: '',
        description: 'Some Service',
        cpu: 0,
        mem: 1);
    expect(processSubtitle(p), contains('Some Service'));
  });
}
