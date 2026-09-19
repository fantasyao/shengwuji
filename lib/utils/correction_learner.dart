import 'dart:math';
import 'dart:typed_data';

/// 「错误-修正」对：用户手动修改识别文本时学到的片段级替换规则。
///
/// 例：识别「饰品日志-」被用户改成「视频日志」保存 → 学到 (error=饰品, correct=视频)。
/// 下次识别结果再出现「饰品」时，可提示用户一键修正（提示制、非静默替换，
/// 与 TextProcessor 热词的自动替换互补：热词=用户主动配置的确定性规则，
/// 本表=从编辑行为里自动学习的候选规则）。
class CorrectionPair {
  /// 识别错误片段（触发匹配的钥匙），非空
  final String error;

  /// 用户修正后的片段；空串表示"删除该片段"（如删掉识别出来的口水词）
  final String correct;

  /// 学习/命中次数（DB 层维护，内存构造默认 1）
  final int hitCount;

  const CorrectionPair({
    required this.error,
    required this.correct,
    this.hitCount = 1,
  });

  @override
  bool operator ==(Object other) =>
      other is CorrectionPair &&
      other.error == error &&
      other.correct == correct;

  @override
  int get hashCode => Object.hash(error, correct);

  @override
  String toString() => '「$error」→「${correct.isEmpty ? '(删除)' : correct}」';
}

/// 从「原文 → 改后文本」的字符级差异中抽取「错误-修正」对的纯逻辑工具。
///
/// 算法：去掉公共前后缀缩小范围 → LCS 对齐（错字处优先走"替换"而不是
/// 删+插）→ 连续非相同操作并成一个差异片段 → 替换类片段补全到完整词
/// （可注入分词器时）→ 过滤噪音（纯标点删除、整句重写、超长片段）。
class CorrectionLearner {
  /// 错误片段最短长度；不足时向两侧吸收相邻的相同字符做上下文，
  /// 避免学出「明→后」这种到处误伤的单字对（吸收后变成「明天→后天」）
  static const int _minErrorLength = 2;

  /// 片段最长长度，超过视为整句重写，不学习
  static const int _maxFragmentLength = 30;

  /// 分词补全/叠词并词后的钥匙长度上限（再长下次错误串稍变就匹配不上了）
  static const int _maxKeyLength = 8;

  /// 去掉公共前后缀后差异区的最大长度，超过视为重写，放弃对齐
  static const int _maxDiffRegionLength = 500;

  /// 全文相同字符占比下限，低于视为整句重写（不是识别错误，是改写了句子）
  static const double _minCommonRatio = 0.25;

  /// 被前后缀 trim 掉的字符里，接回对齐序列做"虚拟 keep"的最大个数。
  /// 吸收上下文每个片段每侧最多需要 _minErrorLength 个字符
  static const int _contextKeepCount = 2;

  /// 中文分词器（生产由 ContextCorrector 加载 dart_jieba 后注入；
  /// null = 未注入，替换类片段回退到固定吸收逻辑）。
  /// 返回的 token 序列拼接必须等于输入文本（jieba 保证），extract 内部
  /// 按顺序累计得到每个 token 的字符区间。
  static List<String> Function(String)? wordSegmenter;

  /// 双钥匙抽取：primary = 分词补全的整词钥匙（准，误伤少），
  /// shortCore = 固定吸收的短钥匙（下次错误串稍变时兜底命中——
  /// 整词钥匙「管管雎鸠」match 不上「管管雎究」，短核「管管」可以）。
  /// 未注入分词器时 shortCore 为空（两条本来就相同）。
  /// 实现上把分词器临时摘除再跑一遍 extract（纯函数幂等，两遍 LCS
  /// 差异区 ≤500 字，保存时一次性开销可接受）。
  static ({List<CorrectionPair> primary, List<CorrectionPair> shortCore})
  extractAll(String original, String edited) {
    final primary = extract(original, edited);
    final seg = wordSegmenter;
    if (seg == null) return (primary: primary, shortCore: const []);
    List<CorrectionPair> shortCore;
    try {
      CorrectionLearner.wordSegmenter = null;
      shortCore = extract(original, edited);
    } finally {
      CorrectionLearner.wordSegmenter = seg;
    }
    final pset = {...primary};
    return (
      primary: primary,
      shortCore: shortCore.where((p) => !pset.contains(p)).toList(),
    );
  }

