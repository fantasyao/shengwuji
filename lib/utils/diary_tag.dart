import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diary_sync_bridge.dart';

/// 日记标注（tag）常量、图标/颜色白名单与外观配置
///
/// 数据来源：diary 表 tag 列（TEXT，可空；NULL=无标注）。
/// 写方：悬浮窗展开卡时间行的标注按钮（OverlayHome._setDiaryTag）；
/// 读方：悬浮窗卡片整卡换色（OverlayDiaryCard）+ 主 App 日记页小色点与筛选行
///（diary_tab）——App 内共用 [DiaryTagStyles]。
/// 电脑访问网页由 diary_web_server 读取同一份 prefs 配置注入页面。
///
/// 4 个槽位固定（urgent/star/idea/task），只允许改图标与颜色，不提供改名：
/// 稳定 id 让 CSV/云同步/旧数据零迁移，显示层可自由换肤。
class DiaryTag {
  DiaryTag._();

  /// 槽位 1（默认：重要/紧急）
  static const String urgent = 'urgent';

  /// 槽位 2（默认：收藏）
  static const String star = 'star';

  /// 槽位 3（默认：灵感）
  static const String idea = 'idea';

  /// 槽位 4（2026-10-22 新增；默认：待办）
  static const String task = 'task';

  /// 槽位顺序 = 悬浮窗时间行按钮顺序 = 随手记筛选行顺序
  static const List<String> tagIds = <String>[urgent, star, idea, task];

  /// 「普通」（无标注）筛选哨兵：仅日记页标注筛选行使用，**不落库**——
  /// 库里无标注就是 tag IS NULL，此值只做"筛选无标注"的 UI/SQL 传话。
  /// 取值用不可能与真实标注撞车的串（isValid 对它返回 false，CSV 导入
  /// 校验天然拒绝）
  static const String filterNormal = '__untagged__';

  /// 「普通」档的显示色 = 悬浮窗无标注卡片默认蓝（与 overlay_constants
  /// defaultCardColor #6F9AF0 同源，悬浮窗改默认色时此处需同步决策）。
  /// 「普通」不是可配置槽位——它是无标注状态，不参与换肤
  static const Color normalColor = Color(0xFF6F9AF0);

  /// 取当前槽位外观；tag 为 null / 哨兵 / 未知值返回 null
  static DiaryTagStyle? styleOf(String? tag) =>
      isValid(tag) ? DiaryTagStyles.config.styleOf(tag!) : null;

  /// 取标注色；tag 为 null 或未收录值时返回 null（= 无标注，用默认色）。
  /// 筛选哨兵 filterNormal 返回 normalColor（筛选图标色点用）
  static Color? colorOf(String? tag) => tag == filterNormal
      ? normalColor
      : (styleOf(tag)?.color);

  /// 取标注图标；tag 为 null / 非法值返回 null
  static IconData? iconOf(String? tag) => styleOf(tag)?.icon;

  /// 是否为合法标注值（CSV 导入等外部输入的校验用）
  static bool isValid(String? tag) => tag != null && tagIds.contains(tag);
}

/// 图标白名单的一项。id 是落盘标识（prefs / 备份），改 id 会丢用户配置；
/// 换图标只改 icon，不动 id
@immutable
class DiaryTagIcon {
  const DiaryTagIcon({required this.id, required this.icon});

  final String id;
  final IconData icon;
}

/// 可选图标集合（2026-10-22 用户定夺「精选 20 个左右，覆盖工作/生活/灵感/出行」）
///
/// ⚠️ 必须保持 const IconData：Flutter 按实际引用的 const 图标裁剪图标字体，
/// 动态 IconData 不会被裁进去。网页端用同一批图标的 codePoint + 内置
/// MaterialIcons 字体渲染，增删图标时网页端无需改代码
const List<DiaryTagIcon> kTagIconChoices = <DiaryTagIcon>[
  DiaryTagIcon(id: 'urgent', icon: Icons.priority_high),
  DiaryTagIcon(id: 'star', icon: Icons.star_rounded),
  DiaryTagIcon(id: 'idea', icon: Icons.lightbulb_outline),
  DiaryTagIcon(id: 'task', icon: Icons.task_alt),
  DiaryTagIcon(id: 'work', icon: Icons.work_outline),
  DiaryTagIcon(id: 'calendar', icon: Icons.event_outlined),
  DiaryTagIcon(id: 'mail', icon: Icons.mail_outline),
  DiaryTagIcon(id: 'phone', icon: Icons.call_outlined),
  DiaryTagIcon(id: 'home', icon: Icons.home_outlined),
  DiaryTagIcon(id: 'heart', icon: Icons.favorite_border),
  DiaryTagIcon(id: 'coffee', icon: Icons.local_cafe_outlined),
  DiaryTagIcon(id: 'food', icon: Icons.restaurant_outlined),
  DiaryTagIcon(id: 'cart', icon: Icons.shopping_cart_outlined),
  DiaryTagIcon(id: 'money', icon: Icons.savings_outlined),
  DiaryTagIcon(id: 'fitness', icon: Icons.fitness_center),
  DiaryTagIcon(id: 'health', icon: Icons.health_and_safety_outlined),
  DiaryTagIcon(id: 'study', icon: Icons.school_outlined),
  DiaryTagIcon(id: 'book', icon: Icons.menu_book_outlined),
  DiaryTagIcon(id: 'pet', icon: Icons.pets),
  DiaryTagIcon(id: 'celebrate', icon: Icons.celebration_outlined),
  DiaryTagIcon(id: 'flight', icon: Icons.flight_takeoff),
  DiaryTagIcon(id: 'car', icon: Icons.directions_car_outlined),
  DiaryTagIcon(id: 'place', icon: Icons.place_outlined),
  DiaryTagIcon(id: 'camera', icon: Icons.photo_camera_outlined),
];

