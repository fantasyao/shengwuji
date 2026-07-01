import 'package:flutter/material.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 快捷方式管理器
/// 单例模式，负责管理应用快捷方式的注册和触发处理
class ShortcutManager {
  static final ShortcutManager _instance = ShortcutManager._internal();
  factory ShortcutManager() => _instance;
  ShortcutManager._internal();

  static const String _shortcutLaunchKey = 'shortcut_launch_record';
  static const String _shortcutTypeRecord = 'action_quick_record';

  final QuickActions _quickActions = const QuickActions();

  /// 初始化快捷方式
  /// [onQuickRecord] 快速录音快捷方式触发时的回调
  Future<void> initialize(VoidCallback onQuickRecord) async {
    // 动态快捷方式已停用，改用静态快捷方式（shortcuts.xml）
    // 避免长按时出现两个重复的"快速录音"
    // await _quickActions.setShortcutItems(<ShortcutItem>[
    //   const ShortcutItem(
    //     type: _shortcutTypeRecord,
    //     localizedTitle: '快速录音',
    //     icon: 'ic_record_shortcut',
    //   ),
    // ]);

    // 监听快捷方式触发
    _quickActions.initialize((shortcutType) {
      if (shortcutType == _shortcutTypeRecord) {
        _markShortcutLaunch();
        onQuickRecord();
      }
    });
  }

  /// 标记从快捷方式启动
  Future<void> _markShortcutLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shortcutLaunchKey, true);
  }

  /// 检查是否从快捷方式启动（调用后自动清除标志）
  /// 用于处理 App 完全关闭后通过快捷方式启动的情况
  Future<bool> checkAndClearShortcutLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final launched = prefs.getBool(_shortcutLaunchKey) ?? false;
    if (launched) {
      await prefs.remove(_shortcutLaunchKey);
    }
    return launched;
  }
}