  /// 折叠"被包含"的短核对：双钥匙对（整词+短核）的错误侧与修正侧互为
  /// 子串（管管雎鸠→关关雎鸠 与 管管→关关），提示场景只展示长钥匙——
  /// 避免"共 N 处"计数撑虚高。修正侧不同时不算双钥匙（直给→脂给 虽
  /// error ⊂ 体直给，但 脂给 ⊄ 体脂率，可能是两条独立规则）不折叠。
  /// 替换场景不需要折叠：applyCorrections 长钥匙先替换，短钥匙自然落空。
  static List<CorrectionPair> dedupeSubsumed(Iterable<CorrectionPair> pairs) {
    final list = pairs.toList();
    return list.where((p) {
      return !list.any(
        (q) =>
            q.error.length > p.error.length &&
            q.error.contains(p.error) &&
            q.correct.contains(p.correct),
      );
    }).toList();
  }

  /// 从 原文 → 用户改后文本，抽取可学习的「错误-修正」对。
  /// 返回空列表表示没有值得学习的内容（没改 / 纯新增 / 整句重写）。
  static List<CorrectionPair> extract(String original, String edited) {    if (original.isEmpty || edited.isEmpty || original == edited) {
      return const [];
    }

    // 1) 去公共前后缀，把差异压缩到中段
    final minLen = min(original.length, edited.length);
    int start = 0;
    while (start < minLen &&
        original.codeUnitAt(start) == edited.codeUnitAt(start)) {
      start++;
    }
    int endA = original.length;
    int endB = edited.length;
    while (endA > start &&
        endB > start &&
        original.codeUnitAt(endA - 1) == edited.codeUnitAt(endB - 1)) {
      endA--;
      endB--;
    }
    final midA = original.substring(start, endA);
    final midB = edited.substring(start, endB);

    // 纯新增（原文中段为空）：没有"错误片段"可触发匹配，学不了
    if (midA.isEmpty) return const [];

    // 纯删除（改后中段为空）：整段被删，按单条删除对处理
    if (midB.isEmpty) {
      final pair = _pairFromFragments(midA, '');
      return pair == null ? const [] : [pair];
    }

    // 中段过长 = 整句重写，放弃
    if (midA.length > _maxDiffRegionLength ||
        midB.length > _maxDiffRegionLength) {
      return const [];
    }

    // 2) LCS 对齐（携带每步操作的类型，供后续吸收上下文）。
    // 公共前后缀在步骤 1 已被剥掉，而短片段吸收上下文恰恰需要它们——
    // 把被剥掉的头部末 2 个、尾部头 2 个字符作为「虚拟 keep」接回对齐
    // 序列两端（公共前缀 original[k]==edited[k]、公共后缀同理，字符两两
    // 相同才能被 trim，所以虚拟 keep 两侧字符必然一致）
    final ops = _align(midA, midB);
    final extOps = <_Op>[];
    int headKeeps = 0;
    for (int k = max(0, start - _contextKeepCount); k < start; k++) {
      extOps.add(_Op(_OpType.keep, original[k], edited[k]));
      headKeeps++;
    }
    extOps.addAll(ops);
    for (
      int k = endA;
      k < min(original.length, endA + _contextKeepCount);
      k++
    ) {
      extOps.add(_Op(_OpType.keep, original[k], edited[k]));
    }

    // 相同字符占比过低 = 改写了句子而非纠正识别错误。
    // 占比按全文算：中段 keep + 前缀长 + 后缀长，再除以较长一方；
    // 只按中段算会把「长文本改一个字」这种最典型场景误判成重写
    final keeps = ops.where((op) => op.type == _OpType.keep).length;
    final totalCommon = keeps + start + (original.length - endA);
    if (totalCommon / max(original.length, edited.length) < _minCommonRatio) {
      return const [];
    }

    // 3) 连续的非 keep 操作并成一个差异片段（替换+删除+插入混杂也算同一段：
    //    nike→NB 两串无公共字符时对齐器吐不出 replace，只能靠并段还原
    //    「整词替换」语义，否则会学出「删掉 ke」这种错对）；
    //    替换类片段补全到完整词（分词注入时）或吸收相邻 keep（回退时），
    //    最后过滤噪音
    final pairs = <CorrectionPair>[];
    final seen = <CorrectionPair>{};
    // 虚拟 keep 只是吸收用的上下文，自身永不成为片段：跳过头部 headKeeps 个，
    // 片段扫描终点不越过真实 ops 的末尾
    final bodyEnd = headKeeps + ops.length;
    // extOps[i] 对应的 original/edited 已消耗字符数（keep/replace 各消耗 1，
    // delete 只消耗 a 侧，insert 只消耗 b 侧），供分词补全定位片段的真实区间。
    // 头部虚拟 keep 恰好消耗 original[start-headKeeps..start)，走到真实 ops
    // 第一个 op 时已消耗 = start
    int offsetA = start;
    int offsetB = start;
    // 惰性分词缓存：null=未分，空表=分词不可用/结果非法（回退固定吸收）
    List<(int, int)>? segWords;
    int i = headKeeps;
    while (i < bodyEnd) {
      if (extOps[i].type == _OpType.keep) {
        i++;
        offsetA++;
        offsetB++;
        continue;
      }
      final aStart = offsetA;
      final bStart = offsetB;
      int j = i;
      while (j < bodyEnd && extOps[j].type != _OpType.keep) {
        j++;
        switch (extOps[j - 1].type) {
          case _OpType.delete:
            offsetA++;
          case _OpType.insert:
            offsetB++;
          default: // keep / replace 两侧都消耗
            offsetA++;
            offsetB++;
        }
      }
      final aEnd = offsetA;
      final bEnd = offsetB;
      var runA = original.substring(aStart, aEnd);
      var runB = edited.substring(bStart, bEnd);
      // 纯插入片段没有"错误钥匙"，吸收上下文也不能学（否则「好的」→「好的呀」
      // 会学出「好的→好的呀」到处乱改）；纯标点/空格的删除是顺手清理不是纠错，
      // 也不学习（删除的有意义性必须看吸收上下文前的裸片段，否则「删标点」
      // 吸收一个汉字后就伪装成有意义了）
      if (runA.isEmpty || (runB.isEmpty && !_isMeaningfulDeletion(runA))) {
        i = j; // offsetA/offsetB 已推进到片段末尾
        continue;
      }
      // 替换类片段：按原文分词补全到完整词（用户改词中的一个字，钥匙取整个词——
      // 「体直给」改「直」学到「体直→体脂」而不是「直给→脂给」这种半截钥匙；
      // 「管管雎鸠」改「管」学到「管管雎鸠→关关雎鸠」）。
      // ASR 错误通常保留词界结构，所以对原文分词即可（改后分词会被 HMM
      // 带偏：「关关雎鸠」切成「关关雎|鸠」）
      if (runB.isNotEmpty && wordSegmenter != null) {
        segWords ??= _segmentWords(original);
        final pair = _wordCompletePair(
          original,
          edited,
          segWords,
          aStart: aStart,
          aEnd: aEnd,
          bStart: bStart,
          bEnd: bEnd,
          i: i,
          j: j,
          extOps: extOps,
        );
        if (pair != null) {
          runA = pair.$1;
          runB = pair.$2;
        }
      }
      // 错误片段仍太短（如「明→后」单字词）：向两侧吸收相邻 keep 的同位字符，
      // 两边同步吸收（keep 在原文和改后中相同），得到「明天→后天」这类带上下文的对。
      // 替换类片段两侧各吸一个（单字改错是语音纠错高频操作，用户只点光标改一个字，
      // 右侧优先会吸到后半截无关字——「体直给→体脂给」若只吸右侧学成「直给→脂给」，
      // 误伤真实词「直给」）；删除类维持右侧优先（净效果=删中间字，两侧同吸只是加长钥匙）
      if (runA.length < _minErrorLength) {
        // 吸收前先记下片段类型：吸收会把两侧字符同时接进 runA/runB，
        // 纯删除片段（runB 空）吸完就不空了，不能用 runB.isEmpty 事后判断
        final isDeletion = runB.isEmpty;
        int lo2 = i;
        int hi2 = j;
        while (runA.length < _minErrorLength) {
          var grew = false;
          if (hi2 < extOps.length && extOps[hi2].type == _OpType.keep) {
            runA += extOps[hi2].a!;
            runB += extOps[hi2].b!;
            hi2++;
            grew = true;
          }
          if (isDeletion && runA.length >= _minErrorLength) break;
          if (lo2 > 0 && extOps[lo2 - 1].type == _OpType.keep) {
            lo2--;
            runA = '${extOps[lo2].a!}$runA';
            runB = '${extOps[lo2].b!}$runB';
            grew = true;
          }
          if (!grew) break; // 两侧都没有可吸收的 keep 了
        }
      }
      final pair = _pairFromFragments(runA, runB);
      if (pair != null && seen.add(pair)) {
        pairs.add(pair);
      }
      i = j;
    }
    return pairs;
  }

