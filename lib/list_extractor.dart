import 'app_logger.dart';

/// 清单提取器 - 从中文语音识别结果中提取结构化待办清单
/// 纯 Dart 实现，不依赖第三方分词库
/// 使用 5 阶段管道：预处理 → 意图检测 → 条目拆分 → 结构提取 → 分类

// ============================================================
// 数据模型
// ============================================================

/// 单个清单条目
class TodoItem {
  final String content; // 核心内容，如"牛奶"、"打扫卫生"
  final int? quantity; // 数量，如 10
  final String? unit; // 单位，如"个"、"斤"
  final String category; // 分类："购物"、"家务"、"工作"、"生活"、"未分类"
  final String? time; // 时间信息（原始文本），如"下午三点"
  final String? rawSegment; // 原始分片文本，便于调试

  const TodoItem({
    required this.content,
    this.quantity,
    this.unit,
    this.category = '未分类',
    this.time,
    this.rawSegment,
  });

  @override
  String toString() {
    final parts = <String>['"$content"'];
    if (quantity != null) parts.add('qty=$quantity');
    if (unit != null) parts.add('unit="$unit"');
    if (category != '未分类') parts.add('cat=$category');
    if (time != null) parts.add('time="$time"');
    return 'TodoItem(${parts.join(', ')})';
  }

  Map<String, dynamic> toMap() {
    return {
      'content': content,
      'quantity': quantity,
      'unit': unit,
      'category': category,
      'time': time,
    };
  }
}

/// 提取结果
class ExtractionResult {
  final bool isList; // 是否被识别为清单
  final List<TodoItem> items; // 提取出的条目列表
  final String normalizedText; // 预处理后的文本
  final String? detectedIntent; // 检测到的意图类型（"购物"、"任务"、"清单"）

  const ExtractionResult({
    required this.isList,
    this.items = const [],
    this.normalizedText = '',
    this.detectedIntent,
  });

  @override
  String toString() {
    return 'ExtractionResult(isList=$isList, count=${items.length}, '
        'intent=$detectedIntent)\n  ${items.join('\n  ')}';
  }

  /// 将清单条目转为 markdown 任务列表格式
  /// 每条目一行，默认未完成状态
  /// 非清单或空条目时返回空字符串
  ///
  /// 方案 A（2026-06-29）：displayText 用 rawSegment（清理首尾标点）保留原句语序，
  /// 不再前置 quantity+unit。避免"最后再买两包烟"被错拼成"2包最后再买烟"。
  /// quantity/unit/time 仍作为元数据保留在 TodoItem 上，供将来 UI 升级使用。
  String toMarkdown() {
    if (!isList || items.isEmpty) return '';

    final lines = items.map((item) {
      // rawSegment 是用户原话，content 经过前缀剥离可能丢信息，这里取原话
      // 顺手清掉首尾的逗号/顿号/句号/空格（用户说话末尾常有句号）
      final displayText = (item.rawSegment ?? item.content)
          .replaceAll(RegExp(r'^[，、,。.、\s]+'), '')
          .replaceAll(RegExp(r'[，、,。.、\s]+$'), '');
      return '- [ ] $displayText'; // 默认未完成
    });
    return lines.join('\n');
  }
}

// ============================================================
// 意图检测结果（内部用）
// ============================================================

class _IntentResult {
  final bool isList;
  final String? type; // "购物"、"任务"、"清单"
  final int score; // 评分，调试用

  const _IntentResult({
    required this.isList,
    this.type,
    this.score = 0,
  });
}

// ============================================================
// 核心提取器
// ============================================================

class ListExtractor {
  // ============ 静态词典 ============

  /// 口语填充词（长短优先排列，"就是说"在"就是"前面）
  static const _fillerWords = [
    '老实说',
    '说实话',
    '怎么说呢',
    '就是说',
    '然后呢',
    '那个',
    '就是',
    '嗯',
    '呃',
    '对吧',
    '嘛',
    '哈',
    '啊',
    '哦',
  ];

  /// 枚举连接词（用于条目拆分）
  static const _enumConnectors = [
    '然后',
    '接着',
    '再',
    '还有',
    '还',
    '并且',
    '而且',
    '同时',
    '另外',
    '之后',
    '随后',
  ];

