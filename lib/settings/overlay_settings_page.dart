import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../overlay/overlay_constants.dart'; // OverlayConstants.autoHide*（自动隐藏档位唯一真值，与 overlay engine 共用）
import '../theme/app_theme_extension.dart';
import '../utils/overlay_launcher.dart'; // OverlayLauncher：主 App 内启动悬浮窗通道封装
import '../utils/pro_gate.dart'; // ProGate：is_pro_unlocked 读写与 Pro 弹窗门禁
import '../utils/search_command_detector.dart'; // kVoiceSearchJumpEnabledKey（与 overlay engine 读取方共用）
import 'accessibility_check.dart';
import 'settings_widgets.dart';

/// 「悬浮窗设置」二级页（zcode: 2026-09 设置页下沉——原主页「悬浮窗」分组整体
/// 搬入：自动隐藏时长 / 停靠侧 / 贴边竖线两开关；2026-09-22 增「把手大小」
/// 三档；2026-09-27 增「字体大小」五档；2026-10-06 增「面板高度」可见条数
/// 五档；2026-10-27 增「按钮位置」顶部/底部两档。prefs key 与 overlay engine、
/// 原生窗口 Gravity 等读取方全部不变；悬浮窗配置同走 Pro 门禁（原
/// _ensureOverlayPro 语义，改用共享 ProGate.tryAccess 实现））
class OverlaySettingsPage extends StatefulWidget {
  const OverlaySettingsPage({super.key});

  @override
  State<OverlaySettingsPage> createState() => _OverlaySettingsPageState();
}

class _OverlaySettingsPageState extends State<OverlaySettingsPage> {
  bool _isProUnlocked = false;
  int _autoHideSeconds = OverlayConstants
      .autoHideDefaultSeconds; // 5/10/30 或 autoHideNeverSeconds=永久
  bool _edgeLineEnabled = true; // 自动隐藏后保留贴边竖线，默认开
  bool _edgeLineTapEnabled = true; // 点按贴边竖线回把手，默认开
  bool _overlaySideLeft = false; // 停靠侧：false=右缘/true=左缘，默认右缘
  int _handleSizePercent =
      OverlayConstants.handleSizeDefaultPercent; // 把手大小档位 100/75/50
  HandleTheme _handleTheme = HandleTheme.duo; // 把手主题：双色药丸/蓝紫/拟物胶囊
  int _fontSizeStep =
      OverlayConstants.fontSizeStepDefault; // 字体大小档位 -2~+2（每档 1pt）
  int _panelMaxCards =
      OverlayConstants.panelMaxCardsDefault; // 面板高度（可见条数档位 6~10）
  bool _panelButtonsBottom = false; // 面板按钮条位置：false=顶部（历史行为）/true=底部
  bool _swipeDeleteEnabled = false; // 滑动直接删除笔记（替代滑动归档），默认关
  int _edgeLineMarginDp =
      OverlayConstants.edgeLineMarginDefault; // 竖线距屏幕边缘间距档位 0/8/16
  bool _voiceSearchJumpEnabled = true; // 语音搜索跳转（说完"搜索 xxx"自动开浏览器），默认开
  List<String> _voiceSearchTriggers =
      kDefaultVoiceSearchTriggers; // 触发词（规范化：先长后短）
  bool _screenshotExpandCard = false; // 截图成功后唤出面板并展开当前卡，默认关（历史行为）

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
        // 字体大小档位（读取方：同上，clamp 到 -2~+2 兜底标准档）
        _fontSizeStep = OverlayConstants.parseFontSizeStep(
          prefs.getInt(OverlayConstants.fontSizeStepPrefKey),
        );
        // 滑动直接删除开关（读取方：overlay engine 的 _onCardSwipeDismissed——
        // 动作型开关，划走回调里现场 reload 读，即时生效；默认关=划走归档）
        _swipeDeleteEnabled =
            prefs.getBool(OverlayConstants.swipeDeletePrefKey) ?? false;
        // 竖线距屏幕边缘间距档位（读取方：overlay engine 的
        // _refreshOverlayConfig/_scheduleAutoHide，非法值兜底贴边 0）
        _edgeLineMarginDp = OverlayConstants.parseEdgeLineMargin(
          prefs.getInt(OverlayConstants.edgeLineMarginPrefKey),
        );
        // 面板高度（可见条数档位，读取方：同上 + _buildPanel 的列表限高与
        // 顶部下压偏移，clamp 到 6~10 兜底默认 10）
        _panelMaxCards = OverlayConstants.parsePanelMaxCards(
          prefs.getInt(OverlayConstants.panelMaxCardsPrefKey),
        );
        // 面板按钮条位置（读取方：overlay engine 的
        // _refreshOverlayConfig/_scheduleAutoHide + _buildPanel，默认顶部）
        _panelButtonsBottom =
            prefs.getBool(OverlayConstants.panelButtonsBottomPrefKey) ?? false;
        // 语音搜索跳转开关（读取方：overlay engine 的
        // OverlayVoiceMemoController._transcribeAndSave——转写收尾现场 reload
        // 读，即时生效；默认开）
        _voiceSearchJumpEnabled =
            prefs.getBool(kVoiceSearchJumpEnabledKey) ?? true;
        // 语音搜索触发词（读取方：同上，转写收尾 parseTriggers 解析；
        // 空/非法回落默认白名单）
        _voiceSearchTriggers = SearchCommandDetector.parseTriggers(
          prefs.getString(kVoiceSearchTriggersKey),
        );
        // 截图后展开当前卡开关（读取方：overlay engine 的
        // _onCardCopyLongPress——动作型开关，截图成功收尾现场 reload 读，
        // 即时生效；默认关 = 只 Toast 提示并保持收起）
        _screenshotExpandCard =
            prefs.getBool(OverlayConstants.screenshotExpandCardPrefKey) ??
            false;
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