  /// 分词原文为内容词区间列表（只留含中文字符/字母数字的 token，标点空格
  /// 不参与补全）。token 拼接必须等于原文（jieba 保证），不满足或分词抛异常
  /// 返回空表（回退固定吸收）
  static List<(int, int)> _segmentWords(String original) {
    try {
      final tokens = wordSegmenter!(original);
      if (tokens.join() != original) return const [];
      final words = <(int, int)>[];
      var off = 0;
      for (final t in tokens) {
        if (t.isNotEmpty && _isMeaningfulDeletion(t)) {
          words.add((off, off + t.length));
        }
        off += t.length;
      }
      return words;
    } catch (_) {
      return const [];
    }
  }

  /// 分词补全：把原文区间 [aStart, aEnd) 上的错误片段补全到相交的内容词，
  /// edited 侧同步扩展（扩展只走 keep 区，两侧字符两两相同）。
  /// 补全后钥匙是 AA 叠词（管管/天天）再并入紧邻一个内容词——叠词钥匙
  /// 撞真实口语词（"管管这事儿"），带一个邻词才有区分度。
  /// 返回 (runA, runB)；null = 分词不可用（回退固定吸收）。
  static (String, String)? _wordCompletePair(
    String original,
    String edited,
    List<(int, int)> words, {
    required int aStart,
    required int aEnd,
    required int bStart,
    required int bEnd,
    required int i,
    required int j,
    required List<_Op> extOps,
  }) {
    if (words.isEmpty) return null;
    // 补全到相交的内容词
    var sA = aStart;
    var eA = aEnd;
    for (final (ws, we) in words) {
      if (ws < aEnd && we > aStart) {
        sA = min(sA, ws);
        eA = max(eA, we);
      }
    }
    // 扩展必须全落在 keep 区（op 数 = 字符数）：左右各数连续 keep 的个数，
    // 可越过 bodyEnd 使用尾部虚拟 keep（同旧吸收逻辑的边界）
    var leftKeep = 0;
    while (i - 1 - leftKeep >= 0 && extOps[i - 1 - leftKeep].type == _OpType.keep) {
      leftKeep++;
    }
    var rightKeep = 0;
    while (j + rightKeep < extOps.length &&
        extOps[j + rightKeep].type == _OpType.keep) {
      rightKeep++;
    }
    final growL = min(aStart - sA, leftKeep);
    final growR = min(eA - aEnd, rightKeep);
    sA = aStart - growL;
    eA = aEnd + growR;
    var wordA = original.substring(sA, eA);
    var wordB = edited.substring(bStart - growL, bEnd + growR);
    // AA 叠词钥匙：并入紧邻一个内容词（右侧优先，无则左侧），
    // 并词后总长不超 _maxKeyLength、且该侧 keep 足够覆盖
    if (wordB.length == 2 && wordB.codeUnitAt(0) == wordB.codeUnitAt(1)) {
      final right = _adjacentWord(words, eA, forward: true);
      final rightLen = right == null ? 0 : right.$2 - right.$1;
      if (right != null &&
          rightLen <= rightKeep - growR &&
          eA + rightLen - aStart <= _maxKeyLength) {
        wordA = original.substring(sA, eA + rightLen);
        wordB = edited.substring(bStart - growL, bEnd + growR + rightLen);
      } else {
        final left = _adjacentWord(words, sA, forward: false);
        final leftLen = left == null ? 0 : left.$2 - left.$1;
        if (left != null &&
            leftLen <= leftKeep - growL &&
            eA - left.$1 <= _maxKeyLength) {
          wordA = original.substring(left.$1, eA);
          wordB = edited.substring(bStart - growL - leftLen, bEnd + growR);
        }
      }
    }
    return (wordA, wordB);
  }

