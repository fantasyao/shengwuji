import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_extension.dart';
import '../utils/recents_visibility.dart';
import '../utils/tab_visibility.dart';
import 'settings_widgets.dart';

/// 「眼不见为净」二级页（2026-10-22）
///
/// 把原一级页「功能页面」两个 Tab 隐藏开关与「后台隐藏（防误杀）」聚合到
/// 一处：前者重启生效（main.dart main() 预读同一组 prefs key），后者写
/// prefs 即真值源并经 [RecentsVisibility] 通道实时生效。
class VisibilitySettingsPage extends StatefulWidget {
  const VisibilitySettingsPage({super.key});

  @override
  State<VisibilitySettingsPage> createState() => _VisibilitySettingsPageState();
}

class _VisibilitySettingsPageState extends State<VisibilitySettingsPage> {
  bool _recordTabHidden = false;
  bool _listTabHidden = false;
  bool _excludeFromRecents = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recordTabHidden = prefs.getBool(prefKeyRecordTabHidden) ?? false;
      _listTabHidden = prefs.getBool(prefKeyListTabHidden) ?? false;
      _excludeFromRecents = prefs.getBool('exclude_from_recents') ?? false;
    });
  }

  Future<void> _saveTabVisibility({
    required bool recordHidden,
    required bool listHidden,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyRecordTabHidden, recordHidden);
    await prefs.setBool(prefKeyListTabHidden, listHidden);
    print(
      '🔧 [Settings] tab_visibility recordHidden=$recordHidden listHidden=$listHidden',
    );
  }

  Future<void> _onTabHiddenChanged({bool? record, bool? list}) async {
    setState(() {
      if (record != null) _recordTabHidden = record;
      if (list != null) _listTabHidden = list;
    });
    await _saveTabVisibility(
      recordHidden: _recordTabHidden,
      listHidden: _listTabHidden,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已保存，重启 App 后生效'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onExcludeFromRecentsChanged(bool value) async {
    setState(() => _excludeFromRecents = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('exclude_from_recents', value);
    await RecentsVisibility.setExcludeFromRecents(value);
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '眼不见为净',
          style: TextStyle(color: ext.textPrimary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: ext.isDarkOverlay
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SettingsSectionTitle('主界面页面'),
          SettingsCard(
            child: Column(
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text('隐藏存物品页', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '隐藏语音录入物品页，搬家模式一并隐藏。重启 App 后生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _recordTabHidden,
                  onChanged: (v) => _onTabHiddenChanged(record: v),
                ),
                buildSettingsSwitchTile(
                  context,
                  title: const Text('隐藏查物品页', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '隐藏物品位置列表页，重启 App 后生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _listTabHidden,
                  onChanged: (v) => _onTabHiddenChanged(list: v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionTitle('后台'),
          SettingsCard(
            child: buildSettingsSwitchTile(
              context,
              title: const Text('后台隐藏', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '开启后多任务页面不显示本 App，防误划清除；回 App 点桌面图标；彻底退出需到系统应用信息里强行停止',
                style: TextStyle(fontSize: 11, color: ext.textHint),
              ),
              value: _excludeFromRecents,
              onChanged: _onExcludeFromRecentsChanged,
            ),
          ),
        ],
      ),
    );
  }
}
