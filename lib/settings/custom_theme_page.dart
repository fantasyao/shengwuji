import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../theme/app_theme.dart' show AppThemes;
import '../theme/app_theme_extension.dart';
import '../theme/custom_theme.dart';
import 'settings_widgets.dart';

/// 自定义主题编辑页（Pro）
///
/// 交互：选主色 → [generateCustomTheme] 实时生成推荐色系（预览卡即时反映）；
/// 背景色/按钮色/选中背景色三项可各自用选色盘覆盖推荐值（允许反差搭配）。
/// 所有改动只在本页 State——点「使用此主题」才写 prefs + 切
/// [AppRoot.themeNotifier]（主 App 与悬浮窗同时生效），pop(true) 让
/// 主题选择 sheet 关闭；放弃编辑 pop(false) 回到 sheet 继续挑预设。
///
/// 更换主色会清空三项微调（推荐色系随主色重新生成，旧微调基于旧主色已无意义）。
class CustomThemePage extends StatefulWidget {
  const CustomThemePage({super.key});

  @override
  State<CustomThemePage> createState() => _CustomThemePageState();
}

class _CustomThemePageState extends State<CustomThemePage> {
  /// 首次进入的默认主色 = 默认青主色（推荐色系观感与出厂主题衔接）
  static const _fallbackSeedValue = 0xFF009688;