  /// 紧邻 boundary 的内容词：forward 取 start == boundary 的词（右侧），
  /// 否则取 end == boundary 的词（左侧）；无则 null
  static (int, int)? _adjacentWord(
    List<(int, int)> words,
    int boundary, {
    required bool forward,
  }) {
    for (final w in words) {
      if (forward ? w.$1 == boundary : w.$2 == boundary) return w;
    }
    return null;
  }

  /// 把 text 中所有命中的错误片段替换为修正片段（按错误片段长度降序，
  /// 先长后短，避免短片段抢先替换破坏长片段的匹配）。
  static String applyCorrections(String text, Iterable<CorrectionPair> pairs) {
    final sorted = pairs.where((p) => p.error.isNotEmpty).toList()
      ..sort((x, y) => y.error.length.compareTo(x.error.length));
    var result = text;
    for (final p in sorted) {
      result = result.replaceAll(p.error, p.correct);
    }
    return result;
  }

  // ==================== 文本编解码（导入/导出用） ====================
  // 格式与热词文件 user_hotwords.txt 一致：每行「错误 = 修正」，
  // # 开头为注释行，人类可读可手改；修正为空串表示删除对（行尾留空）。

  /// 把修正对列表编码成文本（备份 ZIP 里的 correction_pairs.txt、
  /// 管理页单文件导出都用这个格式）
  static String encodeCorrections(Iterable<CorrectionPair> pairs) {
    final buf = StringBuffer('# 声物记 错误-修正学习表（每行: 错误 = 修正）\n');
    for (final p in pairs) {
      if (p.error.isEmpty || p.error == p.correct) continue;
      buf.writeln('${p.error} = ${p.correct}');
    }
    return buf.toString();
  }

