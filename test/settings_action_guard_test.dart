import 'package:computer_manager/pages/settings_page.dart';
import 'package:computer_manager/services/agent_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页里两个会改系统状态的动作，点下去必须先确认。
///
/// 一个注册开机系统服务（sc create），一个重置 DNS/DHCP 让当前连接短暂中断——
/// 都是本机改动里最重的两步，原来点一下就执行，和删文件/结束进程的处理不一致
/// （那两处都过 confirmDestructive）。这里钉住"先问再动"。
/// 常驻状态注入：测试环境没有 RustLib，问真守卫会直接抛。
Future<ResidentStatus?> _noResident() async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1020, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(
                body: AppSettingPage(residentStatus: _noResident))),
      ]),
    ));
    await tester.pump();
  }

  Future<void> openTile(WidgetTester tester, String label) async {
    // 设置页很长，目标行可能还没被构建出来：先滚到底触发懒建，再滚到可见
    await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('存储感知：没读到值时开关不可拨，不先报一个"关"', (tester) async {
    await pumpSettings(tester);
    expect(find.text('存储感知'), findsOneWidget);
    // 测试环境没有 RustLib → 读取抛错 → _storageSense 保持 null → onChanged 为 null
    final tile = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('存储感知'), matching: find.byType(SwitchListTile)));
    expect(tile.onChanged, isNull, reason: '没读到真实状态却能拨，等于先替用户报了个"关"');
  });

  testWidgets('网络修复：确认框还开着时不进「正在修复」进行态', (tester) async {
    // 「正在修复」(`zh_strings.txt:57`) 是自带说法，与清理页「正在删除」`:235` 同一档。
    // 这里钉的是**顺序**：进行态只能在用户确认之后出现——弹窗还开着就报"正在修复"
    // 等于骗人说已经在动了。
    // ⚠ 确认之后那条路（转圈 + 挡住重复点 + finally 复位）要真跑 RustApi 的
    // 逐步修复，测试环境没有 RustLib，**这一段测不到**，别当成端到端覆盖。
    await pumpSettings(tester);
    // 测试环境没有 RustLib，hosts/代理读不到 ⇒ 标题带「部分状态未确认」（既有那条判据）。
    await openTile(tester, '网络修复（DNS/DHCP，部分状态未确认）');
    expect(find.textContaining('执行期间当前网络连接会短暂中断'), findsOneWidget,
        reason: '没弹出确认框，后面的进行态断言就没有意义');
    expect(find.text('正在修复'), findsNothing, reason: '确认框还在，修复根本还没开始');

    // 对话框在独立路由里，按类型找按钮（与既有那条同一写法）
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('正在修复'), findsNothing, reason: '取消之后不该留下任何"在跑"的样子');
  });

  testWidgets('安装守护服务：先弹确认，取消就不往下走', (tester) async {
    await pumpSettings(tester);
    await openTile(tester, '安装并启动守护服务');

    expect(find.text('安装并启动守护服务'), findsWidgets);
    // 弹窗正文要点明这是 sc create（登记系统服务）并要管理员权限
    expect(find.textContaining('注册一个系统服务'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 确认框关掉就结束，没有任何"正在安装"的转圈留��界面上
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('网络修复：先弹确认，并说明当前连接会中断', (tester) async {
    await pumpSettings(tester);
    // 标题带「部分状态未确认」：测试环境没有 RustLib，hosts/代理探针读不到，
    // 于是**不能**摆出"就剩 DNS/DHCP"那副干净样子（这正是上轮修的那条）。
    await openTile(tester, '网络修复（DNS/DHCP，部分状态未确认）');

    expect(find.textContaining('当前网络连接会短暂中断'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 对话框在独立路由里，ensureVisible 对它无效；直接点掉
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    // 取消了就不能报"已执行"
    expect(find.textContaining('网络修复已执行'), findsNothing);
  });

  group('守护服务：装了却停着 vs 压根没装', () {
    Future<void> pumpWithState(WidgetTester tester, String serviceState) async {
      tester.view.physicalSize = const Size(1020, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp.router(
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, __) => Scaffold(
                  body: AppSettingPage(
                      residentStatus: () async => ResidentStatus(
                            serviceState: serviceState,
                            agentAlive: false,
                            guardedBy: '无人守护',
                          )))),
        ]),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('状态 UNKNOWN（没装/查不到）→ 给「安装并启动」', (tester) async {
      await pumpWithState(tester, 'UNKNOWN');
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('安装并启动守护服务'), findsOneWidget);
      expect(find.text('重启守护服务'), findsNothing);
    });

    testWidgets('Windows 明确回了 1060（NOT_INSTALLED）→ 也给「安装并启动」', (tester) async {
      // 关键回归：`_serviceInstalled` 原判据是 `s != 'UNKNOWN'`（"只要不是 UNKNOWN
      // 就算装了"）。加了 NOT_INSTALLED 之后，那个判据会把**真的没装**当成装了，
      // 于是劝用户去"重启"一个不存在的服务——重启只会失败。
      await pumpWithState(tester, 'NOT_INSTALLED');
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('安装并启动守护服务'), findsOneWidget);
      expect(find.text('重启守护服务'), findsNothing);
    });

    testWidgets('已装但 STOPPED → 给「重启守护服务」，不再劝人 sc create', (tester) async {
      await pumpWithState(tester, 'STOPPED');
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pumpAndSettle();

      // 对一个已经装好的服务再跑一遍 sc create 是错的，用户点之前也不该不知道自己装过
      expect(find.text('安装并启动守护服务'), findsNothing);
      expect(find.text('重启守护服务'), findsOneWidget);
    });

    testWidgets('重启也要先确认（停的是系统服务）', (tester) async {
      await pumpWithState(tester, 'STOPPED');
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重启守护服务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重启守护服务'));
      await tester.pumpAndSettle();

      expect(find.textContaining('采集守护会短暂中断'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      // 取消了就不该留下"正在重启"的转圈
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  // 「开机自动启动」与「有更新时自动升级…」这两个开关**做不到它们字面承诺的事**：
  // 写 HKLM Run 的是安装器（本项目没有），升级需要更新源与升级通道（也没有），
  // 而且没有任何本地偏好会上报给后端。它们只把值存进 SharedPreferences 再回显成
  // 开关自己——拨与不拨，系统行为一模一样。
  //
  // ⚠ 上一轮我把「自动更新」换成参考实现的原话 `:501` 之后，这件事**更严重**了：
  // 措辞对齐让它听起来更像真承诺。所以判据不是"别撒谎"就够了，而是
  // **"改措辞时要顺手复查这一行承诺的能力在不在"**。
  // 这里钉住：做不到就必须把限制写在同一行上（副标题），不能只藏在源码注释里。
  group('做不到的开关必须当场说明', () {
    Future<void> pumpGeneral(WidgetTester tester) async {
      await pumpSettings(tester);
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
    }

    testWidgets('开机自动启动：说清偏好不等于已改注册表', (tester) async {
      await pumpGeneral(tester);
      expect(find.text('开机自动启动'), findsOneWidget);
      expect(find.textContaining('仅记住偏好'), findsWidgets,
          reason: '没有安装器写 Run 项，开关只存 prefs——不当场说就是假动作');
      expect(find.textContaining('本程序不代其改动'), findsOneWidget);
    });

    testWidgets('自动升级开关：说清当前不会下载或安装任何东西', (tester) async {
      await pumpGeneral(tester);
      expect(find.text('有更新时自动升级PC Manager客户端'), findsOneWidget);
      expect(find.textContaining('升级服务尚未接入'), findsOneWidget,
          reason: '没有更新源与升级通道，标题却承诺"自动升级"——必须并排说明');
      expect(find.textContaining('不会自动下载或安装'), findsOneWidget);
    });

    testWidgets('两个开关仍可拨（偏好是真存的），不是灰掉的假控件', (tester) async {
      await pumpGeneral(tester);
      // ⚠ 只查这两行，**不能扫全页**：存储感知那格在"读不到值"时故意不可拨
      // （这是本项目自己定的三态规则，测试环境里就是 null），扫全页会把它算进来假红。
      for (final t in [
        '开机自动启动',
        '有更新时自动升级PC Manager客户端',
      ]) {
        final sw = tester.widget<Switch>(find.descendant(
            of: find.ancestor(
                of: find.text(t), matching: find.byType(SwitchListTile)),
            matching: find.byType(Switch)));
        expect(sw.onChanged, isNotNull, reason: '$t 的限制写在副标题里，不该整个禁掉');
      }
    });
  });
}
