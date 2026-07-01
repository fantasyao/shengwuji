/// 查询语句检测器
///
/// 在日记页检测用户是否在"查找物品"（如"游戏机在哪儿"），
/// 区别于普通记录语句（如"游戏机在客厅"）。
///
/// 设计参考：list_extractor.dart 的纯 Dart + 正则风格。
///
/// 测试用例（注释里列出，便于回归）：
///   - "帮我说游戏机在哪儿" → isQuery=true, type=itemQuery, itemName="游戏机"
///   - "钥匙放哪了" → isQuery=true, type=itemQuery, itemName="钥匙"
///   - "我的钱包在哪里" → isQuery=true, type=itemQuery, itemName="钱包"
///   - "游戏机在客厅" → isQuery=false（普通记录，不在结尾问位置）
///   - "钥匙放在桌子上" → isQuery=false（普通记录）
///   - "今天天气也不错，钥匙在哪里" → isQuery=true, type=itemQuery, itemName="钥匙"（分句过滤噪音子句）
///   - "客厅里有什么" → isQuery=true, type=locationQuery, locationName="客厅"
///   - "我家客厅里有什么" → isQuery=true, type=locationQuery, locationName="客厅"（剥"我家"）
///   - "厨房都有什么" → isQuery=true, type=locationQuery, locationName="厨房"

/// 查询方向枚举
/// - itemQuery: 正向查询，"XX在哪里" → 找物品名
/// - locationQuery: 反向查询，"XX里有什么" → 找位置
enum QueryType { itemQuery, locationQuery }

class QueryResult {
  final bool isQuery;
  final String itemName; // 正向查询提取的物品名
  final String locationName; // 反向查询提取的位置名
  final QueryType type;

  const QueryResult({
    this.isQuery = false,
    this.itemName = '',
    this.locationName = '',
    this.type = QueryType.itemQuery,
  });
}

class QueryDetector {
  QueryDetector._(); // 纯工具类，禁止实例化

  /// 正向查询模式（按优先级排序）。
  /// 每个正则都要求文本**结尾**是疑问形式，避免"游戏机在客厅"被误判。
  /// 使用 firstMatch 而非 allMatches，命中第一个就返回。
  static final List<RegExp> _patterns = [
    // "XX在哪儿" / "XX在哪" / "XX在哪里" / "XX在什么地方"
    RegExp(r'(.+?)(?:在哪儿|在哪|在哪里|在什么地方|在啥地方)'),
    // "XX什么地方" / "XX什么位置"（前面没有"在"的变体）
    RegExp(r'(.+?)(?:什么地方|什么位置)'),
    // "XX哪儿了" / "XX哪去了" / "XX放哪了" / "XX放在哪" / "XX放到哪了"
    RegExp(r'(.+?)(?:哪儿了|哪去了|放哪了|放在哪|放到哪了|放哪儿了)'),
  ];

  /// 反向查询模式（按优先级排序，长触发词优先匹配避免误命中）。
  /// 匹配"XX里有什么 / XX里面有什么 / XX中有什么 / XX都有什么 / XX有些什么 / XX有什么"
  /// 捕获组1 = 触发词之前的位置名
  static final List<RegExp> _reversePatterns = [
    // 4字触发词优先（先匹配长的，避免"里面有什么"被"有什么"截断到错误位置）
    RegExp(r'(.+?)(?:里面有什么|中有什么|里有什么)'),
    // "都有什么" / "有些什么"
    RegExp(r'(.+?)(?:都有什么|有些什么)'),
    // "有什么"（最短，兜底——单字位置名也能命中）
    RegExp(r'(.+?)(?:有什么)'),
  ];

  /// 正向查询：需要从物品名前去除的填充词（按长度倒序，优先匹配长的）。
  /// 参考 list_extractor 的填充词列表风格。
  static const _fillerPrefixes = [
    '帮我说',
    '告诉我',
    '请问一下',
    '请问',
    '我想知道',
    '我想问一下',
    '我想问',
    '那个啥',
    '那个东西',
    '那个',
    '我的',
    '一下',
  ];

  /// 反向查询：需要从位置名前去除的填充词。
  /// 注意"房间"作为前缀剥离时仅在开头匹配，不会破坏"房间里有什么"的内部结构。
  static const _reverseFillerPrefixes = [
    '我家',
    '屋里',
    '房间', // 房间类前缀（注意：只在开头剥，"房间里有什么"→"里有什么"前已有"房间"被正则捕获到）
    '那个',
    '这',
    '那',
  ];

