import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../overlay/overlay_constants.dart'; // OverlayConstants.autoHide*（自动隐藏档位唯一真值，与 overlay engine 共用）
import '../theme/app_theme_extension.dart';
import '../utils/pro_gate.dart'; // ProGate：is_pro_unlocked 读写与 Pro 弹窗门禁
import 'settings_widgets.dart';

/// 「悬浮窗设置」二级页（zcode: 2026-09 设置页下沉——原主页「悬浮窗」分组整体
/// 搬入：自动隐藏时长 / 停靠侧 / 贴边竖线两开关；2026-09-22 增「把手大小」
/// 三档。prefs key 与 overlay engine、原生窗口 Gravity 等读取方全部不变；
/// 悬浮窗配置同走 Pro 门禁（原 _ensureOverlayPro 语义，改用共享
/// ProGate.tryAccess 实现））
class OverlaySettingsPage extends StatefulWidget {
  const OverlaySettingsPage({super.key});

  @override
  State<OverlaySettingsPage> createState() => _OverlaySettingsPageState();
}

class _OverlaySettingsPageState extends State<OverlaySettingsPage> {
  bool _isProUnlocked = false;
  int _autoHideSeconds = OverlayConstants.autoHideDefaultSeconds; // 5/10/30 或 autoHideNeverSeconds=永久
  bool _edgeLineEnabled = true; // 自动隐藏后保留贴边竖线，默认开
  bool _edgeLineTapEnabled = true; // 点按贴边竖线回把手，默认开
  bool _overlaySideLeft = false; // 停靠侧：false=右缘/true=左缘，默认右缘
  int _handleSizePercent = OverlayConstants.handleSizeDefaultPercent; // 把手大小档位 100/75/50
  HandleTheme _handleTheme = HandleTheme.duo; // 把手主题：双色药丸/蓝紫/拟物胶囊

  @override
  void initState() {
    super.initState();
    _loadProUnlockStatus();
    _loadOverlaySettings();
  }

  void _loadProUnlockStatus() async {
    final unlocked = await ProGate.isUnlocked();
    if (mounted) {
      setState(() => _isProUnlocked = unlocked);
    }
  }