class DiaryTagIcons {
  DiaryTagIcons._();

  static DiaryTagIcon? byId(String id) => _byId[id];

  static IconData iconOf(String id) => _byId[id]?.icon ?? Icons.label_outline;

  static bool exists(String id) => _byId.containsKey(id);

  static final Map<String, DiaryTagIcon> _byId = <String, DiaryTagIcon>{
    for (final choice in kTagIconChoices) choice.id: choice,
  };
}

/// 可选颜色（10 个）。前三个是历史三色，保证用户能换回原视觉；
/// 其余覆盖绿/青/蓝/靛/粉/灰蓝。卡片是整卡背景 + 白字，选色偏中深，
/// 避免浅色底白字看不清
const List<Color> kTagColorChoices = <Color>[
  Color(0xFFFF6B6B), // 红（历史紧急）
  Color(0xFFFEA545), // 橙（历史收藏）
  Color(0xFFD99A1B), // 琥珀
  Color(0xFF2E9F5C), // 绿（默认待办）
  Color(0xFF168C8C), // 青
  Color(0xFF6F9AF0), // 蓝（卡片默认色）
  Color(0xFF5B5BC9), // 靛
  Color(0xFFAE82E4), // 紫（历史灵感）
  Color(0xFFD4548C), // 粉
  Color(0xFF5C6B7A), // 灰蓝
];

/// 单个槽位的外观
@immutable
class DiaryTagStyle {
  const DiaryTagStyle({
    required this.tag,
    required this.iconId,
    required this.color,
  });

  final String tag;
  final String iconId;
  final Color color;

  IconData get icon => DiaryTagIcons.iconOf(iconId);

  DiaryTagStyle copyWith({String? iconId, Color? color}) => DiaryTagStyle(
    tag: tag,
    iconId: iconId ?? this.iconId,
    color: color ?? this.color,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'tag': tag,
    'icon': iconId,
    'color': color.toARGB32(),
  };

  @override
  bool operator ==(Object other) =>
      other is DiaryTagStyle &&
      other.tag == tag &&
      other.iconId == iconId &&
      other.color == color;

  @override
  int get hashCode => Object.hash(tag, iconId, color);
}

const List<DiaryTagStyle> kDefaultTagStyles = <DiaryTagStyle>[
  DiaryTagStyle(
    tag: DiaryTag.urgent,
    iconId: 'urgent',
    color: Color(0xFFFF6B6B),
  ),
  DiaryTagStyle(tag: DiaryTag.star, iconId: 'star', color: Color(0xFFFEA545)),
  DiaryTagStyle(tag: DiaryTag.idea, iconId: 'idea', color: Color(0xFFAE82E4)),
  DiaryTagStyle(tag: DiaryTag.task, iconId: 'task', color: Color(0xFF2E9F5C)),
];

DiaryTagStyle kDefaultTagStyle(String tag) {
  for (final style in kDefaultTagStyles) {
    if (style.tag == tag) return style;
  }
  return kDefaultTagStyles.first;
}

/// 4 槽位外观配置（不可变；解析/序列化只认 [DiaryTag.tagIds]）
///
/// 容错策略：单个槽位坏值（未知图标/颜色类型错误）回退该槽位默认值；
/// 整体 JSON 坏掉回退全默认。缺槽位自动补默认，保证 UI 恒有 4 项
@immutable
class DiaryTagStyleConfig {
  const DiaryTagStyleConfig._(this._byTag);

