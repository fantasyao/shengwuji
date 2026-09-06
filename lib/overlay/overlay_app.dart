import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
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
      final theme = AppThemes.findById(themeId) ?? AppThemes.defaultTheme;
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