  /// 购物动词（意图检测 + 分类用）
  static const _shoppingVerbs = [
    '买',
    '购',
    '拿',
    '带',
    '取',
    '领',
    '抢',
    '补',
  ];

  /// 任务动词（意图检测 + 分类用）
  static const _taskVerbs = [
    '打扫',
    '清理',
    '洗',
    '拖',
    '擦',
    '整理',
    '收拾',
    '完成',
    '写',
    '做',
    '安排',
    '处理',
    '发',
    '送',
  ];

  /// 引导动词前缀（Stage 4 中去除）
  /// 长短优先，确保长前缀优先匹配
  static const _leadVerbPrefixes = [
    // 带连接词的组合前缀
    '然后去买点',
    '然后去买些',
    '然后要买点',
    '然后要买些',
    '然后去买',
    '然后要买',
    '然后买点',
    '然后买些',
    '再买点',
    '再买些',
    '接着去买',
    '接着买',
    '回来',
    '然后买',
    '再买',
    // 带主语的前缀
    '我要买点',
    '我要买些',
    '我要买',
    '要先',
    '要去',
    '先去买',
    '先要买',
    '先买',
    // 通用动词前缀
    '去买点',
    '去买些',
    '要买点',
    '要买些',
    '去买',
    '去拿',
    '去带',
    '要买',
    '买点',
    '买些',
    '带点',
    '带些',
    '拿点',
    '拿些',
    '买',
    '带',
    '拿',
    '去',
    '先',
    '要',
    '我',
  ];

  /// 量级修饰词（Stage 4 中去除）
  static const _quantityModifiers = [
    '一点儿',
    '一点',
    '点儿',
    '一些',
    '些',
    '点',
  ];

  /// 中文量词正则（用于数量提取）
  static const _measureWordPattern =
      '(个|只|箱|瓶|斤|袋|盒|把|条|本|张|份|双|块|片|杯|桶|套|包|对'
      '|副|串|排|捆|碗|壶|锅|盆|罐|管|支|根|朵|页|册|部|篇|首|幅|座'
      '|栋|间|层|户|门|款|项|堆|组|打|批|节|道|服|滴|粒|颗|株|枚|辆'
      '|架|台|匹|头|口|名|位|群|队|剂|克|千克|公斤|吨|升|毫升|米|厘米'
      '|毫米|公里|寸|尺|丈)';

  /// 中文数字到阿拉伯数字的映射
  static const _chineseNumberMap = {
    '两': '2',
    '十': '10',
    '百': '100',
  };

  /// 类别关键词映射（Stage 5 分类用）
  static const _categoryKeywords = <String, List<String>>{
    '购物': [
      '买',
      '购',
      '拿',
      '带',
      '超市',
      '商店',
      '市场',
      '网购',
      '下单',
      '补货',
    ],
    '家务': [
      '打扫',
      '清理',
      '洗',
      '拖',
      '擦',
      '整理',
      '收拾',
      '晾',
      '叠',
      '倒垃圾',
      '保洁',
    ],
    '工作': [
      '开会',
      '报告',
      '提交',
      '审核',
      '审批',
      '方案',
      '文档',
      '会议',
      '邮件',
      '联系',
      '汇报',
    ],
    '生活': [
      '预约',
      '缴费',
      '取快递',
      '送修',
      '叫外卖',
      '打车',
      '叫保洁',
      '理发',
      '体检',
    ],
  };

  /// 时间关键词正则（简单匹配）
  static final _timePattern = RegExp(
    r'(今天|明天|后天|大后天|早上|上午|中午|下午|晚上|今晚|明早|明晚'
    r'|周[一二三四五六日末]|下周[一二三四五六日末]|这周|本周)'
    r'([上下]午)?\s*(\d{1,2})?[点时]?',
  );

  // ============ 公开方法 ============

