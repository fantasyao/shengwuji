/// 物品位置语句检测与分割器
///
/// 在日记页检测语音识别后的内容是否为"物品+位置"模式（如"钥匙放在客厅桌子上"），
/// 命中时拆分为物品名和位置，供用户一键转存到 items 表。
///
/// 设计参考：query_detector.dart 的纯 Dart + 静态方法风格。
/// 与录入页 record_tab.dart 原内嵌的 _smartSplit/_cleanPunctuation 逻辑完全一致。
///
/// 测试用例（注释里列出，便于回归）：
///   - "钥匙放在客厅桌子上" → item="钥匙", location="客厅桌子上"
///   - "游戏机在客厅" → item="游戏机", location="客厅"
///   - "游戏机在哪儿" → null（查询语句不命中，由 QueryDetector 处理）
///   - "今天天气不错" → null（无分割关键词）
///   - "今天天气也不错，钥匙放在桌子上" → item="钥匙", location="桌子上"（分句过滤噪音子句）
///   - "钥匙，钱包，手机都在包里" → item="手机都", location="包里"（多子句取第一个命中，可能含残留噪音）
class ItemSplitResult {
  final String item;
  final String location;
  ItemSplitResult({required this.item, required this.location});
}

class ItemSplitter {
  ItemSplitter._(); // 纯工具类，禁止实例化

  // ==================== 校验配置 ====================

  /// 强分隔符：高特异性动词+在/到，命中即可（仍需物品名校验）
  static const List<String> _strongKeys = ['放在', '放进', '放到', '搁在', '藏在'];

  /// 弱分隔符：单字符，必须额外通过位置校验
  static const List<String> _weakKeys = ['在', '再'];

  /// 物品名整体停用（单字代词、虚词）
  static const Set<String> _itemStopWords = {
    '现', '我', '你', '他', '她', '它', '这', '那', '咱',
  };

  /// 物品名停用前缀（startsWith 匹配）
  /// 三类来源：时间态（现在/正在）/ 判断态（应该/可能）/ 人称+时间（他现在/我现在）
  static const List<String> _itemStopPrefixes = [
    // 时间态
    '现在', '正在', '此时',
    // 判断态（"应该在成都"/"可能在家里"）
    '应该', '可能', '肯定', '大概', '估计', '似乎', '好像',
    // 人称+时间组合
    '他现在', '她现在', '它现在', '我现在', '你现在', '咱现在',
    '他们现在', '她们现在', '它们现在',
    // "这个正" 来自原始误判
    '这个正', '那个正', '这些正', '那些正',
    // 人称+判断
    '他应该', '她应该', '它应该', '我应该', '你应该',
    '他可能', '她可能', '它可能', '我可能', '你可能',
    // 人称+正在（"他正在路上" / "她正在吃饭"）
    '他正', '她正', '它正', '我正', '你正', '咱正',
    // 人称+现（"他现在" 中第一个"在"切成"他现"，需兜底）
    '他现', '她现', '它现', '我现', '你现', '咱现',
  ];

  /// 方位词（弱分隔符的位置校验）
  static const List<String> _locationDirectionWords = [
    '里', '上', '下', '前', '后', '旁', '中', '内', '外', '边', '头', '面',
  ];

  /// 短位置长度上限（≤ 此值视为"像位置"）
  static const int _shortLocationMax = 3;
  static const int _minItemLength = 2;
  static const int _minLocationLength = 2;

  /// 去除标点符号（与 record_tab.dart 原 _cleanPunctuation 完全一致）
  /// [，。！？,.!?] 匹配标点，\s 匹配任何空白字符
  static String cleanPunctuation(String text) {
    return text.replaceAll(RegExp(r'[，。！？,.!?\s]'), '').trim();
  }

  /// 检测文本是否为"物品+位置"模式
  /// 命中返回 ItemSplitResult，未命中返回 null
  ///
  /// 内部按中英文标点切分复合句，对每个子句单独检测：
  ///   "今天天气也不错，钥匙放在桌子上" → 子句2 命中 → item="钥匙", location="桌子上"
  /// 这样可以处理临界长度（13~15 字）的复合句，避免前半句的噪音被混入 item。
  ///
  /// 分层校验（修复 "现在他这个滚动页面会动" 等误判）：
  ///   1) 强分隔符（放在/放进/搁在等）：特异性高，物品名通过校验即可
  ///   2) 弱分隔符（在/再）：单字符过于宽泛，物品名 + 位置双重校验
  /// 物品名校验：长度≥2、非停用词、非停用前缀（现在/正在/应该 等）
  /// 位置校验：长度≥2、含方位词 或 短到像位置名
  ///
  /// [lenient] 宽松模式（搬家模式专用）：
  ///   - true：弱分隔符也跳过位置校验，适配"3号盒子/红色袋子/储物箱"这类
  ///     无方位词的纯容器名（搬家场景常见）
  ///   - false（默认）：严格校验，日记页"物品转存横条"被动检测用
  static ItemSplitResult? detect(String text, {bool lenient = false}) {
    // 按中英文标点切分复合句
    final sentences = text.split(RegExp(r'[，。！？,.!?]'));

    for (final s in sentences) {
      if (s.trim().isEmpty) continue;
      final cleanText = cleanPunctuation(s);

      // 1) 强分隔符：物品名校验通过即可
      for (var key in _strongKeys) {
        final result = _trySplit(cleanText, key, checkLocation: false);
        if (result != null) return result;
      }

      // 2) 弱分隔符：默认物品名 + 位置双重校验；lenient 模式下放宽位置校验
      for (var key in _weakKeys) {
        final result = _trySplit(cleanText, key, checkLocation: !lenient);
        if (result != null) return result;
      }
    }
    return null;
  }

  /// 尝试用指定 key 切分 cleanText，返回校验通过的结果或 null
  ///
  /// key 在原文中可能出现多次（如"他现在应该在家里"含两个"在"），
  /// 用 indexOf 遍历每个 key 出现位置做切分，避免 split 破坏"他现在"等词：
  ///   "他现在应该在家里" 第1个"在"→(他,现在应该在家里)
  ///                 第2个"在"→(他现在应该,家里) ← 命中停用前缀"他现在"，跳过
  static ItemSplitResult? _trySplit(String cleanText, String key,
      {required bool checkLocation}) {
    var fromIndex = 0;
    while (true) {
      final idx = cleanText.indexOf(key, fromIndex);
      if (idx < 0) break;

      final item = cleanText.substring(0, idx).trim();
      final location = cleanText.substring(idx + key.length).trim();

      fromIndex = idx + 1; // 移动到下一个位置，查找后续 key 出现

      if (item.length < _minItemLength) continue;
      if (location.length < _minLocationLength) continue;
      if (_isStopItem(item)) continue;
      if (checkLocation && !_isLikelyLocation(location)) continue;

      return ItemSplitResult(item: item, location: location);
    }
    return null;
  }

  /// 物品名是否命中停用词 / 停用前缀
  static bool _isStopItem(String item) {
    if (_itemStopWords.contains(item)) return true;
    for (var prefix in _itemStopPrefixes) {
      if (item.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 位置是否"像位置"：含方位词 或 短到像位置名
  static bool _isLikelyLocation(String location) {
    if (location.length <= _shortLocationMax) return true;
    for (var word in _locationDirectionWords) {
      if (location.contains(word)) return true;
    }
    return false;
  }
}