  CustomThemeConfig _config =
      const CustomThemeConfig(seed: _fallbackSeedValue);
  bool _savedBefore = false; // prefs 里是否已有保存的配置（控制"删除自定义主题"显隐）
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await CustomThemeConfig.load();
    if (!mounted) return;
    setState(() {
      _config = saved ?? const CustomThemeConfig(seed: _fallbackSeedValue);
      _savedBefore = saved != null;
      _loaded = true;
    });
  }

  AppThemeExtension get _ext => generateCustomTheme(_config).extension;

  // ==================== 配置编辑 ====================

  void _updateSeed(Color color) {
    // 换主色 = 推荐色系整体重生成，三项微调一并清空（见类注释）
    setState(() {
      _config = CustomThemeConfig(seed: color.toARGB32());
    });
  }

  void _updateOverride({
    int? scaffoldBackground,
    bool clearScaffold = false,
    int? fabReady,
    bool clearFab = false,
    int? selectionBackground,
    bool clearSelection = false,
  }) {
    setState(() {
      _config = _config.copyWith(
        scaffoldBackground: scaffoldBackground,
        clearScaffoldBackground: clearScaffold,
        fabReady: fabReady,
        clearFabReady: clearFab,
        selectionBackground: selectionBackground,
        clearSelectionBackground: clearSelection,
      );
    });
  }

  // ==================== 应用 / 删除 ====================

  Future<void> _applyTheme() async {
    await CustomThemeConfig.save(_config);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_theme', kCustomThemeId);
    AppRoot.themeNotifier.value = generateCustomTheme(_config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已切换到「自定义」主题'),
        backgroundColor: _ext.primary,
      ),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _deleteCustomTheme() async {
    await CustomThemeConfig.clear();
    final prefs = await SharedPreferences.getInstance();
    // 删除时若正在使用自定义主题，回退默认青（与启动门禁回退同一出口）
    if (prefs.getString('selected_theme') == kCustomThemeId) {
      await prefs.setString('selected_theme', AppThemes.defaultTheme.id);
      AppRoot.themeNotifier.value = AppThemes.defaultTheme;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除自定义主题')));
    Navigator.of(context).pop(false);
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    if (!_loaded) {
      return Scaffold(
        backgroundColor: ext.scaffoldBackground,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '自定义主题',
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
          const SettingsSectionTitle('实时预览'),
          _buildPreviewCard(),
          const SizedBox(height: 24),
          const SettingsSectionTitle('主色'),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: _buildColorRow(
              ext: ext,
              label: '选中背景色（主色）',
              subtitle: '改动将重新生成整套推荐色系',
              color: Color(_config.seed),
              badge: null,
              onTap: () => _showColorPicker(
                title: '选择主色',
                initial: Color(_config.seed),
                onChanged: _updateSeed,
              ),
              isSeed: true,
            ),
          ),
          const SizedBox(height: 24),
          SettingsSectionTitle('微调（推荐色系可逐项覆盖）'),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _buildColorRow(
                  ext: ext,
                  label: '背景色',
                  subtitle: '全局页面底色',
                  color: _ext.scaffoldBackground,
                  badge: _config.scaffoldBackground != null ? '已自定义' : '推荐',
                  onTap: () => _showColorPicker(
                    title: '选择背景色',
                    initial: _ext.scaffoldBackground,
                    onChanged: (c) =>
                        _updateOverride(scaffoldBackground: c.toARGB32()),
                  ),
                  onReset: _config.scaffoldBackground != null
                      ? () => _updateOverride(clearScaffold: true)
                      : null,
                ),
                const Divider(height: 1, indent: 16),
                _buildColorRow(
                  ext: ext,
                  label: '按钮色',
                  subtitle: '浮动录音按钮等主按钮底色',
                  color: _ext.fabReady,
                  badge: _config.fabReady != null ? '已自定义' : '推荐',
                  onTap: () => _showColorPicker(
                    title: '选择按钮色',
                    initial: _ext.fabReady,
                    onChanged: (c) => _updateOverride(fabReady: c.toARGB32()),
                  ),
                  onReset: _config.fabReady != null
                      ? () => _updateOverride(clearFab: true)
                      : null,
                ),
                const Divider(height: 1, indent: 16),
                _buildColorRow(
                  ext: ext,
                  label: '选中背景色',
                  subtitle: '筛选/标签等选中态的浅色背景',
                  color: _ext.primaryLight,
                  badge: _config.selectionBackground != null ? '已自定义' : '推荐',
                  onTap: () => _showColorPicker(
                    title: '选择选中背景色',
                    initial: _ext.primaryLight,
                    onChanged: (c) =>
                        _updateOverride(selectionBackground: c.toARGB32()),
                  ),
                  onReset: _config.selectionBackground != null
                      ? () => _updateOverride(clearSelection: true)
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 操作区
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _hasAnyOverride ? _resetAllOverrides : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ext.primary,
                    side: BorderSide(color: ext.primary.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('恢复全部推荐'),
                ),
              ),
              if (_savedBefore) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _deleteCustomTheme,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ext.dangerAccent,
                      side: BorderSide(
                          color: ext.dangerAccent.withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('删除自定义主题'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _applyTheme,
              style: ElevatedButton.styleFrom(
                backgroundColor: _ext.fabReady,
                foregroundColor: _ext.textOnPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.check_rounded),
              label: const Text('使用此主题', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  bool get _hasAnyOverride =>
      _config.scaffoldBackground != null ||
      _config.fabReady != null ||
      _config.selectionBackground != null;

  void _resetAllOverrides() {
    setState(() {
      _config = CustomThemeConfig(seed: _config.seed);
    });
  }

  // ==================== 构建小组件 ====================

  /// 预览卡：用生成色槽画一个 mini 界面（背景 + 卡片 + 文字 + 选中态 + 主按钮），
  /// 所有颜色实时跟随当前配置
  Widget _buildPreviewCard() {
    final e = _ext;
    return Container(
      decoration: BoxDecoration(
        color: e.scaffoldBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: e.divider),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('页面标题',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: e.textPrimary)),
          const SizedBox(height: 12),
          // 一张内容卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: e.cardBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: e.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('卡片内容 · 正文文字',
                    style: TextStyle(fontSize: 14, color: e.textPrimary)),
                const SizedBox(height: 4),
                Text('次要说明文字',
                    style: TextStyle(fontSize: 12, color: e.textSecondary)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    // 选中态 chip（选中背景色 + 主色文字）
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: e.primaryLight,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text('已选中',
                          style: TextStyle(
                              fontSize: 12, color: e.primaryDark)),
                    ),
                    const SizedBox(width: 8),
                    // 未选中 chip
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: e.divider),
                      ),
                      child: Text('未选中',
                          style: TextStyle(
                              fontSize: 12, color: e.textSecondary)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 主按钮（按钮色 + 主色上文字）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: e.fabReady,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic, size: 18, color: e.textOnPrimary),
                const SizedBox(width: 6),
                Text('主按钮',
                    style:
                        TextStyle(fontSize: 14, color: e.textOnPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 颜色行：色块 + 名称/说明 + 徽章（推荐/已自定义）+ 恢复推荐小按钮
  Widget _buildColorRow({
    required AppThemeExtension ext,
    required String label,
    required String subtitle,
    required Color color,
    required String? badge,
    required VoidCallback onTap,
    VoidCallback? onReset,
    bool isSeed = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: ext.divider, width: 1),
              ),
              child: isSeed
                  ? Icon(Icons.colorize, color: ext.textOnPrimary, size: 20)
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 15, color: ext.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: ext.textSecondary)),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: badge == '已自定义'
                      ? ext.primaryLight
                      : ext.scaffoldBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ext.divider),
                ),
                child: Text(badge,
                    style: TextStyle(fontSize: 11, color: ext.primaryDark)),
              ),
            if (onReset != null) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: onReset,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.restart_alt,
                      size: 20, color: ext.textSecondary),
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: ext.textHint, size: 22),
          ],
        ),
      ),
    );
  }

  /// 选色盘 BottomSheet（HSV 色轮 + 明度条 + HEX 输入，实时回调）
  void _showColorPicker({
    required String title,
    required Color initial,
    required ValueChanged<Color> onChanged,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _ext.cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _ColorPickerSheet(
        title: title,
        initial: initial,
        onChanged: onChanged,
      ),
    );
  }
}

/// 选色盘弹层（独立 StatefulWidget：picker 自持颜色状态，
/// 拖动/HEX 输入实时回调 [CustomThemePage] 的 State 刷新预览）
class _ColorPickerSheet extends StatefulWidget {
  const _ColorPickerSheet({
    required this.title,
    required this.initial,
    required this.onChanged,
  });

  final String title;
  final Color initial;
  final ValueChanged<Color> onChanged;

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late Color _color = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final width = MediaQuery.of(context).size.width;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: ext.textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: ext.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            ScrollConfiguration(
              // 色轮外圈拖动会触发页面滚动抢手势（桌面/大屏溢出场景），禁掉
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                child: ColorPicker(
                  pickerColor: _color,
                  onColorChanged: (c) {
                    setState(() => _color = c);
                    widget.onChanged(c);
                  },
                  enableAlpha: false,
                  displayThumbColor: true,
                  hexInputBar: true,
                  labelTypes: const [ColorLabelType.hex],
                  pickerAreaBorderRadius: const BorderRadius.all(Radius.circular(8)),
                  colorPickerWidth: width < 360 ? width - 64 : 300,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('完成',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: ext.primary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
