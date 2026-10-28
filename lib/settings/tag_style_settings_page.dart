import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme_extension.dart';
import '../utils/diary_tag.dart';
import 'settings_widgets.dart';

/// 「标签外观」二级页（2026-10-22）
///
/// 4 个固定槽位（tag id 不变，CSV/云同步/旧数据零迁移）只允许换图标与颜色：
/// 点槽位 → 底部弹层选 24 个精选图标 + 10 个颜色。保存走 [DiaryTagStyles]，
/// 主 App 日记页立即重绘；悬浮窗独立 engine 在下次展开前重读；电脑访问网页
/// 每次拉列表时读同一份 prefs。配置随全量备份 ZIP（tag_config.json）迁移
class TagStyleSettingsPage extends StatefulWidget {
  const TagStyleSettingsPage({super.key});

  @override
  State<TagStyleSettingsPage> createState() => _TagStyleSettingsPageState();
}

class _TagStyleSettingsPageState extends State<TagStyleSettingsPage> {
  DiaryTagStyleConfig _config = DiaryTagStyles.config;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await DiaryTagStyles.load();
    if (mounted) setState(() => _config = config);
  }

  Future<void> _apply(DiaryTagStyleConfig next) async {
    setState(() => _config = next);
    await DiaryTagStyles.save(next);
  }

  Future<void> _editSlot(int index) async {
    final tag = DiaryTag.tagIds[index];
    final result = await showModalBottomSheet<DiaryTagStyle>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TagStylePickerSheet(
        tag: tag,
        slotIndex: index,
        initial: _config.styleOf(tag),
      ),
    );
    if (result == null || !mounted) return;
    await _apply(_config.replace(result));
  }

  Future<void> _resetDefaults() async {
    await _apply(DiaryTagStyleConfig.defaults);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已恢复默认标签外观')));
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final styles = _config.styles;
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '标签外观',
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
                    Icon(Icons.label_outline, color: ext.primary, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '4 个标注槽位',
                      style: TextStyle(color: ext.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '只改图标和颜色，不提供改名：标注数据用固定槽位保存，改外观不会影响已有笔记、备份和云同步',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
                const SizedBox(height: 4),
                Text(
                  '悬浮窗、随手记筛选和电脑访问网页同步生效；配置随全量备份导出',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const SettingsSectionTitle('槽位'),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < styles.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: ext.divider),
                  _buildSlotRow(ext, i, styles[i]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: _resetDefaults,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('恢复默认'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlotRow(AppThemeExtension ext, int index, DiaryTagStyle style) {
    return InkWell(
      onTap: () => _editSlot(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: style.color,
              ),
              child: Icon(style.icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '标签 ${index + 1}',
                    style: TextStyle(fontSize: 15, color: ext.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '点击更换图标与颜色',
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
}

/// 单个槽位的图标/颜色选择弹层（取消返回 null，完成返回新 [DiaryTagStyle]）
class _TagStylePickerSheet extends StatefulWidget {
  const _TagStylePickerSheet({
    required this.tag,
    required this.slotIndex,
    required this.initial,
  });

  final String tag;
  final int slotIndex;
  final DiaryTagStyle initial;

  @override
  State<_TagStylePickerSheet> createState() => _TagStylePickerSheetState();
}

class _TagStylePickerSheetState extends State<_TagStylePickerSheet> {
  late String _iconId;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _iconId = widget.initial.iconId;
    _color = widget.initial.color;
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 实时预览：与悬浮窗卡片上的选中态一致（白底圆 + 标注色图标）
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _color,
                      ),
                      child: Icon(
                        DiaryTagIcons.iconOf(_iconId),
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '标签 ${widget.slotIndex + 1}',
                      style: TextStyle(fontSize: 14, color: ext.textPrimary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '图标',
                style: TextStyle(
                  fontSize: 13,
                  color: ext.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final choice in kTagIconChoices)
                    _buildIconTile(ext, choice),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '颜色',
                style: TextStyle(
                  fontSize: 13,
                  color: ext.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final color in kTagColorChoices)
                    _buildColorDot(ext, color),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      final fallback = kDefaultTagStyle(widget.tag);
                      setState(() {
                        _iconId = fallback.iconId;
                        _color = fallback.color;
                      });
                    },
                    child: const Text('此槽位恢复默认'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      DiaryTagStyle(
                        tag: widget.tag,
                        iconId: _iconId,
                        color: _color,
                      ),
                    ),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIconTile(AppThemeExtension ext, DiaryTagIcon choice) {
    final selected = choice.id == _iconId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _iconId = choice.id),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? _color.withValues(alpha: 0.16) : Colors.transparent,
          border: Border.all(
            color: selected ? _color : ext.divider,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Icon(
          choice.icon,
          size: 22,
          color: selected ? _color : ext.textSecondary,
        ),
      ),
    );
  }

  Widget _buildColorDot(AppThemeExtension ext, Color color) {
    final selected = color == _color;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _color = color),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? ext.textPrimary : Colors.transparent,
            width: 2.4,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 20, color: Colors.white)
            : null,
      ),
    );
  }
}
