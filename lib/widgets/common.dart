import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:lottie/lottie.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme.dart';
import '../services/rust_api.dart';

/// 自定义标题栏（参考实现使用 window_manager 无边框窗口）
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, this.title = 'PC Manager'});
  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const SizedBox(width: 14),
          Image.asset('assets/images/computer_manager_logo.webp',
              width: 20,
              height: 20,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.computer, size: 18)),
          const SizedBox(width: 8),
          DragToMoveArea(
            child: Text(title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const Spacer(),
          _WinBtn(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _WinBtn(
            icon: Icons.close,
            danger: true,
            onTap: () async {
              // 参考实现行为：关闭 → 隐藏到托盘常驻
              await windowManager.hide();
            },
          ),
        ],
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  const _WinBtn({required this.icon, this.onTap, this.danger = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 40,
        alignment: Alignment.center,
        child: Icon(icon,
            size: 16,
            color: danger ? const Color(0xFFE64545) : AppTheme.textSub),
      ),
    );
  }
}

/// 二级页通用头部（参考实现 bg_secondary_page_header.webp 风格）
class PageHeader extends StatelessWidget {
  const PageHeader(
      {super.key, required this.title, this.subtitle, this.onBack});
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.headerGradient),
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 46, 16, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (onBack != null)
            InkWell(
              onTap: onBack,
              child: const Padding(
                padding: EdgeInsets.only(right: 10),
                child:
                    Icon(Icons.arrow_back_ios, size: 16, color: Colors.white),
              ),
            ),
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
        ]),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ]),
    );
  }
}

/// 首页功能入口卡片
class EntryCard extends StatelessWidget {
  const EntryCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      this.onTap});
  final String icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
                color: Color(0x141B2D5B), blurRadius: 10, offset: Offset(0, 4))
          ],
        ),
        child: Row(children: [
          Image.asset('assets/images/$icon',
              width: 40,
              height: 40,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.widgets_outlined, size: 34)),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style:
                      const TextStyle(color: AppTheme.textSub, fontSize: 11)),
            ]),
          ),
          // 没有 onTap 的卡片（未开放功能）不能画出「>」——那是「可进入」的暗示，
          // 点了没反应比没有箭头更糟。
          if (onTap != null)
            const Icon(Icons.chevron_right, color: AppTheme.textSub),
        ]),
      ),
    );
  }
}

/// 主标签已经自带附加信息时不再拼第二遍：注册表 DisplayName 常常含版本号
///（「Ditto 3.24.246.0」+ DisplayVersion「3.24.246.0」），WUSA 补丁列表里
/// id 与 title 同源（「KB5066130  KB5066130」）。extra 为空时也不留尾随空格。
/// 列表行用默认的双空格拉开名称与版本号；写进整句文案里要传 sep: ' '，
/// 不然「确定卸载 Ditto  3.24」那一段看着像手抖打重了。
String dedupTitle(String primary, String extra, {String sep = '  '}) {
  final e = extra.trim();
  if (e.isEmpty || primary.contains(e)) return primary;
  return '$primary$sep$e';
}

/// 重启挂起提示。措辞取参考实现自带的「存在需要重启云电脑才生效的补丁」
///（`specs/zh_strings.txt:260`），但那句只在组件服务或 Windows Update
/// 真的在等重启时才成立；安装器留下的待替换文件不是补丁，就说它自己的话。
String? rebootNotice(List<String> reasons) {
  if (reasons.isEmpty) return null;
  if (reasons.contains('cbs') || reasons.contains('wu')) {
    return '存在需要重启云电脑才生效的补丁';
  }
  return '有文件操作需要重启后才能完成';
}

/// 运行时长（毫秒）→ 中文短时长。启动项页直接把这个数除以 1000 显示成
/// 「上次开机用时 54331.5 秒」：既没人读得懂 5 万秒，也带着一位无意义的小数。
String formatDuration(int millis) {
  if (millis < 0) millis = 0;
  final totalMinutes = millis ~/ 60000;
  if (totalMinutes < 1) return '不足 1 分钟';
  final m = totalMinutes % 60;
  final h = (totalMinutes ~/ 60) % 24;
  final d = totalMinutes ~/ 1440;
  if (d > 0) return h == 0 ? '$d 天' : '$d 天 $h 小时';
  if (h > 0) return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
  return '$m 分钟';
}

