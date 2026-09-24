import 'package:flutter/material.dart';

import '../db_helper.dart';
import '../hotword/phoneme_corrector.dart';
import '../text_processor.dart';
import '../theme/app_theme_extension.dart';
import '../utils/correction_learner.dart';

/// 修正对列表排序模式（AppBar 排序菜单；用户排查高频错误用）
enum PairSortMode {
  /// 默认：错误片段长度降序（与替换链路「先长后短」一致），同长按命中次数
  defaultOrder,

  /// 命中次数降序：哪些错误出现得最多
  hitCount,

  /// 最近命中时间降序（last_used_at 优先、空则 created_at；全无时间的老
  /// 数据排最后）
  lastUsed,
}

/// 纯排序比较器（表 ≤500 行，内存排序零压力）。时间串是 ISO 8601，
/// 字典序即时间序，不做 DateTime.parse 免得坏时间串抛异常
int compareCorrectionPairs(
  CorrectionPair a,
  CorrectionPair b,
  PairSortMode mode,
) {
  switch (mode) {
    case PairSortMode.defaultOrder:
      final byLen = b.error.length.compareTo(a.error.length);
      return byLen != 0 ? byLen : b.hitCount.compareTo(a.hitCount);
    case PairSortMode.hitCount:
      final byHit = b.hitCount.compareTo(a.hitCount);
      return byHit != 0 ? byHit : _compareActivityDesc(a, b);
    case PairSortMode.lastUsed:
      final byTime = _compareActivityDesc(a, b);
      return byTime != 0 ? byTime : b.hitCount.compareTo(a.hitCount);
  }
}

/// 活跃时间（最近命中优先、缺则学习时间）降序；两侧都无时间视为同序
int _compareActivityDesc(CorrectionPair a, CorrectionPair b) {
  final at = a.lastUsedAt ?? a.createdAt;
  final bt = b.lastUsedAt ?? b.createdAt;
  if (at == null && bt == null) return 0;
  if (at == null) return 1; // 无时间的老数据/导入排最后
  if (bt == null) return -1;
  return bt.compareTo(at);
}

/// ISO 时间串 → 「MM-dd HH:mm」（跨年补年份）；坏串原样返回不抛
String formatPairTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  final ymd = d.year == DateTime.now().year
      ? '$mm-$dd'
      : '${d.year}-$mm-$dd';
  return '$ymd $hh:$mi';
}

/// 「错误-修正」学习表管理页（设置页 → 智能修正学习 → 修正对管理）。
///
/// 展示从用户编辑行为中学到的片段级修正对，支持：
/// - 查看：每行「错误 → 修正」+ 命中次数 + 最近命中时间
/// - 排序：AppBar 排序菜单——默认（错误片段长在前）/ 命中次数 / 最近命中
///   时间，方便排查哪些错误出现得最多
/// - 删除：单条删除（学错的对可即时清掉）；AppBar 上"清空全部"（带确认）
/// - 升级：命中 ≥3 次的对可「加入热词」（高亮按钮），转成音素热词后
///   发音近似的写法也自动替换；升级不动本条记录（保留学习史）
///
/// 导入导出不在此页：统一走设置页「数据备份与还原」全量备份
/// （ZIP 内 correction_pairs.txt，导入合并语义），避免双入口分叉。
class CorrectionPairsPage extends StatefulWidget {
  const CorrectionPairsPage({super.key, required this.processor});

  /// 写热词必须走主实例：写盘后同步重建其内存词表，识别链路立即生效
  final TextProcessor processor;

  @override
  State<CorrectionPairsPage> createState() => _CorrectionPairsPageState();
}

class _CorrectionPairsPageState extends State<CorrectionPairsPage> {
  List<CorrectionPair> _pairs = [];
  bool _isLoading = true;
  PairSortMode _sortMode = PairSortMode.defaultOrder;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final pairs = await DbHelper().getAllCorrectionPairs();
    if (!mounted) return;
    setState(() {
      _pairs = pairs..sort((a, b) => compareCorrectionPairs(a, b, _sortMode));
      _isLoading = false;
    });
  }

  /// 切排序：纯内存重排（≤500 行），不必回库重查
  void _changeSort(PairSortMode mode) {
    setState(() {
      _sortMode = mode;
      _pairs.sort((a, b) => compareCorrectionPairs(a, b, mode));
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

  /// 加入热词：把「错误 → 修正」转成音素热词条目「正词 | 错词」，
  /// 发音近似的错误写法之后会自动替换（不止字面提示）
  Future<void> _promotePair(CorrectionPair pair) async {
    final added =
        await widget.processor.appendHotwordPair(pair.correct, pair.error);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? '✅ 已加入热词：「${pair.correct} | ${pair.error}」，发音相似也会自动替换'
              : '热词里已有这条，无需重复添加',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: const Text('修正对管理'),
        actions: [
          PopupMenuButton<PairSortMode>(
            tooltip: '排序方式',
            icon: const Icon(Icons.sort),
            onSelected: _changeSort,
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem(
                value: PairSortMode.defaultOrder,
                checked: _sortMode == PairSortMode.defaultOrder,
                child: const Text('默认（错误片段长在前）'),
              ),
              CheckedPopupMenuItem(
                value: PairSortMode.hitCount,
                checked: _sortMode == PairSortMode.hitCount,
                child: const Text('按命中次数（最多在前）'),
              ),
              CheckedPopupMenuItem(
                value: PairSortMode.lastUsed,
                checked: _sortMode == PairSortMode.lastUsed,
                child: const Text('按最近命中时间'),
              ),
            ],
          ),
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
                final timeText = formatPairTime(
                  pair.lastUsedAt ?? pair.createdAt,
                );
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
                    (pair.correct.isEmpty
                            ? '识别出「${pair.error}」时你手动删掉了它 · 命中 ${pair.hitCount} 次'
                            : '识别出「${pair.error}」时你改成了「${pair.correct}」 · 命中 ${pair.hitCount} 次') +
                        (timeText.isEmpty ? '' : ' · $timeText'),
                    style: TextStyle(fontSize: 12, color: ext.textHint),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 升级为音素热词：满 3 次高亮提议，删除型对（无目标词）不给
                      if (pair.correct.isNotEmpty)
                        IconButton(
                          icon: Icon(
                            Icons.library_add_outlined,
                            size: 20,
                            color: pair.hitCount >=
                                    PhonemeHotwordConfig
                                        .promotionHitThreshold
                                ? ext.primary
                                : ext.textHint,
                          ),
                          tooltip: '加入热词（发音近似自动替换）',
                          onPressed: () => _promotePair(pair),
                        ),
                      IconButton(
                        icon: const Icon(Icons.close_outlined, size: 20),
                        tooltip: '删除',
                        onPressed: () => _deletePair(pair),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
