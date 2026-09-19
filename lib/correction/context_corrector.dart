import 'dart:io' show Directory, File;

import 'package:dart_jieba/dart_jieba.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import '../app_logger.dart';
import '../db_helper.dart';
import '../utils/correction_learner.dart';
import 'context_learner.dart';
import 'context_scorer.dart';
import 'correction_config.dart';
import 'domain_dictionary.dart';
import 'homophone_dictionary.dart';
import 'pair_context.dart';

/// 一次自动替换的明细（坐标为替换前原文的区间）
class AppliedCorrection {
  final String from;
  final String to;
  final int start;
  final int end;

  const AppliedCorrection({
    required this.from,
    required this.to,
    required this.start,
    required this.end,
  });

  @override
  String toString() => '「$from」→「$to」';
}

/// 纠错结果：替换后的文本 + 替换明细（空 applied = 未改动）
class CorrectionResult {
  final String text;
  final List<AppliedCorrection> applied;

  const CorrectionResult(this.text, this.applied);

  bool get changed => applied.isNotEmpty;
}

/// 纠错依赖集（注入便于测试：测试传内存数据，不碰 rootBundle/DB/prefs）
class CorrectionDeps {
  final HomophoneDictionary homophones;
  final DomainDictionary domain;
  final Map<String, Map<String, int>> coStats;
  final Map<String, int> userFreq;

  const CorrectionDeps({
    required this.homophones,
    required this.domain,
    this.coStats = const {},
    this.userFreq = const {},
  });
}

/// 同音词上下文纠错编排器（方案§16 的 correct() 内部流程）。
///
/// 核心原则（方案§21）：词库提供候选，不决定答案；上下文决定答案；
/// 用户历史只提供弱先验；低置信度不修改。
///
/// 五条转写链路（日记/录入/搬家模式/悬浮窗速记/语音搜索）在
/// TextProcessor 热词纠错之后调用 [correct]；编辑学习点调用 [learnFromEdit]。
class ContextCorrector {
  ContextCorrector._();

  static final ContextCorrector instance = ContextCorrector._();

  HomophoneDictionary? _homophones;
  DomainDictionary? _domain;
  Map<String, Map<String, int>> _coStats = {};
  Map<String, int> _userFreq = {};
  Future<void>? _loading;

  bool get isLoaded => _homophones != null && _domain != null;

