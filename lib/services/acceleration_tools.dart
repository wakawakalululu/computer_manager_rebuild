/// 加速球展开出来的「加速工具」条目规则。
///
/// 逆向依据：`classes.txt` 里的 `_AccelerationToolsCardItemState` 与
/// `_AppAccelerationBallBlankEnteryState`（空态），`zh_strings.txt` 里的
/// 「加速工具」(`:474`)、「一键加速」(`:136`)、「隐藏不可操作项」(`:429`)。
///
/// 「隐藏不可操作项」在这里就是字面实现：**列出来的每一项都必须真的能点、
/// 且点得动**。凑不出可执行项时返回空列表，由界面显示空态，而不是摆一排
/// 灰着或点了没反应的条目。
library;

/// 一个可执行条目：要么直接做（[accelerate]），要么把主窗口带到对应页面（[route]）。
class AccelTool {
  const AccelTool({required this.id, required this.label, this.route});

  final String id;
  final String label;

  /// 需要跳转时给的目标路由；为空表示这一条是就地执行
  final String? route;
}

/// 就地执行的那一条（释放内存）。
const String accelToolAccelerateId = 'accelerate';

/// 达到这个占用才把「查看进程」当成可操作项——低于它时这条没有意义，
/// 按「隐藏不可操作项」的规则不列。
const double accelMemoryToolRatio = 0.8;

/// 磁盘同理：只有真的快满了，「深度清理」才是可操作项。
const double accelDiskToolRatio = 0.9;

/// 按当前实测状态算出可执行条目。顺序固定：就地加速在最前。
List<AccelTool> accelerationTools({
  required double memoryRatio,
  required double maxDiskRatio,
  bool canAccelerate = true,
}) =>
    [
      if (canAccelerate)
        const AccelTool(id: accelToolAccelerateId, label: '一键加速'),
      if (memoryRatio >= accelMemoryToolRatio)
        const AccelTool(
            id: 'processes',
            label: '查看进程',
            route: '/app_manage_dashboard/process_info'),
      if (maxDiskRatio >= accelDiskToolRatio)
        const AccelTool(
            id: 'deep_clean',
            label: '深度清理',
            route: '/disk_clean_dashboard/deep_clean_scan'),
    ];

/// 空态文案。原程序给空态留了专门的类（`_AppAccelerationBallBlankEnteryState`），
/// 但没留下对应的那句话，所以这里只陈述事实，不替它编一句营销话。
const String accelToolsEmptyMessage = '暂无可执行的加速项';
