import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/diary_tag.dart';

/// 4 槽位标签外观配置（2026-10-22）：默认值、编解码往返、坏数据容错。
/// 配置随全量备份 tag_config.json 走，所以解析必须对老备份/坏值宽容
void main() {
  test('默认配置：4 槽位与默认图标/颜色一一对应', () {
    final config = DiaryTagStyleConfig.defaults;
    expect(config.styles.map((s) => s.tag), DiaryTag.tagIds);
    expect(config.styleOf(DiaryTag.urgent).color, const Color(0xFFFF6B6B));
    expect(config.styleOf(DiaryTag.star).color, const Color(0xFFFEA545));
    expect(config.styleOf(DiaryTag.idea).color, const Color(0xFFAE82E4));
    expect(config.styleOf(DiaryTag.task).icon, Icons.task_alt);
    expect(config.styleOf(DiaryTag.task).color, const Color(0xFF2E9F5C));
  });

  test('encode/parse 往返保真（含第 4 槽位）', () {
    final config = DiaryTagStyleConfig.defaults
        .replace(
          const DiaryTagStyle(
            tag: DiaryTag.idea,
            iconId: 'pet',
            color: Color(0xFF168C8C),
          ),
        )
        .replace(
          const DiaryTagStyle(
            tag: DiaryTag.task,
            iconId: 'flight',
            color: Color(0xFFD4548C),
          ),
        );
    final parsed = DiaryTagStyleConfig.parse(config.encode());
    expect(parsed, config);
    expect(parsed.styleOf(DiaryTag.idea).icon, Icons.pets);
    expect(parsed.styleOf(DiaryTag.task).icon, Icons.flight_takeoff);
  });

  test('tryParse：无内容 / 坏 JSON / 无合法槽位 → null（老备份保留本机配置）', () {
    expect(DiaryTagStyleConfig.tryParse(null), isNull);
    expect(DiaryTagStyleConfig.tryParse(''), isNull);
    expect(DiaryTagStyleConfig.tryParse('not json'), isNull);
    expect(DiaryTagStyleConfig.tryParse('{"a":1}'), isNull);
    expect(
      DiaryTagStyleConfig.tryParse(
        '[{"tag":"nope","icon":"star","color":1}]',
      ),
      isNull,
    );
  });

  test('parse 容错：未知图标项跳过、缺槽位补默认、颜色强制不透明', () {
    final raw = jsonEncode([
      {
        'tag': 'urgent',
        'icon': 'heart',
        'color': const Color(0xFF168C8C).withValues(alpha: 0.3).toARGB32(),
      },
      {'tag': 'star', 'icon': 'not_an_icon', 'color': 1},
    ]);
    final parsed = DiaryTagStyleConfig.parse(raw);
    expect(parsed.styleOf(DiaryTag.urgent).icon, Icons.favorite_border);
    // 半透明坏值被强制补成不透明
    expect(parsed.styleOf(DiaryTag.urgent).color, const Color(0xFF168C8C));
    // 未知图标 → 整项跳过 → 回该槽位默认
    expect(parsed.styleOf(DiaryTag.star), kDefaultTagStyle(DiaryTag.star));
    // 缺项自动补默认，UI 恒有 4 项
    expect(parsed.styleOf(DiaryTag.idea), kDefaultTagStyle(DiaryTag.idea));
    expect(parsed.styleOf(DiaryTag.task), kDefaultTagStyle(DiaryTag.task));
  });

  test('replace 拒绝非法 tag（返回原实例）', () {
    final base = DiaryTagStyleConfig.defaults;
    final next = base.replace(
      const DiaryTagStyle(
        tag: 'nope',
        iconId: 'star',
        color: Color(0xFF000000),
      ),
    );
    expect(identical(next, base), isTrue);
  });

  test('可选图标/颜色白名单：图标 id 唯一、颜色不透明', () {
    final ids = kTagIconChoices.map((c) => c.id).toSet();
    expect(ids.length, kTagIconChoices.length);
    // 4 个默认槽位图标必须在白名单里（否则默认配置会被解析器当坏值）
    for (final tag in DiaryTag.tagIds) {
      expect(DiaryTagIcons.exists(kDefaultTagStyle(tag).iconId), isTrue);
    }
    for (final color in kTagColorChoices) {
      expect(color.a, 1.0);
    }
  });
}
