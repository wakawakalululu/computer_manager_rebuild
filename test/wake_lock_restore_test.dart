import 'package:computer_manager/pages/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动时重放「阻止云电脑息屏」。
///
/// 修的是这个缺陷：开关只在 `onChanged` 里调 `WakelockPlus.enable()`，
/// **启动路径上一次都没重放过**。于是用户开过一次之后，重启设置页照样显示"开"
/// （那是读 prefs 画出来的），系统层面却什么都没做——比"从来做不到的惯性控件"
/// 更隐蔽一档：上次真的生效过，这次悄悄没了还显示着开。
///
/// `setLock` 是注入缝：测试环境没有 wakelock 插件，真调会 `MissingPluginException`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('restoreWakeLock', () {
    test('存过 true：启动时重放 enable，并回报 true', () async {
      SharedPreferences.setMockInitialValues({'wakeLock': true});
      final calls = <bool>[];
      final applied =
          await restoreWakeLock(setLock: (v) async => calls.add(v));
      expect(calls, [true], reason: '开过的偏好必须在启动时重新落到系统上');
      expect(applied, isTrue);
    });

    // 这条是安全侧：没开过的人不该因为"我们想统一恢复偏好"就凭空多出一个
    // 系统级副作用（屏幕不再息）。默认值 false 不等于"帮我们 enable(false)"。
    test('从没存过：完全不碰系统，也不返回 true', () async {
      SharedPreferences.setMockInitialValues({});
      var called = 0;
      final applied = await restoreWakeLock(
          setLock: (v) async => called++); // ignore: avoid_function_literals_in_foreach_calls
      expect(called, 0, reason: '没开过就不该去动 WakelockPlus');
      expect(applied, isFalse);
    });

    test('明确存过 false：同样不碰系统', () async {
      SharedPreferences.setMockInitialValues({'wakeLock': false});
      var called = 0;
      await restoreWakeLock(setLock: (v) async => called++);
      expect(called, 0);
    });

    // 失败要吞在函数里面：阻止息屏没成功不该把启动带崩（它是偏好重放，不是关键路径）。
    test('插件调用抛错时返回 false 而不是把异常抛出启动路径', () async {
      SharedPreferences.setMockInitialValues({'wakeLock': true});
      final applied = await restoreWakeLock(
          setLock: (v) async => throw StateError('没有 wakelock 插件'));
      expect(applied, isFalse);
    });
  });
}