  /// 加载悬浮窗相关配置（收起后自动隐藏秒数 + 贴边竖线开关 + 停靠侧）
  void _loadOverlaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        // 收起后自动隐藏秒数（读取方：overlay engine 的 _scheduleAutoHide，跨 engine 靠 reload 读新值）
        _autoHideSeconds =
            prefs.getInt('overlay_auto_hide_seconds') ??
            OverlayConstants.autoHideDefaultSeconds;
        // 贴边竖线开关（读取方：同上 _scheduleAutoHide，默认开）
        _edgeLineEnabled =
            prefs.getBool(OverlayConstants.edgeLineEnabledPrefKey) ?? true;
        // 点按竖线回把手开关（读取方：overlay engine 的 _onEdgeLineTap，默认开）
        _edgeLineTapEnabled =
            prefs.getBool(OverlayConstants.edgeLineTapEnabledPrefKey) ?? true;
        // 停靠侧（读取方：overlay engine 的 _refreshSide/_scheduleAutoHide +
        // 原生窗口 Gravity，默认右缘）
        _overlaySideLeft =
            prefs.getBool(OverlayConstants.overlaySideLeftPrefKey) ?? false;
        // 把手大小档位（读取方：overlay engine 的 _refreshSide/_scheduleAutoHide，
        // 非法值兜底默认 100%）
        _handleSizePercent = OverlayConstants.parseHandleSizePercent(
          prefs.getInt(OverlayConstants.handleSizePrefKey),
        );
        // 把手主题（读取方：同上，坏串兜底双色药丸）
        _handleTheme = OverlayConstants.parseHandleTheme(
          prefs.getString(OverlayConstants.handleThemePrefKey),
        );
      });
    }
  }

  /// 保存“收起后自动隐藏”秒数（读取方：overlay engine 的 _scheduleAutoHide）
  Future<void> _saveOverlayAutoHide(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('overlay_auto_hide_seconds', seconds);
    setState(() => _autoHideSeconds = seconds);
    print('🔧 [Settings] overlay_auto_hide_seconds=$seconds');
  }

  /// 保存“自动隐藏后保留贴边竖线”开关（读取方：同上 _scheduleAutoHide 的
  /// 隐藏去向分流——开=缩成竖线驻留，关=彻底移除窗口）
  Future<void> _saveEdgeLineEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.edgeLineEnabledPrefKey, enabled);
    setState(() => _edgeLineEnabled = enabled);
    print('🔧 [Settings] overlay_edge_line_enabled=$enabled');
  }

  /// 保存“点按贴边竖线回把手”开关（读取方：overlay engine 的 _onEdgeLineTap——
  /// 关闭后点按竖线无反应，仅朝屏幕内侧滑动或音量键可展开）
  Future<void> _saveEdgeLineTapEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.edgeLineTapEnabledPrefKey, enabled);
    setState(() => _edgeLineTapEnabled = enabled);
    print('🔧 [Settings] overlay_edge_line_tap_enabled=$enabled');
  }

  /// 保存悬浮窗「停靠侧」（读取方：overlay engine 的 _refreshSide——把手/竖线/
  /// 面板/卡片镜像 + 原生窗口 Gravity START/END。跨 engine 无推送通道，
  /// 悬浮窗下一次展开/收起状态转换整体换侧）
  Future<void> _saveOverlaySide(bool left) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.overlaySideLeftPrefKey, left);
    setState(() => _overlaySideLeft = left);
    print('🔧 [Settings] overlay_side_left=$left');
  }

  /// 保存「把手大小」档位（读取方：overlay engine 的 _refreshSide/_scheduleAutoHide
  /// ——把手胶囊视觉缩放与竖线视觉高度。跨 engine 无推送通道，悬浮窗下一次
  /// 展开/收起状态转换生效，已显示中的把手不瞬变）
  Future<void> _saveHandleSize(int percent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(OverlayConstants.handleSizePrefKey, percent);
    setState(() => _handleSizePercent = percent);
    print('🔧 [Settings] overlay_handle_size_percent=$percent');
  }

  /// 保存「把手主题」（读取方：overlay engine 的 _refreshSide/_scheduleAutoHide
  /// ——把手胶囊配色与内容形态；生效时机同把手大小）
  Future<void> _saveHandleTheme(HandleTheme theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(OverlayConstants.handleThemePrefKey, theme.name);
    setState(() => _handleTheme = theme);
    print('🔧 [Settings] overlay_handle_theme=${theme.name}');
  }

  /// 悬浮窗配置的 Pro 门禁：已解锁返回 true 放行；未解锁弹付费弹窗并返回
  /// false（调用方不写 prefs）。弹窗关闭后重读解锁状态刷新 Pro 徽章
  /// （原 settings_tab._ensureOverlayPro 语义，改用 ProGate 实现）
  Future<bool> _ensureOverlayPro() async {
    final ok = await ProGate.tryAccess(context);
    if (!ok) {
      _loadProUnlockStatus(); // 弹窗里可能已解锁，刷新徽章显示
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "悬浮窗设置",
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
                      Icons.picture_in_picture_alt_outlined,
                      color: ext.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "屏幕边缘随手记面板",
                      style: TextStyle(color: ext.textSecondary, fontSize: 13),
                    ),
                    if (!_isProUnlocked) ...[
                      const SizedBox(width: 6),
                      const SettingsProBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '通过音量键手势召唤悬浮窗（见音量键快捷操作）',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
                const SizedBox(height: 4),
                Text(
                  '收起态把手长按后可上下拖动调整位置；停靠侧可在下方切换屏幕左缘或右缘（滑动方向随侧镜像）',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const SettingsSectionTitle("把手大小"),
          SettingsCard(child: _buildHandleSizeSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("把手主题"),
          SettingsCard(child: _buildHandleThemeSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("收起后自动隐藏"),
          SettingsCard(child: _buildAutoHideSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("停靠侧"),
          SettingsCard(child: _buildOverlaySideSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("贴边竖线"),
          SettingsCard(
            child: Column(
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text(
                    '隐藏后保留贴边竖线',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '自动隐藏后在停靠侧边缘留一条半透明细线（触摸区已加宽易点中），点按回把手、朝屏幕内侧滑动直接展开面板；自动隐藏选「永久」时不生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _edgeLineEnabled,
                  onChanged: (v) async {
                    // 悬浮窗配置同走 Pro 门禁（与自动隐藏时长选择器一致），未解锁不写 prefs
                    if (!await _ensureOverlayPro()) return;
                    _saveEdgeLineEnabled(v);
                  },
                ),
                // 线态点按开关（读取方：overlay engine 的 _onEdgeLineTap）
                buildSettingsSwitchTile(
                  context,
                  title: const Text(
                    '点按竖线展开把手',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '开启后点按贴边竖线回到把手，再点把手展开面板；关闭后点按无反应，仅朝屏幕内侧滑动或音量键可展开',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _edgeLineTapEnabled,
                  onChanged: (v) async {
                    // 同走悬浮窗 Pro 门禁（与上方贴边竖线开关一致）
                    if (!await _ensureOverlayPro()) return;
                    _saveEdgeLineTapEnabled(v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- 悬浮窗「把手主题」三选一（2026-09-22）：双色药丸（默认，历史视觉）/
  // 蓝紫（笔记卡片色系：默认蓝 #6F9AF0 + 灵感标注紫 #AE82E4）/ 拟物胶囊💊
  //（白+珊瑚红立体造型，无图标无文字）。avatar 用上下双色的 16dp 小圆直观
  // 预览各主题配色；生效时机同把手大小
  Widget _buildHandleThemeSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [
      (HandleTheme.duo, '双色药丸'),
      (HandleTheme.bluePurple, '蓝紫'),
      (HandleTheme.pill3d, '拟物胶囊'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (theme, label) = opt;
            final selected = _handleTheme == theme;
            return ChoiceChip(
              // 上下双色小圆 = 把手胶囊配色的迷你预览
              avatar: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.capsuleTopColor,
                      theme.capsuleTopColor,
                      theme.capsuleBottomColor,
                      theme.capsuleBottomColor,
                    ],
                    stops: const [0.0, 0.5, 0.5, 1.0],
                  ),
                ),
              ),
              label: Text(label),
              selected: selected,
              selectedColor: ext.primary,
              labelStyle: TextStyle(
                color: selected ? ext.textOnPrimary : ext.textPrimary,
                fontSize: 13,
              ),
              onSelected: (_) async {
                // 把手主题属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _saveHandleTheme(theme);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '切换把手胶囊配色：蓝紫与悬浮窗笔记卡片同色系；拟物胶囊为纯造型（无图标文字）。改动在悬浮窗下一次展开/收起后生效',
          style: TextStyle(fontSize: 11, color: ext.textHint),
        ),
      ],
    );
  }

  // --- 悬浮窗「把手大小」三档选择器（2026-09-22，用户反馈把手胶囊有点大）：
  // 标准（100%，历史视觉）/ 小（75%）/ 迷你（50%，胶囊 12×40 放不下竖排文字，
  // 只渲染闪电图标）。只缩视觉不缩窗口（触控面积不变），竖线高度跟随档位等比
  // 缩、宽 4dp 不缩；生效时机同停靠侧——悬浮窗下一次展开/收起状态转换
  Widget _buildHandleSizeSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [
      (100, '标准', 16.0),
      (75, '小', 12.0),
      (50, '迷你', 8.0),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (percent, label, dotSize) = opt;
            final selected = _handleSizePercent == percent;
            return ChoiceChip(
              // 圆点大小随档位递减：图标本身暗示所选档位的视觉大小
              avatar: Icon(
                Icons.circle,
                size: dotSize,
                color: selected ? ext.textOnPrimary : ext.primary,
              ),
              label: Text(label),
              selected: selected,
              selectedColor: ext.primary,
              labelStyle: TextStyle(
                color: selected ? ext.textOnPrimary : ext.textPrimary,
                fontSize: 13,
              ),
              onSelected: (_) async {
                // 把手大小属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _saveHandleSize(percent);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '缩小收起态把手与贴边竖线的视觉大小，触控区域不变；迷你档把手只显示闪电图标。改动在悬浮窗下一次展开/收起后生效',
          style: TextStyle(fontSize: 11, color: ext.textHint),
        ),
      ],
    );
  }

  // --- 悬浮窗收起后自动隐藏时长选择器（原 settings_tab._buildAutoHideSelector 搬入）---
  Widget _buildAutoHideSelector() {
    final ext = AppThemeExtension.of(context);
    // 「永久」写哨兵值 autoHideNeverSeconds（-1）进同一 prefs key，overlay
    // engine 读到即不起隐藏计时（收起态把手常驻）
    final options = [
      (5, '5 秒', Icons.timer_outlined),
      (10, '10 秒', Icons.timer_outlined),
      (30, '30 秒', Icons.timer_outlined),
      (OverlayConstants.autoHideNeverSeconds, '永久', Icons.all_inclusive),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (seconds, label, icon) = opt;
        final selected = _autoHideSeconds == seconds;
        return ChoiceChip(
          avatar: Icon(
            icon,
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
          onSelected: (_) async {
            // 自动隐藏时长属于悬浮窗配置，未解锁 Pro 时门禁（不写 prefs）
            if (!await _ensureOverlayPro()) return;
            _saveOverlayAutoHide(seconds);
          },
        );
      }).toList(),
    );
  }

  // --- 悬浮窗「停靠侧」选择器（原 settings_tab._buildOverlaySideSelector 搬入）：
  // 右缘（缺省，历史行为）/ 左缘。写入 overlay_side_left 后，悬浮窗在下一次
  // 展开/收起状态转换整体换侧——把手与竖线窗口 Gravity（原生直读）、面板
  // 锚点与推屏方向、滑动手势方向、卡片划走方向、录音胶囊贴屏端全部随侧镜像
  Widget _buildOverlaySideSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [
      (false, '屏幕右缘', Icons.chevron_right),
      (true, '屏幕左缘', Icons.chevron_left),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (left, label, icon) = opt;
        final selected = _overlaySideLeft == left;
        return ChoiceChip(
          avatar: Icon(
            icon,
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
          onSelected: (_) async {
            // 停靠侧属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
            if (!await _ensureOverlayPro()) return;
            _saveOverlaySide(left);
          },
        );
      }).toList(),
    );
  }
}