/// 字节/秒 → 人类可读速率。数值小于 100 时保留一位小数，大数不留无意义的小数位。
String formatRate(double bytesPerSec) {
  if (bytesPerSec < 1) return '0 B/s';
  const units = ['KB/s', 'MB/s', 'GB/s'];
  var v = bytesPerSec / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 不可逆动作的二次确认。结束进程 / 立即清理 / 清空回收站 / 卸载补丁原本都是
/// 一次点击直达 Rust 侧执行，而 delete_file 走的是 fs::remove_file（不进回收站），
/// 误点一下就是不可恢复的删除。参考实现的文案表里这些确认句都在
///（「确定结束进程？」「所选项删除后不可恢复，请慎重清理」「确定要清空回收站吗？」），
/// 这里按同一套措辞补齐。
Future<bool> confirmDestructive(BuildContext context,
    {required String title, required String body}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.cardBg,
      title: Text(title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: Text(body, style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
      ],
    ),
  );
  return ok ?? false;
}

/// 阈值告急弹窗的正文卡片（内存/CPU/系统盘/应用兼容共用一套版式）。
///
/// 单独拆成 widget 是为了能在 1020x700 的固定画面上直接量：不约束宽度时
/// `Dialog` 会铺满整个主窗（1020 逻辑宽），正文与右对齐按钮之间出现一大片空白，
/// 三个按钮被挤到窗口右缘。宽度定在 420，按钮行留在卡片内。
/// 标题左侧不放 `assets/images/floating_window_popup.webp`：那张图按 VP8X 头是
/// 49x60 的白色气泡底饰，缩到 36px 只剩一块白板，不是图标。
class ThresholdPopupCard extends StatelessWidget {
  const ThresholdPopupCard({
    super.key,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    required this.onCancel,
    required this.onNever,
  });
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onCancel;
  final VoidCallback onNever;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      // M3 默认给 Dialog 的是 surfaceContainerHigh（实机截图上是一片淡紫），
      // 与全站白卡不一致，弹窗会被读成「另一套主题」。
      backgroundColor: AppTheme.cardBg,
      child: SizedBox(
        key: const ValueKey('threshold-popup-card'),
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppTheme.warn, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 12),
                Text(body,
                    style:
                        const TextStyle(color: AppTheme.textSub, fontSize: 13)),
                const SizedBox(height: 18),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                  TextButton(onPressed: onNever, child: const Text('不再提示')),
                  FilledButton(onPressed: onAction, child: Text(actionLabel)),
                ]),
              ]),
        ),
      ),
    );
  }
}

/// 线性占用条
class UsageBar extends StatelessWidget {
  const UsageBar(
      {super.key,
      required this.label,
      required this.ratio,
      required this.detail});
  final String label;
  final double ratio;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final color = ratio > 0.9
        ? AppTheme.danger
        : (ratio > 0.75 ? AppTheme.warn : AppTheme.primary);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const Spacer(),
        Text(detail,
            style: const TextStyle(color: AppTheme.textSub, fontSize: 11)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
            value: ratio.clamp(0, 1),
            minHeight: 6,
            color: color,
            backgroundColor: const Color(0xFFE8EDF7)),
      ),
    ]);
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, this.text = '暂无数据'});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset('assets/images/img_empty_content.png',
            width: 120,
            errorBuilder: (_, __, ___) => const Icon(Icons.inbox_outlined,
                size: 64, color: AppTheme.textSub)),
        const SizedBox(height: 10),
        Text(text, style: const TextStyle(color: AppTheme.textSub)),
      ]),
    );
  }
}

