import 'package:computer_manager/pages/disk_clean_page.dart';
import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统盘那行把**实测**的文件系统带上；读不到就退回原句，不编。
void main() {
  RootDiskInfo root({String fs = 'NTFS', bool removable = false}) =>
      RootDiskInfo(
        letter: 'C',
        mountPoint: 'C:\\',
        total: 100,
        free: 10,
        fileSystem: fs,
        removable: removable,
      );

  test('读到文件系统就写出来', () {
    expect(systemDiskSubtitle(root()), contains('NTFS'));
    expect(systemDiskSubtitle(root()), contains(kSystemDiskDesc));
  });

  test('读不到（null）时退回原来那句，不出现"当前系统盘"', () {
    final s = systemDiskSubtitle(null);
    expect(s, kSystemDiskDesc);
    expect(s, isNot(contains('当前系统盘')));
  });

  test('文件系统读出来是空串时同样不编', () {
    final s = systemDiskSubtitle(root(fs: '  '));
    expect(s, kSystemDiskDesc);
  });

  test('可移动介质要标出来——和系统盘的清理建议不该一样', () {
    expect(systemDiskSubtitle(root(removable: true)), contains('可移动'));
  });
}