  /// 主入口：从语音识别文本中提取清单
  /// 返回 ExtractionResult，isList=false 表示不是清单
  ///
  /// 触发词门禁（2026-06-29 加入）：
  /// - 文本必须严格以"代办"或"待办"开头才会进入清单提取流程
  /// - 命中后剥离触发词，剩余内容走后续拆分/提取/分类管道
  /// - 设计意图：用白名单替代脆弱的评分制，"开口"开小，正常说话不误判
  ExtractionResult extract(String rawText) {
    if (rawText.trim().isEmpty) {
      return const ExtractionResult(isList: false, normalizedText: '');
    }

    // Stage 1: 预处理
    final cleaned = _preprocess(rawText);
    log('[ListExtractor] 预处理后: "$cleaned"');

    // Stage 1.5: 触发词门禁
    // 必须严格以"代办"或"待办"开头（不支持前置引导词，避免"我要代办..."误触发）
    // "代办"/"待办"是同音词，语音识别两者都可能出现，都接受
    String? triggerWord;
    if (cleaned.startsWith('代办')) {
      triggerWord = '代办';
    } else if (cleaned.startsWith('待办')) {
      triggerWord = '待办';
    }

    if (triggerWord == null) {
      log('[ListExtractor] 未命中触发词"代办/待办"，跳过清单提取');
      return ExtractionResult(
        isList: false,
        normalizedText: cleaned,
      );
    }

    // 剥离触发词后送入后续管道
    // 不对触发词后的分隔符做任何要求（标点、空格、直接接内容都允许）
    // 这里顺手清掉首尾残余标点（如"代办，买苹果"→"买苹果"），
    // 否则前导逗号会挡住 _extractStructure 里的动词前缀剥离
    final payload = cleaned
        .substring(triggerWord.length)
        .trim()
        .replaceAll(RegExp(r'^[，、,]\s*'), '')
        .replaceAll(RegExp(r'\s*[，、,]\s*$'), '');
    log('[ListExtractor] 命中触发词"$triggerWord"，剥离后内容: "$payload"');

    if (payload.isEmpty) {
      // 只有触发词没有实际内容，不算清单
      log('[ListExtractor] 触发词后无内容，跳过清单提取');
      return ExtractionResult(
        isList: false,
        normalizedText: cleaned,
      );
    }

    // Stage 2: 意图检测（保留分类逻辑用于打"购物/任务/家务"标签）
    // 注意：isList 已由触发词门禁决定，_detectIntent 内部的评分判定不再生效
    // 仅 intent.type（分类标签）仍有意义
    final intent = _detectIntent(payload);
    log('[ListExtractor] 意图检测(仅用于分类): type=${intent.type}, '
        'score=${intent.score}');

    // Stage 3: 条目拆分
    final segments = _splitEntries(payload);
    log('[ListExtractor] 拆分结果: $segments');

    if (segments.length < 2) {
      // 拆分后只有一条，不算清单
      return ExtractionResult(
        isList: false,
        normalizedText: cleaned,
      );
    }

    // Stage 4: 结构提取
    final items =
        segments.map((s) => _extractStructure(s, intent.type ?? '清单')).toList();

    // Stage 5: 分类
    final classified = _classify(items, intent.type ?? '清单');

    return ExtractionResult(
      isList: true,
      items: classified,
      normalizedText: cleaned,
      detectedIntent: intent.type,
    );
  }

  // ============ Stage 1: 预处理 ============

  String _preprocess(String text) {
    var result = text;

    // 半角逗号统一为全角
    result = result.replaceAll(',', '，');

    // 去口语填充词（已按长度降序排列，确保"就是说"在"就是"之前匹配）
    for (final word in _fillerWords) {
      result = result.replaceAll(word, '');
    }

    // 去首尾空格
    result = result.trim();

    return result;
  }

  // ============ Stage 2: 意图检测（评分制） ============

