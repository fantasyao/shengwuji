import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart'; // AppRoot.themeNotifier / fontScaleNotifier 等全局切换
import '../theme/app_font.dart'; // 全局字体选择（霞鹜文楷/系统默认）
import '../theme/app_theme.dart'; // AppThemes / AppThemeDefinition
import '../theme/app_theme_extension.dart';
import '../theme/custom_theme.dart'; // 自定义主题（配置存取 + 色系派生）
import '../utils/icon_pack_switcher.dart';
import '../utils/pro_gate.dart';
import 'custom_theme_page.dart';
import 'settings_widgets.dart';
import 'tag_style_settings_page.dart';

/// 「外观」二级页（2026-10-22）
///
/// 原一级页外观分区的主题/深色模式/图标/字号/字体全部下沉本页；「标签外观」
/// （4 槽位图标与颜色）也从日记智能分区挪到这里，一级页只留一条入口行。
class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() => _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  String _currentIconPackId = 'default';
  double _fontScale = 1.0;
  AppFontChoice _fontChoice = kDefaultAppFontChoice;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadCurrentIconPack();
    _loadFontScale();
    _loadFontChoice();
    _loadThemeMode();
  }

  /// 从原生层查询当前图标包（状态源是系统 ComponentEnabledSetting，不依赖 prefs）
  Future<void> _loadCurrentIconPack() async {
    final packId = await IconPackSwitcher.getCurrentPackId();
    if (mounted) {
      setState(() => _currentIconPackId = packId);
    }
  }

  /// 加载全局字号缩放档位（读取方：AppRoot 的 fontScaleNotifier，启动时 main() 已预读）
  Future<void> _loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _fontScale = prefs.getDouble('font_size_scale') ?? 1.0;
      });
    }
  }

  /// 保存全局字号缩放档位（写 prefs 持久化 + 立即触发整树重建）
  Future<void> _saveFontScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_size_scale', scale);
    AppRoot.fontScaleNotifier.value = scale; // 立即触发整树重建
    setState(() => _fontScale = scale);
  }

  /// 加载全局字体选择（读取方：AppRoot 的 fontChoiceNotifier，启动时 main() 已预读）
  Future<void> _loadFontChoice() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _fontChoice = parseAppFontChoice(prefs.getString(kAppFontPrefKey));
      });
    }
  }

  /// 保存全局字体选择（写 prefs 持久化 + 立即整树重建；悬浮窗下次展开时读取）
  Future<void> _saveFontChoice(AppFontChoice choice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kAppFontPrefKey, choice.id);
    AppRoot.fontChoiceNotifier.value = choice;
    setState(() => _fontChoice = choice);
  }

  /// 加载深色模式档位（读取方：AppRoot 的 themeModeNotifier，启动时 main() 已预读）
  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _themeMode = parseThemeMode(prefs.getString(kThemeModePrefKey));
      });
    }
  }

  /// 保存深色模式档位（写 prefs 持久化 + 立即触发整树重建）
  Future<void> _saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kThemeModePrefKey, mode.name);
    AppRoot.themeModeNotifier.value = mode; // 立即触发整树重建
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '外观',
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
          const SettingsSectionTitle('外观'),
          SettingsCard(
            child: Column(
              children: [
                _buildThemeEntry(),
                const Divider(height: 1),
                _buildDarkModeEntry(),
                const Divider(height: 1),
                _buildIconPackEntry(),
                const Divider(height: 1),
                _buildFontSizeEntry(),
                const Divider(height: 1),
                _buildFontFamilyEntry(),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionTitle('标签'),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.label_outline,
              title: '标签外观',
              subtitle: '自定义 4 个标注的图标与颜色（悬浮窗、随手记、网页端同步）',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TagStyleSettingsPage()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 主题选择 ====================

  /// 主题入口（仿 iOS 设置项风格，ListTile 风格）
  ///
  /// 显示当前主题名 + 调色板图标，点击调起 [_showThemePicker] BottomSheet。
  Widget _buildThemeEntry() {
    final ext = AppThemeExtension.of(context);
    final currentTheme = AppRoot.themeNotifier.value;
    return InkWell(
      onTap: _showThemePicker,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.palette_outlined, color: ext.primary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题',
                    style: TextStyle(fontSize: 15, color: ext.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentTheme.name,
                    style: TextStyle(fontSize: 12, color: ext.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: ext.textHint, size: 22),
          ],
        ),
      ),
    );
  }

  /// 主题选择弹窗（BottomSheet，2×2 网格）
  ///
  /// 遍历 [AppThemes.all] 渲染所有预设主题，每个主题用自己的色槽预览，
  /// 让用户在切换前看到真实视觉效果。Pro 主题未解锁时点击触发 [ProUnlockDialog]。
  /// 网格末尾追加"自定义"卡：有保存的配置则用派生色槽预览，否则显示创建入口。
  Future<void> _showThemePicker() async {
    // 打开前先载自定义配置（决定自定义卡是"预览"还是"创建"样式）
    final customConfig = await CustomThemeConfig.load();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppThemeExtension.of(context).cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // 5 套预设 + 自定义卡共 6 格（3 行），矮屏需可滚动，避免底栏溢出
      builder: (sheetCtx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部拖拽指示条
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppThemeExtension.of(
                    sheetCtx,
                  ).textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题
            Text(
              '选择主题',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppThemeExtension.of(sheetCtx).textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            // 2 列主题网格：5 套预设 + 末尾"自定义"卡（第 3 行）
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: [
                ...AppThemes.all.map((t) => _buildThemeCard(sheetCtx, t)),
                _buildCustomThemeCard(sheetCtx, customConfig),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 单个主题卡片（2 列网格里的一格）
  ///
  /// 卡片背景/文字/边框全部使用 **该主题自己的色槽** [theme.extension]，
  /// 这样用户能直观看到切换后的视觉。当前选中主题加粗边框 + 右下角对勾。
  /// Pro 主题右上角显示金色 Pro 徽章。
  /// [onTap] 缺省走 [_onThemeTap]；自定义主题卡传编辑页入口覆盖。
  Widget _buildThemeCard(
    BuildContext sheetCtx,
    AppThemeDefinition theme, {
    VoidCallback? onTap,
  }) {
    final currentExt = AppThemeExtension.of(sheetCtx); // 弹窗当前主题色槽（用于非预览元素）
    final previewExt = theme.extension; // 被预览主题自己的色槽
    final isCurrent = AppRoot.themeNotifier.value.id == theme.id;

    return GestureDetector(
      onTap: onTap ?? () => _onThemeTap(theme),
      child: Container(
        padding: const EdgeInsets.all(12),
        // 拟物主题预览卡用自己的色槽画双向凸起阴影（不能走 neuRaisedDecoration——
        // 那取的是"当前主题"的阴影槽，在旧主题下打开选择器会拿占位色）
        decoration: previewExt.isNeumorphic
            ? BoxDecoration(
                color: previewExt.scaffoldBackground,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: previewExt.neuShadowDark,
                    offset: const Offset(3, 3),
                    blurRadius: 6,
                  ),
                  BoxShadow(
                    color: previewExt.neuShadowLight,
                    offset: const Offset(-3, -3),
                    blurRadius: 6,
                  ),
                ],
              )
            : BoxDecoration(
                color: previewExt.scaffoldBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent
                      ? previewExt.primary
                      : currentExt.textHint.withValues(alpha: 0.2),
                  width: isCurrent ? 2 : 1,
                ),
              ),
        child: Stack(
          children: [
            // 内容：主题名（顶）+ 4 色点（底）
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  theme.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: previewExt.textPrimary,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    _colorDot(previewExt.primary),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.positiveAccent),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.warningAccent),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.cardBackground, withBorder: true),
                  ],
                ),
              ],
            ),
            // Pro 徽章（右上角金色，仅 Pro 主题显示）
            if (theme.isPro)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: previewExt.goldAccent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Pro',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // 选中对勾（右下角，仅当前主题显示）
            if (isCurrent)
              Positioned(
                bottom: 0,
                right: 0,
                child: Icon(
                  Icons.check_circle,
                  color: previewExt.primary,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 色点辅助组件（主题卡片底部的 4 个预览圆点）
  ///
  /// [withBorder] 用于浅色色点（如 cardBackground=白色），加灰色细边避免在白底卡片上不可见。
  Widget _colorDot(Color color, {bool withBorder = false}) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: withBorder
            ? Border.all(color: Colors.grey.shade400, width: 0.5)
            : null,
      ),
    );
  }

  /// 自定义主题卡片（主题网格末尾，第 7 格）
  ///
  /// 有保存的配置 → 复用 [_buildThemeCard] 用派生色槽预览（isPro=true 自动带
  /// 金色徽章）；无配置 → 虚线边框"+ 创建自定义主题"入口样式。
  /// 点击不直接切主题（应用动作统一在编辑页"使用此主题"完成，避免点击语义
  /// 二义），先过 Pro 门禁再进编辑页；编辑页 pop(true)=已应用才关 sheet。
  Widget _buildCustomThemeCard(
    BuildContext sheetCtx,
    CustomThemeConfig? config,
  ) {
    if (config != null) {
      final customTheme = generateCustomTheme(config);
      return _buildThemeCard(
        sheetCtx,
        customTheme,
        onTap: () => _onCustomThemeTap(),
      );
    }
    final currentExt = AppThemeExtension.of(sheetCtx);
    final isCurrent = AppRoot.themeNotifier.value.id == kCustomThemeId;
    return GestureDetector(
      onTap: () => _onCustomThemeTap(),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: currentExt.cardBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent ? currentExt.primary : currentExt.divider,
            width: isCurrent ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, color: currentExt.primary, size: 30),
            const SizedBox(height: 8),
            Text(
              '创建自定义主题',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: currentExt.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Pro · 选色盘搭配',
              style: TextStyle(fontSize: 11, color: currentExt.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// 自定义主题卡点击：Pro 门禁（与 [_onThemeTap] 同链路，未解锁弹解锁引导
  /// 并留在 sheet）→ 进编辑页；pop(true)=已应用主题 → 关 sheet，否则留下
  /// 继续挑预设
  Future<void> _onCustomThemeTap() async {
    final active = await ProGate.tryAccess(context);
    if (!active) return;
    if (!mounted) return;
    final applied = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CustomThemePage()),
    );
    if (applied == true && mounted) {
      Navigator.of(context).pop(); // 关闭主题选择 sheet
    }
  }

  /// 主题点击逻辑：Pro 门禁 + 写 prefs + 切 notifier
  ///
  /// 流程：
  /// 1. Pro 门禁：Pro 主题不可用 → 弹 ProUnlockDialog（试用/输码成功返回 true
  ///    继续应用主题；弹窗盖在主题选择 sheet 之上，不再强关 sheet，未解锁时
  ///    用户可留在选择器改选免费主题）
  /// 2. 正常切换：写 SharedPreferences('selected_theme') → 更新 [AppRoot.themeNotifier]
  ///    → 关闭弹窗 → SnackBar 提示
  Future<void> _onThemeTap(AppThemeDefinition theme) async {
    // Pro 门禁：不可用时弹解锁引导（内部含 7 天试用 / 授权码输入出口）
    if (theme.isPro) {
      final active = await ProGate.tryAccess(context);
      if (!active) return;
    }

    // 写入 prefs + 更新 notifier（触发整树重建）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_theme', theme.id);
    AppRoot.themeNotifier.value = theme;

    if (mounted) {
      Navigator.of(context).pop(); // 关闭主题弹窗
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已切换到「${theme.name}」主题'),
          backgroundColor: theme.extension.primary,
        ),
      );
    }
  }

  // ==================== 图标包选择 ====================

  /// 图标包入口（ListTile 风格，仿 _buildThemeEntry）
  Widget _buildIconPackEntry() {
    final ext = AppThemeExtension.of(context);
    final currentPack =
        IconPacks.findById(_currentIconPackId) ?? IconPacks.defaultPack;
    return InkWell(
      onTap: _showIconPackPicker,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.app_shortcut_outlined, color: ext.primary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '图标',
                    style: TextStyle(fontSize: 15, color: ext.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentPack.name,
                    style: TextStyle(fontSize: 12, color: ext.textSecondary),
                  ),
                ],
              ),
            ),
            // 圆形预览：背景色 + 前景色 mic 图标
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(currentPack.backgroundColor),
                shape: BoxShape.circle,
                // minimal 浅色背景加细边框，避免在白底卡片上不可见
                border: currentPack.id == 'minimal'
                    ? Border.all(
                        color: ext.textHint.withValues(alpha: 0.3),
                        width: 0.5,
                      )
                    : null,
              ),
              child: Image.asset(
                'assets/icon/icon2_fg_white.png',
                width: 14,
                height: 14,
                color: Color(currentPack.foregroundColor),
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: ext.textHint, size: 22),
          ],
        ),
      ),
    );
  }

  /// 字号缩放入口（两行：标题行 + 档位 chips 行）
  ///
  /// 曾试过标题与 chips 挤同行的单行方案：App 内「特大」档 1.3 倍整树缩放
  /// （再叠加系统字体放大）会把行宽撑爆，「特大」chip 溢出卡片边——真机两轮
  /// 截图确诊，2026-09 用户拍板换行展示。相对最初版本仍保留瘦身：chips 无
  /// 重复 format_size 图标、无选中勾（showCheckmark）、档位名「标准→中」、
  /// labelPadding 收窄 8；选中态由 chip 实心底色表达，不再需要「当前档位」副标题。
  Widget _buildFontSizeEntry() {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.format_size, color: ext.primary, size: 22),
              const SizedBox(width: 14),
              Text(
                '字号',
                style: TextStyle(fontSize: 15, color: ext.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildFontSizeSelector(),
        ],
      ),
    );
  }

  /// 字号缩放档位选择器（无图标 chips 行；拟物主题走共享拟物胶囊）
  ///
  /// 瘦身三件套与单行失败的教训详见 _buildFontSizeEntry 注释。
  Widget _buildFontSizeSelector() {
    final options = [(0.85, '小'), (1.0, '中'), (1.15, '大'), (1.3, '特大')];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (scale, label) = opt;
        final selected = _fontScale == scale;
        return buildSettingsChoiceChip(
          context,
          label: Text(label),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          showCheckmark: false,
          selected: selected,
          onTap: () => _saveFontScale(scale),
        );
      }).toList(),
    );
  }

  /// 字体选择入口（两行：标题行 + 字体 chips 行）
  ///
  /// 霞鹜文楷与整体观感不搭时用户可切系统默认档；标签本身
  /// 用各自字体渲染，切换前能直接看到字形差异。
  Widget _buildFontFamilyEntry() {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_format, color: ext.primary, size: 22),
              const SizedBox(width: 14),
              Text(
                '字体',
                style: TextStyle(fontSize: 15, color: ext.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildFontFamilySelector(),
          const SizedBox(height: 6),
          Text(
            '系统默认为 Android 平台字体，不跟随手机自定义字体。',
            style: TextStyle(fontSize: 11, color: ext.textHint),
          ),
        ],
      ),
    );
  }

  /// 字体选择 chips（两个档位；label 使用对应字体预览）
  ///
  /// 拟物主题走共享拟物胶囊（选中凹陷 + 品牌青字），label 自带 fontFamily
  /// 以便切换前直接对比字形。
  Widget _buildFontFamilySelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: AppFontChoice.values.map((choice) {
        final selected = _fontChoice == choice;
        return buildSettingsChoiceChip(
          context,
          label: Text(
            choice.label,
            style: TextStyle(fontFamily: choice.fontFamily),
          ),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          showCheckmark: false,
          selected: selected,
          onTap: () => _saveFontChoice(choice),
        );
      }).toList(),
    );
  }

  /// 深色模式入口（两行：标题行 + 三档 chips 行，与 _buildFontSizeEntry 同款
  /// 布局——单行方案已被字号「特大」档撑爆教训否决，见 _buildFontSizeEntry 注释）
  Widget _buildDarkModeEntry() {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dark_mode_outlined, color: ext.primary, size: 22),
              const SizedBox(width: 14),
              Text(
                '深色模式',
                style: TextStyle(fontSize: 15, color: ext.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildDarkModeSelector(),
        ],
      ),
    );
  }

  /// 深色模式三档选择器（跟随系统/浅色/深色；拟物主题走共享拟物胶囊）
  Widget _buildDarkModeSelector() {
    final options = [
      (ThemeMode.system, '跟随系统'),
      (ThemeMode.light, '浅色'),
      (ThemeMode.dark, '深色'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (mode, label) = opt;
        final selected = _themeMode == mode;
        return buildSettingsChoiceChip(
          context,
          label: Text(label),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          showCheckmark: false,
          selected: selected,
          onTap: () => _saveThemeMode(mode),
        );
      }).toList(),
    );
  }

  /// 图标包选择弹窗（BottomSheet，2×2 网格，仿 _showThemePicker）
  void _showIconPackPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppThemeExtension.of(context).cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 拖拽指示条
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppThemeExtension.of(
                    sheetCtx,
                  ).textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题
            Text(
              '选择图标',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppThemeExtension.of(sheetCtx).textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            // 切换提示（关键：告知用户应用会短暂重启）
            Text(
              '切换后应用会短暂重启',
              style: TextStyle(
                fontSize: 12,
                color: AppThemeExtension.of(sheetCtx).textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            // 2×2 图标网格
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: IconPacks.all
                  .map((p) => _buildIconPackCard(sheetCtx, p))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个图标包卡片（2×2 网格里的一格，仿 _buildThemeCard）
  Widget _buildIconPackCard(BuildContext sheetCtx, IconPack pack) {
    final currentExt = AppThemeExtension.of(sheetCtx);
    final isCurrent = _currentIconPackId == pack.id;

    return GestureDetector(
      onTap: () => _onIconPackTap(pack),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: currentExt.scaffoldBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent
                ? currentExt.primary
                : currentExt.textHint.withValues(alpha: 0.2),
            width: isCurrent ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            // 内容：图标包名（顶）+ 圆形预览（底）
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pack.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: currentExt.textPrimary,
                  ),
                ),
                const Spacer(),
                Center(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Color(pack.backgroundColor),
                      shape: BoxShape.circle,
                      // minimal 浅色背景加细边框，避免在白底卡片上不可见
                      border: pack.id == 'minimal'
                          ? Border.all(
                              color: currentExt.textHint.withValues(alpha: 0.3),
                              width: 0.5,
                            )
                          : null,
                    ),
                    child: Image.asset(
                      'assets/icon/icon2_fg_white.png',
                      width: 26,
                      height: 26,
                      color: Color(pack.foregroundColor),
                      colorBlendMode: BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
            // Pro 徽章（右上角金色，仅 Pro 图标包显示）
            if (pack.isPro)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: currentExt.goldAccent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Pro',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // 选中对勾（右下角，仅当前图标包显示）
            if (isCurrent)
              Positioned(
                bottom: 0,
                right: 0,
                child: Icon(
                  Icons.check_circle,
                  color: currentExt.primary,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图标包点击逻辑：Pro 门禁 + 调原生切换 + 延迟关闭弹窗
  ///
  /// 流程：
  /// 1. 当前已选中的，点一下不做事
  /// 2. Pro 门禁：Pro 图标包不可用 → 弹 ProUnlockDialog（试用/输码成功返回 true
  ///    继续切换；弹窗盖在选择弹窗之上，不强关）
  /// 3. 正常切换：写 prefs('selected_icon_pack') → 调 IconPackSwitcher.switchTo
  ///    → 显示"正在切换..." → 延迟 3 秒关闭弹窗（进程可能已被系统杀死）
  Future<void> _onIconPackTap(IconPack pack) async {
    // 当前已选中，不切换
    if (_currentIconPackId == pack.id) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // Pro 门禁：不可用时弹解锁引导（内部含 7 天试用 / 授权码输入出口）
    if (pack.isPro) {
      final active = await ProGate.tryAccess(context);
      if (!active) return;
    }

    // 写 prefs（仅用于 UI 显示当前选中，真正的状态源是系统 ComponentEnabledSetting）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_icon_pack', pack.id);

    // 调原生层切换
    final success = await IconPackSwitcher.switchTo(pack.id);

    if (!mounted) return; // 进程可能已被系统杀死

    if (success) {
      setState(() => _currentIconPackId = pack.id);

      // 显示"正在切换" SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text('正在切换到「${pack.name}」图标...'),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // 延迟关闭弹窗（进程可能在此之前已被系统杀死）
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        Navigator.of(context).pop();
      }
    } else {
      // 切换失败
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('图标切换失败，请重试'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