  /// 解析文本为修正对列表（备份导入、管理页单文件导入共用）。
  /// 自动跳过注释行、空行和格式不完整的行；同一对去重。
  /// 用正则而非 `split(' = ')`：删除对的修正侧是空串，行尾空格被 trim 掉后
  /// 行内容是「嗯嗯 =」，按固定分隔符切会整行丢弃
  static List<CorrectionPair> parseCorrections(String content) {
    final pairs = <CorrectionPair>[];
    final seen = <CorrectionPair>{};
    final pattern = RegExp(r'^\s*(.+?)\s*=\s*(.*)$');
    for (var line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final m = pattern.firstMatch(line);
      if (m == null) continue;
      final error = m.group(1)!.trim();
      final correct = m.group(2)!.trim();
      if (error.isEmpty || error == correct) continue;
      final pair = CorrectionPair(error: error, correct: correct);
      if (seen.add(pair)) {
        pairs.add(pair);
      }
    }
    return pairs;
  }

  /// 片段 → 学习对的守门过滤：超长放弃、删除对要求"有意义"（含文字/数字，
  /// 纯标点空格的删除多为顺手清理，不值得学）
  static CorrectionPair? _pairFromFragments(String error, String correct) {
    if (error.isEmpty || error == correct) return null;
    if (error.length > _maxFragmentLength) return null;
    if (correct.length > _maxFragmentLength) return null;
    if (correct.isEmpty && !_isMeaningfulDeletion(error)) return null;
    return CorrectionPair(error: error, correct: correct);
  }

  /// 删除对是否有学习价值：至少含一个中文字符或字母数字（口水词"嗯嗯"值得记，
  /// 分隔符"-"、"、"这类是用户清理格式，不是纠错）
  static bool _isMeaningfulDeletion(String s) {
    for (final cu in s.codeUnits) {
      final isCJK =
          (cu >= 0x4E00 && cu <= 0x9FFF) || (cu >= 0x3400 && cu <= 0x4DBF);
      final isAlnum =
          (cu >= 0x30 && cu <= 0x39) || // 0-9
          (cu >= 0x41 && cu <= 0x5A) || // A-Z
          (cu >= 0x61 && cu <= 0x7A); // a-z
      if (isCJK || isAlnum) return true;
    }
    return false;
  }

  /// LCS 对齐：返回操作序列（keep/replace/delete/insert）。
  /// 错字处对角优先（dp 对角值 >= 两个方向时走 replace），
  /// 让「明→后」对齐成一条替换而不是 删明+插后，片段对才有正确语义
  static List<_Op> _align(String a, String b) {
    final dp = List<Uint16List>.generate(
      a.length + 1,
      (_) => Uint16List(b.length + 1),
    );
    for (int i = a.length - 1; i >= 0; i--) {
      for (int j = b.length - 1; j >= 0; j--) {
        dp[i][j] = a.codeUnitAt(i) == b.codeUnitAt(j)
            ? dp[i + 1][j + 1] + 1
            : max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
    final ops = <_Op>[];
    int i = 0;
    int j = 0;
    while (i < a.length && j < b.length) {
      if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
        ops.add(_Op(_OpType.keep, a[i], b[j]));
        i++;
        j++;
      } else if (dp[i + 1][j + 1] >= dp[i + 1][j] &&
          dp[i + 1][j + 1] >= dp[i][j + 1]) {
        ops.add(_Op(_OpType.replace, a[i], b[j]));
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        ops.add(_Op(_OpType.delete, a[i], null));
        i++;
      } else {
        ops.add(_Op(_OpType.insert, null, b[j]));
        j++;
      }
    }
    while (i < a.length) {
      ops.add(_Op(_OpType.delete, a[i], null));
      i++;
    }
    while (j < b.length) {
      ops.add(_Op(_OpType.insert, null, b[j]));
      j++;
    }
    return ops;
  }
}

/// 对齐操作：keep=两边相同的字符；replace=错字替换（a→b）；
/// delete=原文多出的字符（b 为 null）；insert=用户新增的字符（a 为 null）
class _Op {
  final _OpType type;
  final String? a;
  final String? b;
  const _Op(this.type, this.a, this.b);
}

enum _OpType { keep, replace, delete, insert }