  _IntentResult _detectIntent(String text) {
    int score = 0;
    String? intentType;

    // --- 加分项 ---

    // 顿号出现：+3（中文清单的强信号）
    final dunCount = '、'.allMatches(text).length;
    if (dunCount >= 1) score += 3;

    // 逗号分隔片段 >= 3（多个并列短语是清单的强信号）
    // 但纯逗号分段是弱信号——日记也经常用逗号分段
    final commaParts =
        text.split('，').where((s) => s.trim().isNotEmpty).length;
    if (commaParts >= 5) {
      score += 3; // 5+ 段逗号，清单信号较强
    } else if (commaParts >= 3 && dunCount >= 1) {
      score += 3; // 3+ 段逗号且有顿号，清单信号较强
    } else if (commaParts >= 3) {
      score += 1; // 仅逗号分段，弱信号
    }
    // 注意：2 段逗号不给分，避免"这个购物清单不会刷新，必须切换才刷新"误判

    // 枚举连接词出现次数
    int enumCount = 0;
    for (final conn in _enumConnectors) {
      enumCount += conn.allMatches(text).length;
    }
    if (enumCount >= 2) score += 2;
    if (enumCount >= 1) score += 1;

    // 数量词模式出现次数
    final quantPattern = RegExp(r'\d+\s*' + _measureWordPattern);
    final quantCount = quantPattern.allMatches(text).length;
    if (quantCount >= 2) score += 2;
    if (quantCount >= 1) score += 1;

    // 购物动词出现
    bool hasShoppingVerb = false;
    for (final verb in _shoppingVerbs) {
      if (text.contains(verb)) {
        hasShoppingVerb = true;
        break;
      }
    }
    if (hasShoppingVerb) {
      score += 1;
      intentType = '购物';
    }

    // 任务动词出现
    bool hasTaskVerb = false;
    for (final verb in _taskVerbs) {
      if (text.contains(verb)) {
        hasTaskVerb = true;
        break;
      }
    }
    if (hasTaskVerb) {
      score += 1;
      intentType ??= '任务';
    }

    // 如果没有任何具体意图，但有清单信号
    intentType ??= (score >= 2) ? '清单' : null;

    // --- 减分项 ---

    // 顿号分隔的片段数
    final dunParts = text.split('、').where((s) => s.trim().isNotEmpty).length;

    // 无任何分隔符且无枚举词
    if (commaParts < 2 && dunParts < 2 && enumCount < 1 && quantCount < 2) {
      score -= 5;
    }

    // 包含物品位置关键词且无其他清单信号
    final hasLocationKeyword =
        text.contains('放在') || text.contains('在');
    if (hasLocationKeyword && !hasShoppingVerb && !hasTaskVerb && dunCount == 0) {
      score -= 3;
    }

    // --- 叙述文本检测（减分） ---
    // 叙述性文字常含逗号和"然后"，但不是清单，需额外检测

    // 规则 1：片段长度差异过大
    // 真清单各片段长度相近，叙述文长短差异极大
    final commaSegments = text
        .split('，')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (commaSegments.length >= 3) {
      final lengths = commaSegments.map((s) => s.trim().length).toList();
      final maxLen = lengths.reduce((a, b) => a > b ? a : b);
      final minLen = lengths.reduce((a, b) => a < b ? a : b);
      if (minLen > 0 && maxLen > minLen * 5) {
        score -= 4;
      }
    }

    // 规则 2：叙事模式关键词
    // "当...就"、"全程"、"新增了"等是叙述文特征，清单不会出现
    final narrativePatterns = [
      RegExp(r'当.*就'),
      RegExp(r'如果.*就'),
      RegExp(r'只要.*就'),
    ];
    final narrativeStarts = ['新增了', '更新了', '添加了', '修复了'];
    final narrativeKeywords = ['全程', '之后就会', '就可以', '就能', '弹出提醒'];

    bool isNarrative = false;
    for (final p in narrativePatterns) {
      if (p.hasMatch(text)) {
        isNarrative = true;
        break;
      }
    }
    if (!isNarrative) {
      for (final s in narrativeStarts) {
        if (text.startsWith(s)) {
          isNarrative = true;
          break;
        }
      }
    }
    if (!isNarrative) {
      for (final k in narrativeKeywords) {
        if (text.contains(k)) {
          isNarrative = true;
          break;
        }
      }
    }
    if (isNarrative) score -= 3;

    // 规则 3：完整句子比例过高
    // 真清单片段是名词短语（短），叙述文含"会/能/可以/了"等句式（长句子）
    if (commaSegments.length >= 3) {
      final sentencePattern = RegExp(r'[会能否可以了着过]');
      final sentenceCount =
          commaSegments.where((s) => sentencePattern.hasMatch(s)).length;
      if (sentenceCount > commaSegments.length / 2) {
        score -= 3;
      }
    }

    // 日记前缀检测（不应识别为清单）
    if (text.startsWith('记录一下') || text.startsWith('记一下')) {
      return _IntentResult(isList: false, score: score);
    }

    // 阈值判定
    final isList = score >= 2;
    return _IntentResult(
      isList: isList,
      type: intentType,
      score: score,
    );
  }

  // ============ Stage 3: 条目拆分 ============

