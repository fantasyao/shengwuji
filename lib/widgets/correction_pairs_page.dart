import 'package:flutter/material.dart';

import '../db_helper.dart';
import '../theme/app_theme_extension.dart';
import '../utils/correction_learner.dart';

/// 「错误-修正」学习表管理页（设置页 → 智能修正学习 → 修正对管理）。
///
/// 展示从用户编辑行为中学到的片段级修正对，支持：
/// - 查看：每行「错误 → 修正」+ 命中次数
/// - 删除：单条删除（学错的对可即时清掉）；AppBar 上"清空全部"（带确认）
///
/// 导入导出不在此页：统一走设置页「数据备份与还原」全量备份
/// （ZIP 内 correction_pairs.txt，导入合并语义），避免双入口分叉。
class CorrectionPairsPage extends StatefulWidget {
  const CorrectionPairsPage({super.key});

  @override
  State<CorrectionPairsPage> createState() => _CorrectionPairsPageState();
}

class _CorrectionPairsPageState extends State<CorrectionPairsPage> {
  List<CorrectionPair> _pairs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final pairs = await DbHelper().getAllCorrectionPairs();
    if (!mounted) return;
    setState(() {
      _pairs = pairs;
      _isLoading = false;
    });
  }

  /// 单条删除：学错的对即时清掉，不弹确认（删除是可预期的低风险操作，
  /// 下次编辑保存会重新学到）
  Future<void> _deletePair(CorrectionPair pair) async {
    await DbHelper().deleteCorrectionPair(pair.error, pair.correct);
    await _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('🗑️ 已删除「${pair.error}」的修正')));
    }
  }

  /// 清空全部：带确认弹窗（不可恢复的批量操作）
  Future<void> _clearAll() async {
    if (_pairs.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部修正对？'),
        content: Text('将删除全部 ${_pairs.length} 条学到的修正，删除后不再弹一键修正提示。此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DbHelper().clearAllCorrectionPairs();
    await _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ 已清空全部修正对')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: const Text('修正对管理'),
        actions: [
          IconButton(
            tooltip: '清空全部',
            onPressed: _pairs.isEmpty ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _pairs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lightbulb_outline,
                    size: 56,
                    color: ext.textHint.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有学到修正对',
                    style: TextStyle(fontSize: 16, color: ext.textHint),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      '当识别结果有误、你手动修改后保存时，\napp 会自动记住「错误 → 修正」，'
                      '下次遇到相同错误会提示一键修正',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: ext.textHint.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              itemCount: _pairs.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: ext.textHint.withValues(alpha: 0.15),
              ),
              itemBuilder: (context, index) {
                final pair = _pairs[index];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    pair.correct.isEmpty
                        ? Icons.delete_outline
                        : Icons.edit_note_outlined,
                    color: ext.textHint,
                  ),
                  title: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '「${pair.error}」',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const TextSpan(
                          text: ' → ',
                          style: TextStyle(
                            color: Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: pair.correct.isEmpty
                              ? '（删除）'
                              : '「${pair.correct}」',
                          style: TextStyle(
                            color: ext.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  subtitle: Text(
                    pair.correct.isEmpty
                        ? '识别出「${pair.error}」时你手动删掉了它 · 命中 ${pair.hitCount} 次'
                        : '识别出「${pair.error}」时你改成了「${pair.correct}」 · 命中 ${pair.hitCount} 次',
                    style: TextStyle(fontSize: 12, color: ext.textHint),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close_outlined, size: 20),
                    tooltip: '删除',
                    onPressed: () => _deletePair(pair),
                  ),
                );
              },
            ),
    );
  }
}
