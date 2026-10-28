/// 语音搜索指令检测器
///
/// 悬浮窗语音速记 / 按住说话（PTT）转写完成后，检测纠错后的文本是否为
/// 「搜索 xxx」指令——是则自动拉起浏览器搜索关键词（日记照常回填原文）。
/// 白名单前缀思路与清单提取的「代办/待办」触发词一致：必须先报上暗号才
/// 触发，正常说话永不误命中。
///
/// 测试用例（注释里列出，便于回归）：
///   - "搜索明天天气" → 命中, keyword="明天天气"
///   - "搜索一下明天天气" → 命中, keyword="明天天气"（不留「一下」残留）
///   - "搜一下附近的奶茶店" → 命中, keyword="附近的奶茶店"
///   - "我去搜索一下明天天气" → 不命中（触发词不在开头）
///   - "搜索" → 不命中（无关键词）
///   - "搜索一下，" → 不命中（剥离后为空）
///   - "搜索，明天天气怎么样？" → 命中, keyword="明天天气怎么样"（首尾标点清理）
library;

/// prefs key：「语音搜索跳转」开关（默认开）。
/// 写入方：设置页悬浮窗二级页 overlay_settings_page.dart；
/// 读取方：overlay engine 的 OverlayVoiceMemoController._transcribeAndSave
/// （跨 engine 读必须 prefs.reload()，项目惯例）
const kVoiceSearchJumpEnabledKey = 'voice_search_jump_enabled';

/// prefs key：触发词列表（String，换行分隔的规范化结果）。
/// 写入方：设置页悬浮窗二级页（保存前经 [SearchCommandDetector.normalize]）；
/// 读取方：overlay engine 转写收尾（reload 后经
/// [SearchCommandDetector.parseTriggers] 解析，空/非法回落默认白名单）。
/// 全量备份经 ZIP 内 voice_search_triggers.txt 导出/导入（settings_tab.dart）。
const kVoiceSearchTriggersKey = 'voice_search_triggers';

/// 默认触发词（先长后短：「搜索一下」必须先于「搜索」，否则
/// 「搜索一下 xxx」会被「搜索」截断留下「一下」残留）。
const kDefaultVoiceSearchTriggers = ['搜索一下', '搜索', '搜一下'];

class SearchCommandResult {
  final bool isSearchCommand;
  final String keyword; // 命中时提取的搜索关键词

  const SearchCommandResult({this.isSearchCommand = false, this.keyword = ''});
}

class SearchCommandDetector {
  SearchCommandDetector._(); // 纯工具类，禁止实例化

  /// 规范化触发词输入：按换行 / 英文逗号 / 中文逗号 / 顿号拆分，trim、
  /// 去空、去重，再按长度降序排列（先长后短）。全部为空时返回空列表，
  /// 由调用方决定兜底（设置页拒绝保存，读取侧回落默认）。
  static List<String> normalize(String raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final part in raw.split(RegExp(r'[\n\r,，、]'))) {
      final trigger = part.trim();
      if (trigger.isEmpty || !seen.add(trigger)) continue;
      out.add(trigger);
    }
    out.sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  /// 从 prefs 原始字符串解析触发词：空白/全部非法 → 默认白名单
  /// （旧版本没有该 key，天然走默认，行为不变）。
  static List<String> parseTriggers(String? raw) {
    final parsed = normalize(raw ?? '');
    return parsed.isEmpty ? kDefaultVoiceSearchTriggers : parsed;
  }

  /// 检测文本是否为搜索指令：trim 后严格以触发词开头，剥离触发词后
  /// 清理首尾空白与中英文标点，关键词非空才算命中。
  /// [triggers] 为空/未传时用默认白名单；传入时内部再按先长后短排序，
  /// 调用方不必保证顺序。
  static SearchCommandResult detect(
    String text, {
    List<String>? triggers,
  }) {
    final t = text.trim();
    if (t.isEmpty) return const SearchCommandResult();

    final list = (triggers == null || triggers.isEmpty)
        ? kDefaultVoiceSearchTriggers
        : ([...triggers]..sort((a, b) => b.length.compareTo(a.length)));

    for (final trigger in list) {
      if (trigger.isEmpty || !t.startsWith(trigger)) continue;
      var keyword = t.substring(trigger.length);
      // 防御：剥离开头残留的「一下」（先长后短的触发词顺序下本不会发生，
      // 钉住防默认触发词被调整顺序后静默回归）
      if (keyword.startsWith('一下')) {
        keyword = keyword.substring(2);
      }
      // 清理首尾空白与中英文标点（如「搜索，明天天气？」→「明天天气」）
      keyword = keyword.replaceAll(RegExp(r'^[，。！？、,.!?\s]+'), '');
      keyword = keyword.replaceAll(RegExp(r'[，。！？、,.!?\s]+$'), '');
      if (keyword.isEmpty) return const SearchCommandResult();
      return SearchCommandResult(isSearchCommand: true, keyword: keyword);
    }
    return const SearchCommandResult();
  }
}