  /// 保存「字体大小」档位（读取方：overlay engine 的
  /// _refreshOverlayConfig/_scheduleAutoHide——日记面板全部文字基准 ±1pt/档；
  /// 生效时机同把手大小，已显示中的面板不瞬变）
  Future<void> _saveFontSizeStep(int step) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(OverlayConstants.fontSizeStepPrefKey, step);
    setState(() => _fontSizeStep = step);
    print('🔧 [Settings] overlay_font_size_step=$step');
  }

  /// 保存「滑动直接删除」开关（读取方：overlay engine 的 _onCardSwipeDismissed——
  /// 动作型开关，划走回调里现场 reload 读，即时生效无需等状态转换。开启后活跃
  /// 卡划走直接删除（面板顶部撤销胶囊 3 秒内可撤销）；归档入口由卡片顶端
  /// 勾选框保留）
  Future<void> _saveSwipeDeleteEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.swipeDeletePrefKey, enabled);
    setState(() => _swipeDeleteEnabled = enabled);
    print('🔧 [Settings] overlay_swipe_delete_enabled=$enabled');
  }

  /// 保存「竖线距屏幕边缘间距」档位（读取方：overlay engine 的
  /// _refreshOverlayConfig/_scheduleAutoHide——竖线视觉向屏内侧偏移，窗口与
  /// 触摸缓冲区不动。生效时机同把手大小：悬浮窗下一次状态转换）
  Future<void> _saveEdgeLineMargin(int marginDp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(OverlayConstants.edgeLineMarginPrefKey, marginDp);
    setState(() => _edgeLineMarginDp = marginDp);
    print('🔧 [Settings] overlay_edge_line_margin_dp=$marginDp');
  }

  /// 保存「面板高度」可见条数档位（读取方：overlay engine 的
  /// _refreshOverlayConfig/_scheduleAutoHide + _buildPanel——列表限高
  /// panelListMaxHeightFor + 顶部下压偏移 panelTopOffsetFor；条数越少顶部
  /// 按钮组越下移（每少 1 条下压一张卡高），整列底边位置不变。生效时机
  /// 同把手大小：悬浮窗下一次状态转换）
  Future<void> _savePanelMaxCards(int cards) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(OverlayConstants.panelMaxCardsPrefKey, cards);
    setState(() => _panelMaxCards = cards);
    print('🔧 [Settings] overlay_panel_max_cards=$cards');
  }

  /// 保存「按钮位置」：底部 = 面板改贴停靠侧下角锚定、按钮条挪到列表下方
  ///（单手拇指可达；读取方：overlay engine 的 _refreshOverlayConfig/
  /// _scheduleAutoHide + _buildPanel）。生效时机同面板高度档位——悬浮窗
  /// 下一次状态转换
  Future<void> _savePanelButtonsBottom(bool bottom) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.panelButtonsBottomPrefKey, bottom);
    setState(() => _panelButtonsBottom = bottom);
    print('🔧 [Settings] overlay_panel_buttons_bottom=$bottom');
  }

  /// 保存「截图后展开笔记卡片」开关（读取方：overlay engine 的
  /// _onCardCopyLongPress——动作型开关，截图成功收尾现场 reload 读，即时生效。
  /// 开启后截图成功自动唤出面板并展开该卡，便于核对截图效果或继续编辑）
  Future<void> _saveScreenshotExpandCard(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OverlayConstants.screenshotExpandCardPrefKey, enabled);
    setState(() => _screenshotExpandCard = enabled);
    print('🔧 [Settings] screenshot_expand_card=$enabled');
  }

  /// 保存「语音搜索跳转」开关（读取方：overlay engine 的
  /// OverlayVoiceMemoController._transcribeAndSave——动作型开关，转写收尾时
  /// 现场 reload 读，即时生效无需等状态转换。开启后说完「搜索 xxx」自动拉起
  /// 浏览器搜索关键词，日记照常保存）
  Future<void> _saveVoiceSearchJumpEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kVoiceSearchJumpEnabledKey, enabled);
    setState(() => _voiceSearchJumpEnabled = enabled);
    print('🔧 [Settings] voice_search_jump_enabled=$enabled');
  }

  /// 保存语音搜索触发词（读取方：overlay engine 的
  /// OverlayVoiceMemoController._transcribeAndSave——转写收尾现场 reload 读，
  /// 即时生效）。triggers 已经过 [SearchCommandDetector.normalize] 规范化，
  /// prefs 落盘为换行分隔文本（全量备份同格式，见 settings_tab.dart）
  Future<void> _saveVoiceSearchTriggers(List<String> triggers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kVoiceSearchTriggersKey, triggers.join('\n'));
    if (!mounted) return;
    setState(() => _voiceSearchTriggers = triggers);
    print('🔧 [Settings] voice_search_triggers=${triggers.join('/')}');
  }

  /// 编辑语音搜索触发词：每行一个（也兼容逗号/顿号分隔），保存时 trim、
  /// 去空、去重并按长度降序排列（先长后短，防短触发词截留长触发词后缀）；
  /// 全空拒绝保存并就地报错，保证至少保留一个触发词
  Future<void> _editVoiceSearchTriggers() async {
    if (!await _ensureOverlayPro()) return;
    if (!mounted) return;

    var input = _voiceSearchTriggers.join('\n');
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('语音搜索触发词'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '每行一个触发词（也支持逗号/顿号分隔）。只有说在开头才触发搜索；'
                    '保存时自动去重并按长度从长到短匹配',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppThemeExtension.of(context).textHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: input,
                    minLines: 3,
                    maxLines: 5,
                    onChanged: (v) => input = v,
                    decoration: InputDecoration(
                      hintText: kDefaultVoiceSearchTriggers.join('\n'),
                      errorText: errorText,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final triggers = SearchCommandDetector.normalize(input);
                    if (triggers.isEmpty) {
                      setDialogState(() => errorText = '至少保留一个触发词');
                      return;
                    }
                    Navigator.pop(dialogContext, triggers);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return;
    await _saveVoiceSearchTriggers(result);
  }

  /// 悬浮窗配置的 Pro 门禁：已解锁返回 true 放行；未解锁弹付费弹窗并返回  /// false（调用方不写 prefs）。弹窗关闭后重读解锁状态刷新 Pro 徽章
  /// （原 settings_tab._ensureOverlayPro 语义，改用 ProGate 实现）
  Future<bool> _ensureOverlayPro() async {
    final ok = await ProGate.tryAccess(context);
    if (!ok) {
      _loadProUnlockStatus(); // 弹窗里可能已解锁，刷新徽章显示
      return false;
    }
    return true;
  }

  /// 启动悬浮窗（「立即启动悬浮窗」按钮）：Pro 门禁 → 无障碍服务状态检查
  ///（未开启弹引导对话框，可跳系统设置）→ 通道调原生 showOverlayFromSettings
  Future<void> _launchOverlay() async {
    if (!await _ensureOverlayPro()) return;
    final enabled = await checkAccessibilityServiceEnabled();
    if (!mounted) return;
    if (enabled != true) {
      // null=检测失败 与 false=未开启 都走引导（检测失败大概率也是未开启，
      // 对话框文案不区分，用户到系统页一看便知）
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要先开启无障碍服务'),
          content: const Text('悬浮窗寄生于无障碍服务。请前往系统设置开启「声物记」的无障碍服务，然后再回来启动。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                openAccessibilitySettings();
              },
              child: const Text('去开启'),
            ),
          ],
        ),
      );
      return;
    }
    final ok = await OverlayLauncher.showOverlay();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('启动失败：无障碍服务未运行，请检查是否被系统关闭')));
    }
    // 成功不打 SnackBar——悬浮窗面板已在屏幕上展开，即最佳反馈
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
                  '通过音量键手势召唤悬浮窗（见音量键快捷操作），或点击下方按钮直接启动',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
                const SizedBox(height: 4),
                Text(
                  '收起态把手长按后可上下拖动调整位置；停靠侧可在下方切换屏幕左缘或右缘（滑动方向随侧镜像）',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
                const SizedBox(height: 10),
                // 「立即启动悬浮窗」按钮：不按音量键也能召唤（2026-10-19）。
                // 链路走 _launchOverlay：Pro 门禁 → 无障碍服务检查 → 原生转发
                buildSettingsPrimaryButton(
                  context,
                  icon: Icons.rocket_launch_outlined,
                  label: '立即启动悬浮窗',
                  expand: false,
                  onPressed: _launchOverlay,
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

          const SettingsSectionTitle("字体大小"),
          SettingsCard(child: _buildFontSizeSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("面板高度"),
          SettingsCard(child: _buildPanelHeightSelector()),
          const SizedBox(height: 24),

          const SettingsSectionTitle("按钮位置"),
          SettingsCard(child: _buildPanelButtonsPositionSelector()),
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
                  title: const Text('点按竖线展开把手', style: TextStyle(fontSize: 13)),
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
                const SizedBox(height: 8),
                _buildEdgeLineMarginSelector(),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const SettingsSectionTitle("滑动操作"),
          SettingsCard(
            child: buildSettingsSwitchTile(
              context,
              title: const Text('滑动直接删除笔记', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '开启后活跃卡片朝屏幕内侧滑动直接删除（面板顶部提示 3 秒内可撤销）；归档仍可点卡片顶端圆圈。关闭则维持默认：滑动=归档',
                style: TextStyle(fontSize: 11, color: ext.textHint),
              ),
              value: _swipeDeleteEnabled,
              onChanged: (v) async {
                // 悬浮窗配置同走 Pro 门禁（与其他配置一致），未解锁不写 prefs
                if (!await _ensureOverlayPro()) return;
                _saveSwipeDeleteEnabled(v);
              },
            ),
          ),
          const SizedBox(height: 24),

          const SettingsSectionTitle("截图附件"),
          SettingsCard(
            child: buildSettingsSwitchTile(
              context,
              title: const Text('截图后展开笔记卡片', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                '开启后长按复制按钮截图成功，会重新唤出悬浮窗并展开这张笔记，方便核对截图效果或继续编辑；关闭则只提示「截图已保存为附件」并保持收起',
                style: TextStyle(fontSize: 11, color: ext.textHint),
              ),
              value: _screenshotExpandCard,
              onChanged: (v) async {
                // 悬浮窗配置同走 Pro 门禁（与其他配置一致），未解锁不写 prefs
                if (!await _ensureOverlayPro()) return;
                _saveScreenshotExpandCard(v);
              },
            ),
          ),
          const SizedBox(height: 24),

          const SettingsSectionTitle("语音搜索跳转"),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text(
                    '说完触发词自动搜索',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '语音速记或按住说话转写完成后，内容以触发词开头时自动打开浏览器搜索关键词（日记照常保存）；浏览器与搜索引擎在「大爆炸搜索」里选择',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _voiceSearchJumpEnabled,
                  onChanged: (v) async {
                    // 悬浮窗配置同走 Pro 门禁（与其他配置一致），未解锁不写 prefs
                    if (!await _ensureOverlayPro()) return;
                    _saveVoiceSearchJumpEnabled(v);
                  },
                ),
                Divider(height: 20, color: ext.textHint.withValues(alpha: 0.2)),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '触发词',
                            style: TextStyle(
                              fontSize: 13,
                              color: ext.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _voiceSearchTriggers.join(' / '),
                            style: TextStyle(fontSize: 11, color: ext.textHint),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _editVoiceSearchTriggers,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('编辑', style: TextStyle(fontSize: 12)),
                    ),
                  ],
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
            return buildSettingsChoiceChip(
              context,
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
              onTap: () async {
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

  // --- 悬浮窗「字体大小」五档选择器：特小/小/标准/大/特大，档位值 -2~+2，
  // 每档 1pt（基准即当前字号；档差 0.5pt 真机不可辨、2pt 会让最小档跌破可读
  // 下限，故取 1pt）。只作用日记面板文字；把手（有独立大小档位）与语音速记
  // 胶囊（宽度预算按 15 号字调过）不缩放。生效时机同把手大小——下一次
  // 展开/收起状态转换
  Widget _buildFontSizeSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [(-2, '特小'), (-1, '小'), (0, '标准'), (1, '大'), (2, '特大')];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (step, label) = opt;
            final selected = _fontSizeStep == step;
            return buildSettingsChoiceChip(
              context,
              // Aa 图标大小随档位递减/递增：图标本身暗示字号档位
              icon: Icons.format_size,
              iconSize: 14.0 + step * 2,
              label: Text(label),
              selected: selected,
              onTap: () async {
                // 字体大小属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _saveFontSizeStep(step);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '缩放随手记面板的文字大小（每档 ±1pt，不影响把手与录音胶囊）。改动在悬浮窗下一次展开/收起后生效',
          style: TextStyle(fontSize: 11, color: ext.textHint),
        ),
      ],
    );
  }

  // --- 悬浮窗「按钮位置」两档选择器（2026-10-27，用户要求：按钮切到底部
  // 便于单手操作）：顶部（默认，历史行为）/ 底部。底部模式不只是把按钮条
  // 挪到列表下方——面板整体改为贴停靠侧下角锚定，条目少时按钮也贴着屏幕
  // 底部（只挪按钮、面板仍顶部锚定的话按钮还停在屏幕上方）。生效时机同
  // 面板高度——下一次展开/收起状态转换
  Widget _buildPanelButtonsPositionSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [
      (false, '顶部', Icons.vertical_align_top),
      (true, '底部', Icons.vertical_align_bottom),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (bottom, label, icon) = opt;
            final selected = _panelButtonsBottom == bottom;
            return buildSettingsChoiceChip(
              context,
              icon: icon,
              label: Text(label),
              selected: selected,
              onTap: () async {
                // 按钮位置属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _savePanelButtonsBottom(bottom);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '把新增/展开/打开随手记等按钮条放到面板底部（面板整体贴屏幕下角），'
          '单手拇指更好按。改动在悬浮窗下一次展开/收起后生效',
          style: TextStyle(fontSize: 11, color: ext.textHint),
        ),
      ],
    );
  }

  // --- 悬浮窗「面板高度」可见条数选择器（2026-10-06，用户需求：大屏手机单手
  // 拿时面板顶部的新建/展开按钮够不着）：10 条（默认，历史行为）~6 条五档。
  // 条数越少，面板顶部按钮组随之下移（每少 1 条下压一张卡高），满列表时整列
  // 底边位置不变——单手大拇指可轻松按到顶部按钮。单位用条数（比高/中/低
  // 档位直观）。生效时机同把手大小——下一次展开/收起状态转换
  Widget _buildPanelHeightSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [10, 9, 8, 7, 6];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((cards) {
            final selected = _panelMaxCards == cards;
            return buildSettingsChoiceChip(
              context,
              // 列表图标大小随条数递减：图标本身暗示面板高度档位
              icon: Icons.view_agenda_outlined,
              iconSize: 8.0 + cards,
              label: Text('$cards 条'),
              selected: selected,
              onTap: () async {
                // 面板高度属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _savePanelMaxCards(cards);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '降低面板一次可见的笔记条数；按钮位置为「顶部」时按钮条随之下移、'
          '底部位置不变，单手更好按。改动在悬浮窗下一次展开/收起后生效',
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
    final options = [(100, '标准', 16.0), (75, '小', 12.0), (50, '迷你', 8.0)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (percent, label, dotSize) = opt;
            final selected = _handleSizePercent == percent;
            return buildSettingsChoiceChip(
              context,
              // 圆点大小随档位递减：图标本身暗示所选档位的视觉大小
              icon: Icons.circle,
              iconSize: dotSize,
              label: Text(label),
              selected: selected,
              onTap: () async {
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
        return buildSettingsChoiceChip(
          context,
          icon: icon,
          label: Text(label),
          selected: selected,
          onTap: () async {
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
        return buildSettingsChoiceChip(
          context,
          icon: icon,
          label: Text(label),
          selected: selected,
          onTap: () async {
            // 停靠侧属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
            if (!await _ensureOverlayPro()) return;
            _saveOverlaySide(left);
          },
        );
      }).toList(),
    );
  }

  // --- 竖线「距屏幕边缘间距」三档选择器（2026-09-29，用户反馈：贴带黑边的
  // 钢化膜后贴边竖线可能被遮住）：贴边（0，历史行为）/ 内移（4）/ 最里（8）。
  // 只内移竖线视觉，窗口与触摸缓冲区不动；
  // 生效时机同把手大小——悬浮窗下一次状态转换
  Widget _buildEdgeLineMarginSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [(0, '贴边'), (4, '内移'), (8, '最里')];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('距屏幕边缘间距', style: TextStyle(fontSize: 13, color: ext.textPrimary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (margin, label) = opt;
            final selected = _edgeLineMarginDp == margin;
            return buildSettingsChoiceChip(
              context,
              // 竖条图标离左边框的间距随档位拉宽：图标本身暗示边距档位
              icon: Icons.vertical_align_center,
              iconSize: 12.0 + margin / 2,
              label: Text(label),
              selected: selected,
              onTap: () async {
                // 竖线间距属于悬浮窗配置，同走 Pro 门禁（未解锁不写 prefs）
                if (!await _ensureOverlayPro()) return;
                _saveEdgeLineMargin(margin);
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 6),
        Text(
          '贴了带黑边的钢化膜、竖线被膜边遮住时调大；只移动竖线视觉位置，触控区域不变。改动在悬浮窗下一次展开/收起后生效',
          style: TextStyle(fontSize: 11, color: ext.textHint),
        ),
      ],
    );
  }
}
