import 'package:computer_manager/services/rust_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// hosts/手动代理探针有三态，**"没读到"和"确实干净"必须分得开**。
///
/// 原来 `networkOverrides()` 把抛异常的那项塞成 false，而设置页与体检都只看这个
/// false —— 于是探针失败时，界面与"两项都没问题"**完全一样**。那不是漏报一行，
/// 是凭空给了一份干净结论，而 hosts/代理恰恰是上不了网最常见的两种人为原因。
void main() {
  test('unknown() 不谎称干净', () {
    const u = NetworkOverrides.unknown();
    expect(u.hostsModified, isFalse);
    expect(u.manualProxy, isFalse);
    // 值确实是 false（拿它去 if 判断不会炸），但**明确标记为没读到**
    expect(u.allChecked, isFalse);
    expect(u.any, isFalse, reason: '没读到就不该"有任何发现"');
  });

  test('读到且都干净：allChecked 为 true，与 unknown 区分得开', () {
    const c = NetworkOverrides(hostsModified: false, manualProxy: false);
    expect(c.allChecked, isTrue);
    expect(c.any, isFalse);
    // 两者 any 都是 false——所以**只判断 any 是不够的**，必须看 allChecked
    expect(c.any, NetworkOverrides.unknown().any);
    expect(c.allChecked, isNot(NetworkOverrides.unknown().allChecked));
  });

  test('读到且有问题：allChecked 仍为 true（读到了，不是猜的）', () {
    const hosts = NetworkOverrides(hostsModified: true, manualProxy: false);
    const proxy = NetworkOverrides(hostsModified: false, manualProxy: true);
    expect(hosts.allChecked, isTrue);
    expect(proxy.allChecked, isTrue);
    expect(hosts.any, isTrue);
    expect(proxy.any, isTrue);
  });
}