/// 扫描中横幅（参考实现 Lottie：acceleration_loading / deep_scan_loading …）
class ScanningBanner extends StatelessWidget {
  const ScanningBanner(
      {super.key,
      this.lottie = 'deep_scan_loading.json',
      required this.text,
      this.onCancel});
  final String lottie;
  final String text;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    // 两个调用处都在 Center 里；这里不收窄的话 Row 会吃满可用宽度，
    // 「正在检测…」贴左、「取消」贴右，中间一整条空白（实机图实测）。
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _ScanningVisual(lottie: lottie),
      const SizedBox(width: 10),
      Text(text),
      if (onCancel != null) ...[
        const SizedBox(width: 16),
        TextButton(onPressed: onCancel, child: const Text('取消')),
      ],
    ]);
  }
}

/// 扫描中的动图：参考实现这一格放的是 `assets/lottie/*.json` 的循环动画，
/// `ScanningBanner` 过去只收了 `lottie` 参数从没用它画过东西（页面上一律是
/// 静态 img_scanning.png）。素材按 .gitignore 不入库，clean-room 分支拿不到
/// json，所以两级回落：Lottie → 静态图 → 进度环，缺素材不能红屏。
class _ScanningVisual extends StatelessWidget {
  const _ScanningVisual({required this.lottie});
  final String lottie;

  @override
  Widget build(BuildContext context) {
    return Lottie.asset(
      'assets/lottie/$lottie',
      width: 40,
      height: 40,
      errorBuilder: (_, __, ___) => Image.asset(
        'assets/images/img_scanning.png',
        width: 34,
        errorBuilder: (_, __, ___) =>
            const CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

/// 应用图标 —— Rust 侧 SHGetFileInfo 取到的 RGBA 经 decodeImageFromPixels
/// 解码成 ui.Image 后用 RawImage 画，不走 PNG/JPEG 编码。
/// [loader] 可注入（默认 [RustApi.appIcon]）：测试给假像素即可脱离 frb 桥验证
/// 解码与回落两条路径。取不到图标（无 DisplayIcon / 文件不存在 / 无权限）时
/// 回落成占位图标，列表其余信息照用。
/// ui.Image 是栅格资源，必须随 widget 销毁，否则列表反复进出会累积泄漏。
class AppIconImage extends StatefulWidget {
  const AppIconImage(
      {super.key, required this.displayIcon, this.loader, this.size = 32});

  final String displayIcon;
  final Future<AppIcon?> Function(String displayIcon)? loader;
  final double size;

  @override
  State<AppIconImage> createState() => _AppIconImageState();
}

class _AppIconImageState extends State<AppIconImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AppIconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进程列表每 3s 按内存重排，行会按位置复用：图标来源换了就必须重新取，
    // 否则这一行会一直挂着上一个进程的图标。
    if (oldWidget.displayIcon != widget.displayIcon) _load();
  }

  Future<void> _load() async {
    final requested = widget.displayIcon;
    final icon =
        await (widget.loader ?? RustApi.instance.appIcon)(widget.displayIcon);
    if (icon == null || !mounted) return;
    try {
      final image = await _decodePixels(icon);
      if (!mounted || requested != widget.displayIcon) {
        image?.dispose(); // 页面已关或行已换来源，解码结果没人用，立刻释放
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
    } catch (e) {
      // 解码失败也要留痕，否则现场只看到一排占位图，无从判断挂在哪一层
      await RustApi.instance.logError('图标解码失败 [${widget.displayIcon}]: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Icon(Icons.extension_outlined,
          color: AppTheme.primary, size: widget.size);
    }
    return RawImage(image: image, width: widget.size, height: widget.size);
  }
}

/// decodeImageFromPixels 是回调式接口，包成 Future 才能接进 async 流程。
Future<ui.Image?> _decodePixels(AppIcon icon) {
  final completer = Completer<ui.Image?>();
  ui.decodeImageFromPixels(icon.rgba, icon.width, icon.height,
      ui.PixelFormat.rgba8888, (image) => completer.complete(image));
  return completer.future;
}
