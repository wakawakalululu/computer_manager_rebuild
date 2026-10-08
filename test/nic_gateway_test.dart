import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 网卡相关两个判据，钉的是同一类错误：**WMI 字段非空 ≠ 那个东西有意义**。
///
/// 两个都是本机实测踩出来的：云客户端那张虚拟网卡只有 `fe80::…` 链路本地网关
/// 和一个 `169.254.241.240` 的 APIPA 地址，照单全收就会把一台网络正常的机器
/// 报成「网卡数量异常」。这两个函数原先藏在 adapterList 的闭包里测不到，只能
/// 靠实机肉眼比对——那正是它们一开始写错的原因，所以抽成公开纯函数。
void main() {
  group('网关：链路本地不算真上游路由', () {
    test('链路本地 / APIPA 网关 / 0.0.0.0 / 空白 都不算', () {
      expect(isRoutableGateway('fe80::fcff:ffff:feff:ffff'), isFalse);
      expect(isRoutableGateway('FE80::1'), isFalse, reason: '大小写不敏感');
      expect(isRoutableGateway('169.254.1.1'), isFalse, reason: 'APIPA 也是链路本地');
      expect(isRoutableGateway('0.0.0.0'), isFalse);
      expect(isRoutableGateway('  '), isFalse);
    });

    test('真实网关照算', () {
      expect(isRoutableGateway('172.16.0.1'), isTrue);
      expect(isRoutableGateway('192.168.1.1'), isTrue);
      expect(isRoutableGateway('221.5.88.88'), isTrue);
    });
  });

  group('地址：没联上网的网卡不算在用', () {
    test('APIPA / 链路本地 / 0.0.0.0 / :: / 空白 都不算可用地址', () {
      // 没拿到 DHCP 时 Windows 自己填 169.254.x；只 IPv6 的机器必有 fe80::
      expect(isUsableIp('169.254.241.240'), isFalse);
      expect(isUsableIp('FE80::edc1:c641:c4ea:dc5f'), isFalse);
      expect(isUsableIp('0.0.0.0'), isFalse);
      expect(isUsableIp('::'), isFalse);
      expect(isUsableIp('  '), isFalse);
    });

    test('真实地址照算', () {
      expect(isUsableIp('172.16.3.121'), isTrue);
      expect(isUsableIp('2409:8c2f::1'), isTrue, reason: '全球单播 IPv6 是能用的');
    });

    test('本机那两张网卡：虚拟网卡既没有真网关、也没拿到真地址', () {
      // 实测：VirtIO #1 只有 169.254.241.240 + fe80:: + fe80:: 网关
      const virtualNic = Nic(
        description: 'Red Hat VirtIO Ethernet Adapter',
        hasIp: false,
        hasGateway: false,
      );
      const realNic = Nic(
        description: 'Red Hat VirtIO Ethernet Adapter #3',
        hasIp: true,
        hasGateway: true,
        dnsServers: ['100.127.129.129', '211.136.17.107'],
      );
      // 两类计数都只认那一张真网卡——不该触发"网卡数量异常"
      final usable = [virtualNic, realNic].where((n) => n.hasIp).length;
      final gated = [virtualNic, realNic].where((n) => n.hasGateway).length;
      expect(usable, 1);
      expect(gated, 1);
    });
  });
}
