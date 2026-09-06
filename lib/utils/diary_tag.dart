import 'package:flutter/material.dart';

/// 日记标注（tag）常量与色映射
///
/// 数据来源：diary 表 tag 列（TEXT，可空；NULL=无标注）。
/// 写方：悬浮窗展开卡底部按钮条的标注行（OverlayHome._setDiaryTag）；
/// 读方：悬浮窗卡片整卡换色（OverlayDiaryCard）+ 主 App 日记页小色点
///（diary_tab._buildNormalCard）——两侧共用本映射，改色只动这里
class DiaryTag {
  DiaryTag._();

  /// 紧急（!）
  static const String urgent = 'urgent';

  /// 收藏（⭐）
  static const String star = 'star';

  /// 灵感（💡）
  static const String idea = 'idea';

  /// tag → 标注色映射（悬浮窗整卡换色与主 App 小色点共用同一真值）
  static const Map<String, Color> colors = <String, Color>{
    urgent: Color(0xFFFF6B6B), // 红
    star: Color(0xFFFEA545), // 橙黄（纯黄 #FFD93D 与白字混色，2026-09-04 用户要求换）
    idea: Color(0xFFAE82E4), // 紫
  };

  /// 取标注色；tag 为 null 或未收录值时返回 null（= 无标注，用默认色）
  static Color? colorOf(String? tag) => tag == null ? null : colors[tag];

  /// 是否为合法标注值（CSV 导入等外部输入的校验用）
  static bool isValid(String? tag) => tag != null && colors.containsKey(tag);
}
