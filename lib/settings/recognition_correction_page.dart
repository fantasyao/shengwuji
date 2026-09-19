import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../correction/correction_config.dart'; // 同音词上下文纠错开关 key
import '../db_helper.dart';
import '../text_processor.dart';
import '../theme/app_theme_extension.dart';
import '../widgets/correction_pairs_page.dart'; // 错误-修正学习表管理页
import 'settings_widgets.dart';

/// 「识别与修正」二级页（zcode: 2026-09 设置页下沉——原主页「动态热词替换」
/// 与「智能修正学习」两个分组合并，主题同属识别结果纠错；prefs key 与
/// TextProcessor / ContextCorrector 读取方全部不变）
class RecognitionCorrectionPage extends StatefulWidget {
  const RecognitionCorrectionPage({
    super.key,
    required this.processor,
    required this.dbHelper,
  });

  final TextProcessor processor;
  final DbHelper dbHelper;

  @override
  State<RecognitionCorrectionPage> createState() =>
      _RecognitionCorrectionPageState();
}

class _RecognitionCorrectionPageState extends State<RecognitionCorrectionPage> {
  final TextEditingController _hotwordController = TextEditingController();
  int _correctionPairCount = 0;

  @override
  void initState() {
    super.initState();
    _loadHotwords();
    _loadCorrectionPairCount();
  }

  @override
  void dispose() {
    _hotwordController.dispose();
    super.dispose();
  }

  Future<void> _loadHotwords() async {
    final text = await widget.processor.getLocalContent();
    if (mounted) setState(() => _hotwordController.text = text);
  }

  Future<void> _loadCorrectionPairCount() async {
    final pairs = await widget.dbHelper.getAllCorrectionPairs();
    if (mounted) setState(() => _correctionPairCount = pairs.length);
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "识别与修正",
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
          const SettingsSectionTitle("动态热词替换"),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                TextField(
                  controller: _hotwordController,
                  maxLines: 5,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: ext.cardBackground,
                    hintText: "错词 = 正词 (每行一个)",
                    hintStyle: TextStyle(color: ext.textHint, fontSize: 13),
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await widget.processor.saveContent(
                        _hotwordController.text,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("✅ 热词已保存生效")),
                        );
                      }
                    },
                    icon: const Icon(Icons.save_rounded, size: 20),
                    label: const Text(
                      "保存并更新热词",
                      style: TextStyle(fontWeight: FontWeight.bold),
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
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const SettingsSectionTitle("智能修正学习"),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _buildCorrectionEntry(),
                const Divider(height: 1, indent: 16, endIndent: 16),
                // 同音词上下文纠错总开关（prefs key 与 ContextCorrector 读的一致）
                // 卡片是 padding.zero（入口行/底部说明自带水平 16），开关行本身无水平
                // 内边距（NeuSwitchTile 只有 vertical），须补 16 与卡内其他块对齐
                FutureBuilder<bool>(
                  future: SharedPreferences.getInstance().then(
                    (prefs) =>
                        prefs.getBool(CorrectionConfig.enabledPrefKey) ?? true,
                  ),
                  builder: (context, snapshot) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: buildSettingsSwitchTile(
                        context,
                        title: const Text(
                          '同音词上下文纠错',
                          style: TextStyle(fontSize: 15),
                        ),
                        subtitle: Text(
                          '识别到「智谱/质朴」「事物/事务」这类同音词时，'
                          '结合上下文自动选择正确的写法；拿不准时保持原文不改',
                          style: TextStyle(fontSize: 12, color: ext.textHint),
                        ),
                        value: snapshot.data ?? true,
                        onChanged: (v) async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool(CorrectionConfig.enabledPrefKey, v);
                          setState(() {});
                        },
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Text(
                    '你在日记或存物品时手动修改识别文字，app 会记住「识别错误 → 你改成的文字」，'
                    '下次识别再出现相同错误时提示一键修正。与上方热词的区别：热词自动替换，'
                    '修正对每次先征求你同意。同音词纠错（如「质朴公司」自动改成「智谱公司」）'
                    '不走这张表，它按上下文判断并只在很有把握时才自动改，你的手动修改会帮它越学越准。',
                    style: TextStyle(
                      fontSize: 12,
                      color: ext.textHint,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「修正对管理」入口（zcode: 从 settings_tab._buildCorrectionEntry 原样搬入，
  /// 视觉改用共享 SettingsEntryRow；返回后刷新条数）
  Widget _buildCorrectionEntry() {
    return SettingsEntryRow(
      icon: Icons.auto_fix_high_outlined,
      title: '修正对管理',
      subtitle: _correctionPairCount > 0
          ? '已学到 $_correctionPairCount 条，点击查看/删除'
          : '暂无学习记录，点击了解详情',
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CorrectionPairsPage()),
        );
        _loadCorrectionPairCount(); // 管理页可能有增删，返回后刷新计数
      },
    );
  }
}

/// 热词条数（主页「识别与修正」入口行摘要用）：非空行数，格式「错词 = 正词」每行一条
int countHotwordLines(String content) {
  return content.split('\n').where((line) => line.trim().isNotEmpty).length;
}
