import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// netsh 认的接口名 ≠ WMI 的 Description。
///
/// 本机实测：Description 是 `Red Hat VirtIO Ethernet Adapter #3`，netsh 认的却是
/// `以太网实例 0 3`。拿 description 去跑 `netsh interface ip set dns name=…` 会回
/// 「找不到指定的路径」，而**退出码是 0**——上层看不出任何异常，只会以为改完了。
/// 这是典型的静默失败，所以空名字必须在边界上就被挡住。
void main() {
  test('空 netsh 名字被拒绝，不发那条命令', () async {
    for (final name in ['', '   ', '\t']) {
      await expectLater(
        RustApi.instance.setAdapterDhcp(name),
        throwsA(isA<ArgumentError>()),
        reason: '「$name」不该被当成合法接口名放过去',
      );
    }
  });

  test('启用网卡同样被空名字挡住', () async {
    await expectLater(
      RustApi.instance.enableAdapter(''),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('netsh 名字与描述是两个字段，模型上分开', () {
    const nic = Nic(
      description: 'Red Hat VirtIO Ethernet Adapter #3',
      netshName: '以太网实例 0 3',
      hasIp: true,
      hasGateway: true,
    );
    expect(nic.netshName, isNot(nic.description));
    expect(nic.netshName, isNotEmpty);
  });
}
