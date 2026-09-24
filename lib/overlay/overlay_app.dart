import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../theme/custom_theme.dart';
import 'overlay_home.dart';

/// 悬浮窗根 Widget
///
/// 负责加载当前主题并构建 [MaterialApp]，使悬浮窗内的 UI 与主 App 保持一致的
/// 字体和语义化色槽。
class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});

  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  AppThemeDefinition _theme = AppThemes.defaultTheme;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  /// 从 SharedPreferences 读取用户选择的主题 ID
  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final themeId = prefs.getString('selected_theme');
      // 预设 findById；'custom' 按保存的配置现建，坏配置回退默认青
      var theme = await loadThemeById(themeId) ?? AppThemes.defaultTheme;
      // ⚠️ 新拟物主题降级为默认青（悬浮窗视觉零变化）：
      // 悬浮窗 FlutterView 背景透明，拟物的外扩散双阴影会被窗口边缘硬裁剪成
      // 灰块（透明窗口教训，overlay_constants 同类约束），且灰底面板与桌面
      // 叠加突兀。2026-09-17 拍板：本期悬浮窗不拟物化，选中拟物主题时主窗
      // 正常渲染、悬浮窗回落 default_teal。
      if (theme.id == 'neumorphism') {
        theme = AppThemes.defaultTheme;
        print('🎨 [OverlayApp] 拟物主题不适用于悬浮窗，降级为默认青');
      }
      if (mounted) {
        setState(() => _theme = theme);
      }
      print('🎨 [OverlayApp] 加载主题: ${theme.name}');
    } catch (e) {
      print('⚠️ [OverlayApp] 加载主题失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme.toThemeData(),
      // 强制中文本地化（与主 App 一致）：悬浮窗闹钟转轮选择器
      //（CalendarConfirmSheet 的 CupertinoDatePicker）的月份/时段文案依赖
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const OverlayHome(),
    );
  }
}
