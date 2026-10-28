import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_extension.dart';
import '../utils/diary_sync_bridge.dart';
import '../utils/note_lock_settings.dart';
import '../utils/note_unlock_session.dart';
import 'settings_widgets.dart';

/// 「日记智能与交互」二级页（2026-10-22）
///
/// 原一级页同分区四个开关下沉到本页：笔记锁定总开关、日记智能识别物品、
/// 日记智能查询物品位置、交换单击与双击。prefs key 与各读取方不变
///（DiaryTab / OverlayHome / DiaryWebServer 共读）。
class DiaryInteractionSettingsPage extends StatefulWidget {
  const DiaryInteractionSettingsPage({super.key});

  @override
  State<DiaryInteractionSettingsPage> createState() =>
      _DiaryInteractionSettingsPageState();
}

class _DiaryInteractionSettingsPageState
    extends State<DiaryInteractionSettingsPage> {
  bool _noteLockEnabled = true;
  bool _itemTransferEnabled = true;
  bool _queryAnswerEnabled = true;
  bool _swapTapLongPress = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final noteLock = await NoteLockSettings.isEnabled();
    if (!mounted) return;
    setState(() {
      _noteLockEnabled = noteLock;
      _itemTransferEnabled =
          prefs.getBool('diary_item_transfer_enabled') ?? true;
      _queryAnswerEnabled = prefs.getBool('diary_query_answer_enabled') ?? true;
      _swapTapLongPress =
          prefs.getBool('diary_card_swap_tap_longpress') ?? false;
    });
  }

  /// 关闭时同步结束当前解锁会话（重新开启后已锁定笔记立即恢复打码，
  /// 不沿用关闭前残留的 5 分钟会话）；bump DiarySyncBridge 让已常驻的
  /// 悬浮窗下次展开重读开关（跨 engine 无推送通道）
  Future<void> _saveNoteLockEnabled(bool enabled) async {
    setState(() => _noteLockEnabled = enabled);
    await NoteLockSettings.setEnabled(enabled);
    if (!enabled) {
      await NoteUnlockSession.revoke();
    }
    await DiarySyncBridge.bump();
    print('🔧 [Settings] note_lock_enabled=$enabled');
  }

  Future<void> _saveItemTransferEnabled(bool enabled) async {
    setState(() => _itemTransferEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diary_item_transfer_enabled', enabled);
  }

  Future<void> _saveQueryAnswerEnabled(bool enabled) async {
    setState(() => _queryAnswerEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diary_query_answer_enabled', enabled);
  }

  Future<void> _saveSwapTapLongPress(bool enabled) async {
    setState(() => _swapTapLongPress = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('diary_card_swap_tap_longpress', enabled);
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '日记智能与交互',
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
          const SettingsSectionTitle('隐私'),
          SettingsCard(
            child: buildSettingsSwitchTile(
              context,
              title: const Text('笔记锁定', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '随手记和悬浮窗卡片可加锁，锁屏时旁人也看不到内容。关闭后锁按钮隐藏、已锁定笔记按明文显示（锁定标记保留，重新开启恢复保护）',
                style: TextStyle(fontSize: 11, color: ext.textHint),
              ),
              value: _noteLockEnabled,
              onChanged: _saveNoteLockEnabled,
            ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionTitle('智能识别与交互'),
          SettingsCard(
            child: Column(
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text('日记智能识别物品', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '识别"物品+位置"语句并显示转存按钮',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _itemTransferEnabled,
                  onChanged: _saveItemTransferEnabled,
                ),
                buildSettingsSwitchTile(
                  context,
                  title: const Text(
                    '日记智能查询物品位置',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '识别"XX在哪儿"语句并显示答案区',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _queryAnswerEnabled,
                  onChanged: _saveQueryAnswerEnabled,
                ),
                const Divider(height: 1),
                buildSettingsSwitchTile(
                  context,
                  title: const Text('交换单击与双击', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '开启后：单击=编辑、双击=复制（默认：单击=复制、双击=编辑）；长按=大爆炸分词不受开关影响。修改后需重启 App 生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _swapTapLongPress,
                  onChanged: _saveSwapTapLongPress,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
