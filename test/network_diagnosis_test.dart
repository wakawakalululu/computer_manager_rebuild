import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 网络现状的判定：DNS 空或全是 0.0.0.0 就算"没配"——重置是治标，
/// 用户得先看见问题在哪。
void main() {
  test('DNS 没配 / 全是无效值 → 判为异常', () {
    expect(
        const NetworkDiagnosis(dhcpEnabled: true, dnsServers: [])
            .dnsLooksBroken,
        isTrue);
    expect(
        const NetworkDiagnosis(dhcpEnabled: true, dnsServers: ['0.0.0.0'])
            .dnsLooksBroken,
        isTrue);
    expect(
        const NetworkDiagnosis(dhcpEnabled: true, dnsServers: ['', '  '])
            .dnsLooksBroken,
        isTrue);
  });

  test('有真实 DNS 就算正常，不管 DHCP 开没开', () {
    const d = NetworkDiagnosis(
        dhcpEnabled: false, dnsServers: ['221.5.88.88', '8.8.8.8']);
    expect(d.dnsLooksBroken, isFalse);
    // DHCP 关着本身也是一条要被看见的现状，别在模型层被吞掉
    expect(d.dhcpEnabled, isFalse);
  });

  test('DHCP 有第三态：null 是"没读到网卡"，不是"关着"', () {
    // Rust 侧 get_dhcp_and_dns_status 一张网卡都没有时原来回 vec!["false"]，
    // 等于宣称"DHCP 关着"；而真实情况是"根本没查到网卡"。
    // 改回空列表后 Dart 侧必须保持 null，不能顺手 `&&` 成 false。
    const d = NetworkDiagnosis(dhcpEnabled: null, dnsServers: []);
    expect(d.dhcpEnabled, isNull);
    expect(d.dhcpEnabled, isNot(false), reason: 'false 会被界面摆成「DHCP 关」这种凭空结论');
  });
}