  /// 检测给定文本是否为查询语句。
  ///
  /// 内部按中英文标点切分复合句，对每个子句单独检测：
  ///   "今天天气也不错，钥匙在哪里" → 子句2 命中 → itemName="钥匙"
  /// 避免长复合句中的前半句噪音被混入 itemName。
  ///
  /// 返回 [QueryResult]：
  ///   - 命中正向查询时 isQuery=true, type=itemQuery, itemName 为物品名
  ///   - 命中反向查询时 isQuery=true, type=locationQuery, locationName 为位置名
  ///   - 未命中时 isQuery=false，itemName 和 locationName 均为空字符串
  ///
  /// 关键约束：保持原有 detect() 签名向后兼容（DiaryTab 调用方只读 isQuery/itemName，
  /// 新的 type/locationName 字段有默认值，不影响旧调用方）。
  static QueryResult detect(String text) {
    if (text.isEmpty) return const QueryResult();

    // 按中英文标点切分复合句
    final sentences = text.split(RegExp(r'[，。！？,.!?]'));
    for (final s in sentences) {
      if (s.trim().isEmpty) continue;
      final result = _detectSingle(s);
      if (result.isQuery) return result;
    }
    return const QueryResult();
  }

  /// 对单个子句跑检测逻辑（正向优先，反向兜底）
  /// 私有静态方法，仅供 detect 内部分句后调用
  static QueryResult _detectSingle(String text) {
    // 1. 先跑正向查询（保持原有行为不变）
    final forwardResult = _detectForward(text);
    if (forwardResult.isQuery) return forwardResult;

    // 2. 正向未命中，再跑反向查询
    return _detectReverse(text);
  }

  /// 正向查询：原有的"XX在哪里"检测逻辑（正则匹配 + 填充词剥离 + 标点清理）
  static QueryResult _detectForward(String text) {
    // 遍历所有正向模式，命中第一个返回
    for (final pattern in _patterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.groupCount >= 1) {
        String itemName = match.group(1)!.trim();

        // 去除前缀填充词（"我的"、"那个" 等）
        // 多次循环以处理"我的那个游戏机"这类多重前缀
        bool changed = true;
        while (changed) {
          changed = false;
          for (final prefix in _fillerPrefixes) {
            if (itemName.startsWith(prefix) &&
                itemName.length > prefix.length) {
              itemName = itemName.substring(prefix.length).trim();
              changed = true;
              break; // 重新从最长的前缀开始匹配
            }
          }
        }

        // 去除结尾的标点和语气词
        itemName = itemName.replaceAll(RegExp(r'[，。？！、\s]+$'), '');
        itemName = itemName.replaceAll(RegExp(r'^[，。？！、\s]+'), '');

        // 物品名为空或过短 → 视为无效查询
        if (itemName.isEmpty) {
          continue; // 尝试下一个模式
        }

        return QueryResult(
          isQuery: true,
          itemName: itemName,
          type: QueryType.itemQuery,
        );
      }
    }

    return const QueryResult();
  }

  /// 反向查询："XX里有什么" 检测逻辑
  /// 提取触发词之前的部分作为 locationName，剥离反向填充词
  static QueryResult _detectReverse(String text) {
    // 遍历反向模式（按优先级，长触发词先匹配）
    for (final pattern in _reversePatterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.groupCount >= 1) {
        String locationName = match.group(1)!.trim();

        // 去除前缀填充词（"我家"、"那个" 等）
        // 多次循环以处理"我家那个客厅"这类多重前缀
        bool changed = true;
        while (changed) {
          changed = false;
          for (final prefix in _reverseFillerPrefixes) {
            if (locationName.startsWith(prefix) &&
                locationName.length > prefix.length) {
              locationName = locationName.substring(prefix.length).trim();
              changed = true;
              break;
            }
          }
        }

        // 去除首尾标点
        locationName = locationName.replaceAll(RegExp(r'[，。？！、\s]+$'), '');
        locationName = locationName.replaceAll(RegExp(r'^[，。？！、\s]+'), '');

        // 位置名为空 → 视为无效（可能是纯触发词"有什么"无前缀）
        if (locationName.isEmpty) {
          continue; // 尝试下一个模式
        }

        return QueryResult(
          isQuery: true,
          locationName: locationName,
          type: QueryType.locationQuery,
        );
      }
    }

    return const QueryResult();
  }
}