  /// 预载词库与统计（幂等；首次调用真正加载）。词库加载失败 → 纠错整体
  /// 静默停用（correct 永远原样返回），统计失败 → 仅用静态词表
  Future<void> ensureLoaded() {
    if (isLoaded) return Future.value();
    // 失败时清掉 _loading，下次调用可重试
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      _homophones = HomophoneDictionary.fromJsonString(
        await rootBundle.loadString('assets/homophones.json'),
      );
      _domain = DomainDictionary.fromJsonString(
        await rootBundle.loadString('assets/domain_words.json'),
      );
    } catch (e) {
      log('[ContextCorrector] 词库加载失败，上下文纠错停用: $e');
    }
    try {
      _coStats = await DbHelper().getAllCorrectionContextStats();
      _userFreq = await DbHelper().getAllUserWords();
    } catch (e) {
      log('[ContextCorrector] 共现统计加载失败（仅用静态词表）: $e');
    }
    await _loadSegmenter();
  }

  /// jieba 分词器（修正对学习取词用）：词典 asset 先拷到数据库目录再初始化——
  /// dart_jieba 用 dart:io File 读词典，APK 内 asset 不是文件系统路径。
  /// 任何失败静默保持 wordSegmenter = null，取词回退固定吸收逻辑
  Future<void> _loadSegmenter() async {
    if (CorrectionLearner.wordSegmenter != null) return;
    try {
      String baseDir;
      try {
        baseDir = await getDatabasesPath();
      } catch (_) {
        // 测试环境无 sqflite 平台通道：落到系统临时目录
        baseDir = Directory.systemTemp.path;
      }
      final dictFile = File('$baseDir/jieba_dict.dgz');
      if (!dictFile.existsSync()) {
        final bytes = await rootBundle.load('assets/jieba_dict.dgz');
        await dictFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
      final seg = await JiebaSegmenter.load(dictPath: dictFile.path);
      CorrectionLearner.wordSegmenter = (text) => seg.cut(text);
      log('[ContextCorrector] jieba 分词器已就绪（取词补全到完整词）');
    } catch (e) {
      log('[ContextCorrector] jieba 初始化失败，取词回退固定吸收: $e');
    }
  }

  /// 纠错对是否属于同一同音组（提示制修正对的分流守卫）：
  /// 同音组内的对不进 SnackBar 提示，只由上下文模块处理，
  /// 防止盲替换表与上下文纠错互相打架。词库未加载时返回 false（照旧提示）
  bool isHomophonePair(CorrectionPair pair) {
    final h = _homophones;
    return h != null &&
        pair.correct.isNotEmpty &&
        h.isSameGroup(pair.error, pair.correct);
  }

  /// 识别文本的上下文纠错入口。只动同音组命中的位置，且必须同时过
  /// [CorrectionConfig.minScore] 与 [minMargin] 两道阈值；其余文本
  /// 原样返回（方案§14：无歧义不处理，CPU 消耗可忽略）
  Future<CorrectionResult> correct(String text) async {
    if (text.isEmpty) return CorrectionResult(text, const []);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(CorrectionConfig.enabledPrefKey) ?? true)) {
        return CorrectionResult(text, const []);
      }
    } catch (_) {
      // prefs 不可用时按默认开启处理
    }
    await ensureLoaded();
    final h = _homophones;
    final d = _domain;
    if (h == null || d == null) return CorrectionResult(text, const []);
    final result = correctWith(
      text,
      CorrectionDeps(
        homophones: h,
        domain: d,
        coStats: _coStats,
        userFreq: _userFreq,
      ),
    );
    // 自动纠错的结果绝不回流成训练数据（方案§18：防错误反馈循环）
    if (result.changed) {
      log('[ContextCorrector] 上下文纠错: ${result.applied.join('、')}');
    }
    return result;
  }

  /// 纯函数核心（无 IO，可直测）：逐命中位置评分 → 过阈值才替换
  static CorrectionResult correctWith(String text, CorrectionDeps deps) {
    if (text.isEmpty) return CorrectionResult(text, const []);
    final matches = deps.homophones.findMatches(text);
    if (matches.isEmpty) return CorrectionResult(text, const []);

    final buffer = StringBuffer();
    final applied = <AppliedCorrection>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start < cursor) continue; // 重叠保险（findMatches 已去重）
      final scores = ContextScorer.score(
        text: text,
        matchStart: m.start,
        matchEnd: m.end,
        candidates: m.candidates,
        domain: deps.domain,
        coStats: deps.coStats,
        userFreq: deps.userFreq,
        homophones: deps.homophones,
      );
      if (scores.isEmpty) continue;
      final sorted = [...scores]..sort((a, b) => b.score.compareTo(a.score));
      final top = sorted.first;
      final runnerUp = sorted.length > 1 ? sorted[1].score : 0.0;
      final margin = top.score - runnerUp;
      final original = text.substring(m.start, m.end);
      final winnerIsOriginal =
          top.word.toLowerCase() == original.toLowerCase();
      if (!winnerIsOriginal &&
          top.score >= CorrectionConfig.minScore &&
          margin >= CorrectionConfig.minMargin) {
        buffer.write(text.substring(cursor, m.start));
        buffer.write(top.word);
        cursor = m.end;
        applied.add(
          AppliedCorrection(
            from: original,
            to: top.word,
            start: m.start,
            end: m.end,
          ),
        );
        log(
          '[ContextCorrector] 「$original」→「${top.word}」'
          '(${top.score.toStringAsFixed(1)} vs 次高${runnerUp.toStringAsFixed(1)})'
          ' 依据: ${top.reasons.join(' ')}',
        );
      }
      // 不过阈值：不写 buffer、不动 cursor——原区间留给后续写入，
      // 原文原样保留（宁漏勿错，方案§13）
    }
    buffer.write(text.substring(cursor));
    return CorrectionResult(buffer.toString(), applied);
  }

  /// 编辑学习分流入口（方案§11/§18：只学用户明确的修改行为）。
  /// 三个编辑保存点 + 两处一键修正采纳共用；fire-and-forget，内部自吞异常。
  /// 同音组对 → 共现统计+词频（并在内存热更新，下一次 correct 立即受益）；
  /// 普通对 → correction_pairs（照旧），并顺带记语境档案
  /// （PairContextGate.extract，供提示前语境门控用）
  Future<void> learnFromEdit(String original, String edited) async {
    if (original.isEmpty || edited.isEmpty || original == edited) return;
    try {
      await ensureLoaded();
      final h = _homophones;
      final d = _domain;
      if (h == null || d == null) {
        // 词库不可用：退回旧行为，全部进修正对表
        final all = CorrectionLearner.extractAll(original, edited);
        final pairs = [...all.primary, ...all.shortCore];
        if (pairs.isNotEmpty) {
          await DbHelper().learnCorrectionPairs(pairs);
          await _learnPairContexts(original, pairs);
        }
        return;
      }
      final outcome = ContextLearner.split(
        original,
        edited,
        homophones: h,
        domain: d,
        extraVocabulary: {
          for (final ctx in _coStats.values) ...ctx.keys,
        },
      );
      if (outcome.regularPairs.isNotEmpty) {
        await DbHelper().learnCorrectionPairs(outcome.regularPairs);
        await _learnPairContexts(original, outcome.regularPairs);
      }
      if (outcome.statBumps.isNotEmpty || outcome.userWordBumps.isNotEmpty) {
        await DbHelper().applyContextLearning(
          outcome.statBumps,
          outcome.userWordBumps,
        );
        for (final b in outcome.statBumps) {
          final src = b.source.toLowerCase();
          final row = _coStats[src] ??= {};
          row[b.context] = (row[b.context] ?? 0) + b.delta;
        }
        for (final w in outcome.userWordBumps) {
          final key = w.toLowerCase();
          _userFreq[key] = (_userFreq[key] ?? 0) + 1;
        }
        log(
          '[ContextCorrector] 编辑学习: 同音词共现 +${outcome.statBumps.length} 条'
          '（${outcome.statBumps.take(3).join('、')}）'
          ' 词频 ${outcome.userWordBumps.toSet().join('、')}',
        );
      }
      if (outcome.regularPairs.isNotEmpty) {
        log('学习修正对 ${outcome.regularPairs.length} 条: '
            '${outcome.regularPairs.join('、')}');
      }
    } catch (e) {
      log('[ContextCorrector] 编辑学习失败: $e');
    }
  }

  /// 普通修正对入库时顺带记语境档案（错误片段在识别原文中各出现位置的
  /// 左右邻接字符）。档案供提示点做语境门控；学不到档案的对（裸片段等）
  /// 照旧字面提示
  Future<void> _learnPairContexts(
    String original,
    List<CorrectionPair> pairs,
  ) async {
    final records = PairContextGate.extract(original, pairs);
    if (records.isEmpty) return;
    await DbHelper().learnPairContexts(records);
  }
}