  final Map<String, DiaryTagStyle> _byTag;

  static final DiaryTagStyleConfig defaults = DiaryTagStyleConfig._(
    Map<String, DiaryTagStyle>.unmodifiable(<String, DiaryTagStyle>{
      for (final style in kDefaultTagStyles) style.tag: style,
    }),
  );

  List<DiaryTagStyle> get styles =>
      <DiaryTagStyle>[for (final tag in DiaryTag.tagIds) styleOf(tag)];

  DiaryTagStyle styleOf(String tag) =>
      _byTag[tag] ?? kDefaultTagStyle(tag);

  Color? colorOf(String? tag) {
    if (tag == null) return null;
    return _byTag[tag]?.color;
  }

  IconData? iconOf(String? tag) {
    if (tag == null) return null;
    return _byTag[tag]?.icon;
  }

  /// 替换一个槽位，返回新配置（页面/测试共用）
  DiaryTagStyleConfig replace(DiaryTagStyle style) {
    if (!DiaryTag.isValid(style.tag)) return this;
    final next = Map<String, DiaryTagStyle>.from(_byTag)..[style.tag] = style;
    return DiaryTagStyleConfig._(
      Map<String, DiaryTagStyle>.unmodifiable(next),
    );
  }

  String encode() =>
      jsonEncode(<Map<String, Object?>>[for (final s in styles) s.toJson()]);

  /// 宽松解析：坏项跳过、缺项补默认；整串不可解析时返回全默认
  static DiaryTagStyleConfig parse(String? raw) =>
      tryParse(raw) ?? defaults;

  /// 严格解析：无内容 / JSON 坏 / 一个合法槽位都没有 → null。
  /// 备份导入用——老备份没有配置文件时保持本机现值，不回落默认
  static DiaryTagStyleConfig? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final parsed = <String, DiaryTagStyle>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final tag = item['tag'];
        final iconId = item['icon'];
        final colorValue = item['color'];
        if (tag is! String || !DiaryTag.isValid(tag)) continue;
        if (iconId is! String || !DiaryTagIcons.exists(iconId)) continue;
        if (colorValue is! int) continue;
        // 备份/旧版本可能写入带透明或越界的值：强制不透明并截 32 位，
        // 避免坏值让整卡背景变透明/抛异常
        final argb = (colorValue & 0xFFFFFFFF) | 0xFF000000;
        parsed[tag] = DiaryTagStyle(
          tag: tag,
          iconId: iconId,
          color: Color(argb),
        );
      }
      if (parsed.isEmpty) return null;
      for (final tag in DiaryTag.tagIds) {
        parsed.putIfAbsent(tag, () => kDefaultTagStyle(tag));
      }
      return DiaryTagStyleConfig._(
        Map<String, DiaryTagStyle>.unmodifiable(parsed),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DiaryTagStyleConfig && mapEquals(other._byTag, _byTag);

  @override
  int get hashCode => Object.hashAll(<Object?>[
    for (final tag in DiaryTag.tagIds) _byTag[tag],
  ]);
}

/// 外观配置的跨页读写入口
///
/// 主 App 内设置页保存后 [notifier] 立即通知日记页重绘；悬浮窗是独立
/// engine，靠 [_refreshOverlayConfig] 在展开前 reload prefs 读取；网页端在
/// 每次拉列表时读 prefs。配置只在本机 prefs，随全量备份 ZIP
///（tag_config.json）走，不参与云同步（用户明确暂不做 WebDAV）。
class DiaryTagStyles {
  DiaryTagStyles._();

  static const String prefsKey = 'diary_tag_styles_v1';

  static final ValueNotifier<DiaryTagStyleConfig> notifier =
      ValueNotifier<DiaryTagStyleConfig>(DiaryTagStyleConfig.defaults);

  static DiaryTagStyleConfig get config => notifier.value;

  static Future<DiaryTagStyleConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return loadFromPrefs(prefs);
  }

  /// 调用方已 reload 过 prefs 时用这个（悬浮窗 _refreshOverlayConfig）
  static DiaryTagStyleConfig loadFromPrefs(SharedPreferences prefs) {
    final config = DiaryTagStyleConfig.parse(
      prefs.getString(prefsKey),
    );
    notifier.value = config;
    return config;
  }

  static Future<void> save(DiaryTagStyleConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setString(prefsKey, config.encode());
    notifier.value = config;
    // 悬浮窗 engine 不共享内存，靠计数桥提示"有变更"（它展开时会重读配置）
    await DiarySyncBridge.bump();
  }

  @visibleForTesting
  static void resetForTest() {
    notifier.value = DiaryTagStyleConfig.defaults;
  }
}
