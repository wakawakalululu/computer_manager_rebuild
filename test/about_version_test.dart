import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 关于页的版本串与机型判断。
///
/// 版本串来自 `getWinDetialVer`（HKLM 的 ProductName/DisplayVersion/Build/UBR）
/// ——提问题单时对方只认完整串，只有产品名是不够的。
void main() {
  test('完整版本串带显示版本与 Build.修订号', () {
    const v = WindowsVersion(
      productName: 'Windows 10 Enterprise LTSC 2021',
      displayVersion: '21H2',
      build: '19044',
      revision: 7058,
      editionId: 'Enterprise',
    );
    expect(v.fullVersion,
        'Windows 10 Enterprise LTSC 2021 21H2 (Build 19044.7058)');
  });

  test('Build 为 0 时不编出 ".0" 这种假修订号', () {
    const v = WindowsVersion(
      productName: 'Windows 11 Pro',
      displayVersion: '23H2',
      build: '22631',
      revision: 0,
      editionId: 'Professional',
    );
    expect(v.fullVersion, contains('(Build 22631)'));
    expect(v.fullVersion, isNot(contains('.0)')));
  });

  test('空字段不留下多余空格', () {
    const v = WindowsVersion(
      productName: 'Windows 10',
      displayVersion: '',
      build: '19045',
      revision: 1,
      editionId: '',
    );
    expect(v.fullVersion, 'Windows 10 (Build 19045.1)');
  });

  group('机型判断（:503 是自研云电脑 / :549 组件】云电脑类型为自研）', () {
    test('本机实测机型 RDO/KVM 认作云电脑', () {
      const id =
          ComputerIdentity(systemType: 'PC', manufacturer: 'RDO', model: 'KVM');
      expect(id.looksLikeCloudMachine, isTrue);
    });

    test('公共虚拟化机型不算自研', () {
      for (final m in ['QEMU', 'VirtualBox', 'VMware', 'innotek GmbH']) {
        expect(
          ComputerIdentity(systemType: 'PC', manufacturer: m, model: '')
              .looksLikeCloudMachine,
          isFalse,
          reason: '$m 不该被当成自研云电脑',
        );
      }
    });

    test('机型读不到时判"不是"——认不出宁可不说，报错了会被网关当另一类处理', () {
      const id = ComputerIdentity(systemType: '', manufacturer: '', model: '');
      expect(id.looksLikeCloudMachine, isFalse);
    });
  });
}
