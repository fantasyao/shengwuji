import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_extension.dart';
import '../utils/pro_gate.dart';
import '../utils/quick_record_auto_stop.dart'; // 快速录音说完自动停止配置（key/档位唯一真值，两个录音入口开录时读同一组 key）
import '../utils/volume_gesture_config.dart'; // 音量键手势槽位配置（4 槽位动作选择器）
import 'accessibility_check.dart';
import 'settings_widgets.dart';

/// 「音量键快捷操作」二级页（zcode: 2026-09 设置页下沉——原主页分组整体搬入：
/// 无障碍服务状态 + 4 手势槽位 + 录音静音/说完自动停止开关。prefs key 与
/// Kotlin 无障碍服务侧、录音入口读取方全部不变。主页入口行保留状态点，
/// 主页与本页各自 resume 重查）
class VolumeKeySettingsPage extends StatefulWidget {
  const VolumeKeySettingsPage({super.key});

  @override
  State<VolumeKeySettingsPage> createState() => _VolumeKeySettingsPageState();
}

class _VolumeKeySettingsPageState extends State<VolumeKeySettingsPage>
    with WidgetsBindingObserver {
  // 无障碍服务是否已开启（null=检测失败：与「未开启」区分，UI 显式提示而非误导用户去开无障碍——服务可能明明开着）
  bool? _isAccessibilityEnabled = false;
  bool _isProUnlocked = false;
  bool _keepMutedOnVolumeDownEnabled = true; // 按音量减保持静音开关，默认开启
  bool _singleClickStopEnabled = false; // 录音中单击键结束录音开关，默认关（与上面互斥二选一）
  bool _quickRecordAutoStopEnabled = false; // 说完自动停止开关，默认关
  int _quickRecordAutoStopSeconds = quickRecordAutoStopDefaultSeconds; // 静音等待秒数（3/5/8 档）
  // 音量键手势槽位 → 动作映射（key 为 VolumeGestureSlot.* 常量；
  // 写入方 _loadVolumeGestureActions/_saveGestureAction，读取方本页 4 行槽位选择器）
  Map<String, String> _gestureActions = {};
  // 长按触发阈值（毫秒，400/500/800/1200 档）：两个「长按」手势共用；
  // Kotlin 无障碍服务每次按键 DOWN 读同一落盘 key，无需 MethodChannel
  int _longPressMs = VolumeLongPressMs.defaultMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibilityStatus();
    _loadProUnlockStatus();
    _loadVolumeGestureActions();
    _loadLongPressMs();
    _loadKeepMutedOnVolumeDown();
    _loadSingleClickStop();
    _loadQuickRecordAutoStop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从系统设置返回时刷新无障碍服务状态
      _checkAccessibilityStatus();
    }
  }

  void _loadProUnlockStatus() async {
    final unlocked = await ProGate.isUnlocked();
    if (mounted) {
      setState(() => _isProUnlocked = unlocked);
    }
  }

  /// 悬浮窗系动作的 Pro 门禁：已解锁返回 true 放行；未解锁弹付费弹窗并返回
  /// false（调用方不写 prefs）。弹窗关闭后重读解锁状态刷新 Pro 徽章
  Future<bool> _ensureOverlayPro() async {
    final ok = await ProGate.tryAccess(context);
    if (!ok) {
      _loadProUnlockStatus();
      return false;
    }
    return true;
  }

  void _checkAccessibilityStatus() async {
    final enabled = await checkAccessibilityServiceEnabled();
    if (mounted) {
      setState(() => _isAccessibilityEnabled = enabled);
    }
  }

  // --- 音量键手势槽位配置（4 槽位 × 5 动作）---
  /// 加载：新 key 优先，否则按旧配置推导（读取方：本页 4 行选择器；Kotlin 无障碍服务侧另有同规则 fallback）
  Future<void> _loadVolumeGestureActions() async {
    final prefs = await SharedPreferences.getInstance();
    final actions = await loadVolumeGestureActions(prefs);
    if (mounted) setState(() => _gestureActions = actions);
  }

  /// 保存：新 key 的唯一写入方（原生侧每次按键直接读落盘 prefs，无需 MethodChannel 通知）
  Future<void> _saveGestureAction(String slot, String action) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(slot, action);
    setState(() => _gestureActions[slot] = action);
    print('🔧 [Settings] 手势动作 $slot=$action');
  }

  // --- 长按触发阈值（400/500/800/1200 档）---
  Future<void> _loadLongPressMs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _longPressMs = VolumeLongPressMs.normalize(
        prefs.getInt(VolumeLongPressMs.prefKey),
      );
    });
  }

  Future<void> _saveLongPressMs(int ms) async {
    setState(() => _longPressMs = ms);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(VolumeLongPressMs.prefKey, ms);
    print('🔧 [Settings] volume_long_press_ms=$ms');
  }

  // --- 按音量减保持静音开关 ---
  Future<void> _loadKeepMutedOnVolumeDown() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _keepMutedOnVolumeDownEnabled =
            prefs.getBool('keep_muted_on_volume_down') ?? true;
      });
    }
  }

  Future<void> _saveKeepMutedOnVolumeDown(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('keep_muted_on_volume_down', enabled);
    if (!enabled) {
      await prefs.setBool('mute_hint_enabled', false);
    }
    // 互斥二选一：开启保持静音时自动关闭「单击键结束录音」——录音中单击音量键
    // 变成停录后不再走 adjustVolume，keep_muted 失去触发入口，两者同开语义矛盾
    if (enabled && _singleClickStopEnabled) {
      await prefs.setBool(kSingleClickStopRecordingKey, false);
      if (mounted) setState(() => _singleClickStopEnabled = false);
    }
    if (mounted) {
      setState(() {
        _keepMutedOnVolumeDownEnabled = enabled;
      });
    }
  }

  // --- 录音中单击键结束录音开关（与按音量减保持静音互斥二选一）---
  // 读取方：Kotlin 无障碍服务每次按键实时读落盘；overlay 语音速记 start()
  // 读同一 key 选停止提示文案
  Future<void> _loadSingleClickStop() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _singleClickStopEnabled =
            prefs.getBool(kSingleClickStopRecordingKey) ?? false;
      });
    }
  }

  Future<void> _saveSingleClickStop(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kSingleClickStopRecordingKey, enabled);
    // 互斥二选一：开启单击停录时自动关闭「按音量减保持静音」及其联动的静音提示
    //（录音中单击音量减变成停录，keep_muted 失去触发入口，两者同开语义矛盾）
    if (enabled && _keepMutedOnVolumeDownEnabled) {
      await prefs.setBool('keep_muted_on_volume_down', false);
      await prefs.setBool('mute_hint_enabled', false);
      if (mounted) setState(() => _keepMutedOnVolumeDownEnabled = false);
    }
    if (mounted) setState(() => _singleClickStopEnabled = enabled);
    print('🔧 [Settings] single_click_stop_recording=$enabled');
  }

  // --- 快速录音说完自动停止 ---
  // 读取方：overlay_voice_memo / diary_tab（开录时 reload 后读，key 见
  // quick_record_auto_stop.dart）
  Future<void> _loadQuickRecordAutoStop() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _quickRecordAutoStopEnabled =
          prefs.getBool(quickRecordAutoStopEnabledPrefKey) ?? false;
      final seconds =
          prefs.getInt(quickRecordAutoStopSecondsPrefKey) ??
          quickRecordAutoStopDefaultSeconds;
      _quickRecordAutoStopSeconds = quickRecordAutoStopSecondsChoices
          .contains(seconds)
          ? seconds
          : quickRecordAutoStopDefaultSeconds;
    });
  }

  Future<void> _saveQuickRecordAutoStopEnabled(bool value) async {
    setState(() => _quickRecordAutoStopEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(quickRecordAutoStopEnabledPrefKey, value);
    print('🔧 [Settings] quick_record_auto_stop_enabled=$value');
  }

  Future<void> _saveQuickRecordAutoStopSeconds(int seconds) async {
    setState(() => _quickRecordAutoStopSeconds = seconds);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(quickRecordAutoStopSecondsPrefKey, seconds);
    print('🔧 [Settings] quick_record_auto_stop_seconds=$seconds');
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "音量键快捷操作",
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
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isAccessibilityEnabled == true
                          ? Icons.check_circle
                          : _isAccessibilityEnabled == null
                          ? Icons.help_outline
                          : Icons.cancel_outlined,
                      color: _isAccessibilityEnabled == true
                          ? ext.positiveText
                          : ext.textHint,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isAccessibilityEnabled == true
                          ? "已开启"
                          : _isAccessibilityEnabled == null
                          ? "检测失败"
                          : "未开启",
                      style: TextStyle(
                        color: _isAccessibilityEnabled == true
                            ? ext.positiveText
                            : ext.textHint,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _isAccessibilityEnabled == true
                      ? "在任意界面通过音量键手势快速唤起录音、笔记或悬浮窗"
                      : _isAccessibilityEnabled == null
                      ? "无法确认服务状态，可前往系统设置查看或回到本页自动重试"
                      : "开启后，长按或双击音量键即可快速唤起对应功能",
                  style: TextStyle(color: ext.textSecondary, fontSize: 13),
                ),
                // 4 手势槽位动作选择（仅在服务开启时显示）
                if (_isAccessibilityEnabled == true) ...[
                  const SizedBox(height: 12),
                  // 长按行标题的时长随阈值档位动态显示（0.4/0.5/0.8/1.2 秒）
                  _buildGestureSelectorRow(
                    '长按音量加（约${(_longPressMs / 1000).toStringAsFixed(1)}秒）',
                    VolumeGestureSlot.longPressUp,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '长按音量减（约${(_longPressMs / 1000).toStringAsFixed(1)}秒）',
                    VolumeGestureSlot.longPressDown,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '双击音量加（0.3秒内）',
                    VolumeGestureSlot.doubleClickUp,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '双击音量减（0.3秒内）',
                    VolumeGestureSlot.doubleClickDown,
                  ),
                  const SizedBox(height: 14),
                  _buildLongPressMsSelector(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 静音相关开关与手势选择器一样仅在服务开启时有意义（音量键按不到就无从触发）
          if (_isAccessibilityEnabled == true) ...[
            const SettingsSectionTitle("录音静音"),
            SettingsCard(
              child: Column(
                children: [
                  buildSettingsSwitchTile(
                    context,
                    title: const Text('单击键结束录音', style: TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '录音中单击音量键/耳机线控键/相机键立即停止并转写，无需再长按；与「按音量减保持静音」二选一',
                      style: TextStyle(fontSize: 11, color: ext.textHint),
                    ),
                    value: _singleClickStopEnabled,
                    onChanged: (val) => _saveSingleClickStop(val),
                  ),
                  buildSettingsSwitchTile(
                    context,
                    title: const Text(
                      '按音量减保持静音',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '快捷录音/悬浮窗录音期间按音量减键，录音结束后继续保持静音（与单击键结束录音二选一）',
                      style: TextStyle(fontSize: 11, color: ext.textHint),
                    ),
                    value: _keepMutedOnVolumeDownEnabled,
                    onChanged: (val) => _saveKeepMutedOnVolumeDown(val),
                  ),
                  // 静音提示开关只在保持静音开启时有意义（原主页同款联动）
                  FutureBuilder<bool>(
                    future: SharedPreferences.getInstance().then(
                      (prefs) => prefs.getBool('mute_hint_enabled') ?? true,
                    ),
                    builder: (context, snapshot) {
                      return buildSettingsSwitchTile(
                        context,
                        title: const Text('静音提示'),
                        subtitle: const Text('快速录音静音时显示提示文案'),
                        value: snapshot.data ?? true,
                        onChanged: _keepMutedOnVolumeDownEnabled
                            ? (value) async {
                                final prefs =
                                    await SharedPreferences.getInstance();
                                await prefs.setBool('mute_hint_enabled', value);
                                // 触发重建以更新UI
                                setState(() {});
                              }
                            : null,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            const SettingsSectionTitle("说完自动停止"),
            SettingsCard(
              child: Column(
                children: [
                  buildSettingsSwitchTile(
                    context,
                    title: const Text(
                      '说完自动停止',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '快速录音（音量键/悬浮窗速记）检测到说完话后静音，自动停止并转写；一次都没说话不自动停',
                      style: TextStyle(fontSize: 11, color: ext.textHint),
                    ),
                    value: _quickRecordAutoStopEnabled,
                    onChanged: (val) => _saveQuickRecordAutoStopEnabled(val),
                  ),
                  if (_quickRecordAutoStopEnabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: _buildQuickRecordAutoStopSecondsSelector(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          ElevatedButton.icon(
            onPressed: openAccessibilitySettings,
            icon: Icon(
              _isAccessibilityEnabled == true ? Icons.settings : Icons.launch,
              size: 20,
            ),
            label: Text(
              _isAccessibilityEnabled == true
                  ? "已开启，前往系统设置"
                  : _isAccessibilityEnabled == null
                  ? "前往系统设置确认"
                  : "前往系统设置开启",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: ext.primary,
              foregroundColor: ext.textOnPrimary,
              elevation: 0,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "提示：在无障碍设置中找到「声物记」并开启服务",
            style: TextStyle(color: ext.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // --- 音量键手势槽位动作选择器行（原 settings_tab._buildGestureSelectorRow 搬入：
  // 标题 Text + 6 间距 + Wrap ChoiceChip）---
  Widget _buildGestureSelectorRow(String title, String slot) {
    final ext = AppThemeExtension.of(context);
    final options = [
      (VolumeGestureAction.none, '无动作', Icons.block),
      (VolumeGestureAction.showOverlay, '显示悬浮窗', Icons.picture_in_picture_alt),
      (VolumeGestureAction.overlayRecord, '悬浮窗录音', Icons.mic),
      (VolumeGestureAction.quickRecord, 'APP内录音', Icons.fiber_manual_record),
      (VolumeGestureAction.quickTextNote, 'APP内笔记', Icons.edit_note),
      (VolumeGestureAction.overlayNewNote, '悬浮窗笔记', Icons.note_add_outlined),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (action, label, icon) = opt;
            final selected =
                (_gestureActions[slot] ?? VolumeGestureAction.none) == action;
            // 悬浮窗系动作未解锁时展示 Pro 徽章（门禁在 onSelected 拦截，不写 prefs）
            final isOverlayAction =
                action == VolumeGestureAction.showOverlay ||
                action == VolumeGestureAction.overlayRecord ||
                action == VolumeGestureAction.overlayNewNote;
            return ChoiceChip(
              // ⚠️ ChoiceChip 的 avatar 槽位固定 24×24（M3 Container 定宽高居中），
              // 塞 Row 会溢出压到 label（防再犯：徽章必须放 label 侧）
              avatar: Icon(
                icon,
                size: 16,
                color: selected ? ext.textOnPrimary : ext.primary,
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  if (isOverlayAction && !_isProUnlocked) ...[
                    const SizedBox(width: 4),
                    const SettingsProBadge(),
                  ],
                ],
              ),
              selected: selected,
              selectedColor: ext.primary,
              labelStyle: TextStyle(
                color: selected ? ext.textOnPrimary : ext.textPrimary,
                fontSize: 13,
              ),
              onSelected: (_) async {
                if (isOverlayAction && !await _ensureOverlayPro()) return;
                _saveGestureAction(slot, action);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  // --- 长按触发阈值档位选择器（两个「长按」手势共用；写 prefs 后 Kotlin 每次
  // 按键 DOWN 实时读。档位下限 400ms 的误触权衡见 VolumeLongPressMs.choices 注释；
  // 非悬浮窗 Pro 功能，无门禁，样式对齐下方说完自动停止秒数选择器）---
  Widget _buildLongPressMsSelector() {
    final ext = AppThemeExtension.of(context);
    const options = [
      (400, '快 · 0.4秒'),
      (500, '标准 · 0.5秒'),
      (800, '慢 · 0.8秒'),
      (1200, '很慢 · 1.2秒'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '长按触发时长',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (ms, label) = opt;
            final selected = _longPressMs == ms;
            return ChoiceChip(
              avatar: Icon(
                Icons.timer_outlined,
                size: 16,
                color: selected ? ext.textOnPrimary : ext.primary,
              ),
              label: Text(label),
              selected: selected,
              selectedColor: ext.primary,
              labelStyle: TextStyle(
                color: selected ? ext.textOnPrimary : ext.textPrimary,
                fontSize: 13,
              ),
              onSelected: (_) => _saveLongPressMs(ms),
            );
          }).toList(),
        ),
        const SizedBox(height: 4),
        Text(
          '两个「长按」手势共用的按住时长。设得过短可能把按得偏重的单击误判为长按',
          style: TextStyle(color: ext.textHint, fontSize: 11),
        ),
      ],
    );
  }

  // --- 快速录音静音等待秒数选择器（原 settings_tab 搬入；非悬浮窗 Pro 功能，无门禁）---
  Widget _buildQuickRecordAutoStopSecondsSelector() {
    final ext = AppThemeExtension.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: quickRecordAutoStopSecondsChoices.map((seconds) {
        final selected = _quickRecordAutoStopSeconds == seconds;
        return ChoiceChip(
          avatar: Icon(
            Icons.timer_outlined,
            size: 16,
            color: selected ? ext.textOnPrimary : ext.primary,
          ),
          label: Text('$seconds 秒'),
          selected: selected,
          selectedColor: ext.primary,
          labelStyle: TextStyle(
            color: selected ? ext.textOnPrimary : ext.textPrimary,
            fontSize: 13,
          ),
          onSelected: (_) => _saveQuickRecordAutoStopSeconds(seconds),
        );
      }).toList(),
    );
  }
}
