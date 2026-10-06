import 'package:flutter/material.dart';

/// 主题 —— 蓝白管家风格（与参考实现视觉基调一致；色值为近似，可对照原图校准）
class AppTheme {
  static const primary = Color(0xFF2A6BFF);
  static const primaryDeep = Color(0xFF1E4FD6);
  static const headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5B93FF), Color(0xFF2A6BFF)],
  );
  static const bg = Color(0xFFF3F6FC);
  static const cardBg = Colors.white;
  static const textMain = Color(0xFF1F2533);
  static const textSub = Color(0xFF8A93A6);
  static const ok = Color(0xFF2ECC71);
  static const warn = Color(0xFFF5A623);
  static const danger = Color(0xFFE64545);

  static ThemeData light() {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme:
          base.colorScheme.copyWith(primary: primary, secondary: primary),
      textTheme: base.textTheme.apply(
        bodyColor: textMain,
        fontFamily: 'SourceHanSansCN',
      ),
    );
  }
}
