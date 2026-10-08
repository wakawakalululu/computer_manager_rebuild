import 'package:computer_manager/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐条操作的失败提示必须点名是哪一条。
///
/// 一屏几十个应用/补丁/启动项，只说「卸载失败」用户不知道是哪一行坏了；
/// 而同一处的成功提示本来就带名字（「卸载补丁 KB…」），失败那行更该带。
void main() {
  test('逐条失败带上条目名，且带上真实原因', () {
    final s = perItemFailure('卸载', 'Bilibili 1.19.0', Exception('拒绝访问'));
    expect(s, contains('Bilibili 1.19.0'));
    expect(s, contains('拒绝访问'));
  });

  test('启动项那条连注册表位置一起给出，才对得上刚拨的那一格', () {
    final s = perItemFailure('修改启动项', 'OneDrive（HKCU）', Exception('需要管理员'));
    expect(s, contains('OneDrive'));
    expect(s, contains('HKCU'));
    expect(s, contains('需要管理员'));
  });

  test('补丁号原样带出（KB 号不能被截断或改写）', () {
    final s = perItemFailure('卸载补丁', 'KB5034441', Exception('wusa 退出码 1'));
    expect(s, contains('KB5034441'));
    expect(s, contains('wusa 退出码 1'));
  });

  test('条目名为空时也不塌成孤零零一句"失败"——至少留出动作与原因', () {
    final s = perItemFailure('结束', '', Exception('PID 不存在'));
    expect(s, contains('结束'));
    expect(s, contains('PID 不存在'));
  });
}