  List<String> _splitEntries(String text) {
    List<String> parts;

    // 优先级 1：按顿号拆分
    parts = text.split('、');
    if (parts.where((s) => s.trim().isNotEmpty).length >= 2) {
      return _cleanParts(parts);
    }

    // 优先级 2：按逗号拆分
    parts = text.split('，');
    if (parts.where((s) => s.trim().isNotEmpty).length >= 2) {
      return _cleanParts(parts);
    }

    // 优先级 3：按枚举连接词拆分
    final enumPattern = RegExp(
      r'(?:然后|接着|再|还有|还|并且|而且|同时|另外|之后|随后)',
    );
    parts = text.split(enumPattern);
    if (parts.where((s) => s.trim().isNotEmpty).length >= 2) {
      return _cleanParts(parts);
    }

    // 无法拆分，返回单条
    return [text.trim()].where((s) => s.isNotEmpty).toList();
  }

  /// 清理拆分后的片段：trim + 过滤空串
  List<String> _cleanParts(List<String> parts) {
    return parts
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // ============ Stage 4: 结构提取 ============

  TodoItem _extractStructure(String segment, String intentType) {
    var remaining = segment.trim();
    int? quantity;
    String? unit;
    String? time;

    // 1. 提取时间信息
    final timeMatch = _timePattern.firstMatch(remaining);
    if (timeMatch != null) {
      time = timeMatch.group(0);
      remaining = remaining.replaceFirst(timeMatch.group(0)!, '').trim();
    }

    // 2. 中文数字预处理（"两" → "2"）
    for (final entry in _chineseNumberMap.entries) {
      remaining = remaining.replaceAll(entry.key, entry.value);
    }

    // 3. 提取数量 + 量词
    final quantPattern = RegExp(r'(\d+)\s*' + _measureWordPattern);
    final quantMatch = quantPattern.firstMatch(remaining);
    if (quantMatch != null) {
      quantity = int.tryParse(quantMatch.group(1)!);
      unit = quantMatch.group(2);
      remaining = remaining.replaceFirst(quantMatch.group(0)!, '').trim();
    }

    // 4. 去引导动词前缀（长短优先）
    for (final prefix in _leadVerbPrefixes) {
      if (remaining.startsWith(prefix)) {
        remaining = remaining.substring(prefix.length).trim();
        break;
      }
    }

    // 5. 去量级修饰词
    for (final mod in _quantityModifiers) {
      if (remaining.endsWith(mod)) {
        remaining =
            remaining.substring(0, remaining.length - mod.length).trim();
        break;
      }
      if (remaining.startsWith(mod)) {
        remaining = remaining.substring(mod.length).trim();
        break;
      }
    }

    // 6. "和"字拆分辅助：如果分片中包含"和"且前后都是短词
    // 这里不拆分（拆分在 Stage 3 完成），只清理

    // 7. 清理残余标点（含句号 —— 用户说话末尾常带"。"，老逻辑只清逗号顿号）
    remaining = remaining.replaceAll(RegExp(r'^[，、,。.]\s*'), '');
    remaining = remaining.replaceAll(RegExp(r'\s*[，、,。.]\s*$'), '');
    remaining = remaining.trim();

    return TodoItem(
      content: remaining.isNotEmpty ? remaining : segment.trim(),
      quantity: quantity,
      unit: unit,
      category: '未分类', // Stage 5 会覆盖
      time: time,
      rawSegment: segment.trim(),
    );
  }

  // ============ Stage 5: 分类 ============

  List<TodoItem> _classify(List<TodoItem> items, String fallback) {
    return items.map((item) {
      // 对 content 和 rawSegment 匹配类别关键词
      final text = '${item.content} ${item.rawSegment ?? ''}';

      for (final entry in _categoryKeywords.entries) {
        for (final keyword in entry.value) {
          if (text.contains(keyword)) {
            return TodoItem(
              content: item.content,
              quantity: item.quantity,
              unit: item.unit,
              category: entry.key,
              time: item.time,
              rawSegment: item.rawSegment,
            );
          }
        }
      }

      // 未命中关键词 → 继承意图类型作为分类
      return TodoItem(
        content: item.content,
        quantity: item.quantity,
        unit: item.unit,
        category: fallback,
        time: item.time,
        rawSegment: item.rawSegment,
      );
    }).toList();
  }
}
