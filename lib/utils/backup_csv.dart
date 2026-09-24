import 'package:path/path.dart' as p;

import 'diary_tag.dart';

/// 全量备份 items.csv / diary.csv 的编解码（纯函数，无 IO，单元测试覆盖
/// test/backup_csv_test.dart）。导出/导入共用同一套生成与解析，保证
/// 「导出 → 原封不动导入」不产生重复行、不丢状态。
///
/// 2026-09 往返导入修复（两个缺陷叠加导致整包判新，用户复现：A 活跃 +
/// B/C 归档，导出再原封导入后出现 A、A、B、C 四条活跃 + B/C 归档）：
/// - created_at 原先导出时被 DateFormat 重排成 'yyyy-MM-dd HH:mm:ss'
///   （空格分隔 + 丢毫秒），与库内 toIso8601String() 原串（T 分隔 + 亚秒）
///   逐字比对永不相等 → 导入去重键 content|created_at 全部漏判 → 整包
///   重复插入。现在导出直接写库内原串，导入经 normalizeCreatedAt 归一化。
/// - CSV 原先不含归档列，导入行落库走 DDL 默认 is_archived=0，归档笔记
///   恢复后全部复活成活跃。新增「归档」列放最后：旧版本 App 解析只读
///   前几列，天然兼容（与 v10 标注列同策略）。
/// - 去重键 diaryDedupeKey 对齐到秒：老备份的毫秒在导出时已不可恢复，
///   秒级对齐让新旧备份的往返导入都能命中去重。

// 生成物品CSV
String generateItemsCsv(List<Map<String, dynamic>> items) {
  final rows = [
    ['物品', '位置'],
  ];
  for (var item in items) {
    rows.add([
      escapeCsvField(item['name']?.toString() ?? ''),
      escapeCsvField(item['location']?.toString() ?? ''),
    ]);
  }
  return rows.map((row) => row.join(',')).join('\n');
}

// 生成日记CSV
String generateDiaryCsv(List<Map<String, dynamic>> diaries) {
  final rows = [
    // 标注列（v10）/ 归档列（2026-09）均放最后：旧版本 App 解析只读前几列，天然兼容
    ['ID', '内容', '创建时间', '音频文件', '时长(秒)', '标注', '归档'],
  ];
  for (var diary in diaries) {
    rows.add([
      diary['id']?.toString() ?? '',
      escapeCsvField(diary['content']?.toString() ?? ''),
      // 创建时间写库内原串（含亚秒）：它是导入去重自然键的一半，任何重排版
      // 都会让「导出→原封导入」整包判新（见文件头 2026-09 修复注释）
      diary['created_at']?.toString() ?? '',
      diary['audio_path'] != null
          ? p.basename(diary['audio_path'].toString())
          : '',
      diary['duration']?.toString() ?? '',
      // 标注（'urgent'/'star'/'idea'），无标注导出为空串
      diary['tag']?.toString() ?? '',
      // 归档位（'1'/'0'）：随备份走，换机恢复才能保持归档区不变
      diary['is_archived']?.toString() ?? '0',
    ]);
  }
  return rows.map((row) => row.join(',')).join('\n');
}

// CSV字段转义
String escapeCsvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

// 解析items.csv
List<Map<String, String>> parseItemsCsv(String csvContent) {
  final records = splitCsvRecords(csvContent);
  final items = <Map<String, String>>[];

  for (var i = 1; i < records.length; i++) {
    // 跳过表头
    final line = records[i].trim();
    if (line.isEmpty) continue;

    final parts = parseCsvLine(line);
    if (parts.length >= 2) {
      items.add({'name': parts[0], 'location': parts[1]});
    }
  }
  return items;
}

// 解析diary.csv
List<Map<String, dynamic>> parseDiaryCsv(String csvContent) {
  final records = splitCsvRecords(csvContent);
  final diaries = <Map<String, dynamic>>[];

  for (var i = 1; i < records.length; i++) {
    // 跳过表头
    final line = records[i].trim();
    if (line.isEmpty) continue;

    final parts = parseCsvLine(line);
    if (parts.length >= 5) {
      final audioPath = parts[3].isNotEmpty ? parts[3] : null;
      diaries.add({
        'id': int.tryParse(parts[0]),
        'content': parts[1],
        'created_at': normalizeCreatedAt(parts[2]),
        'audio_path': audioPath,
        'duration': parts[4].isNotEmpty ? int.tryParse(parts[4]) : null,
        // 标注列（v10 新增，放最后）：旧备份没有第 6 列 → 容忍缺列置 null；
        // 有列但值非法（非 urgent/star/idea）同样按无标注处理
        'tag': parts.length > 5 && DiaryTag.isValid(parts[5])
            ? parts[5]
            : null,
        // 归档列（2026-09 新增，放最后）：旧备份没有第 7 列 → 容忍缺列按活跃处理
        'is_archived': parts.length > 6 && parts[6].trim() == '1' ? 1 : 0,
      });
    }
  }
  return diaries;
}

// 解析CSV行（支持引号转义）
List<String> parseCsvLine(String line) {
  final result = <String>[];
  String current = '';
  bool inQuotes = false;

  for (int i = 0; i < line.length; i++) {
    final char = line[i];

    if (char == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        current += '"';
        i++; // 跳过下一个引号
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char == ',' && !inQuotes) {
      result.add(current);
      current = '';
    } else {
      current += char;
    }
  }
  result.add(current);
  return result;
}

/// 按 CSV 记录切分：引号内的换行属于字段内容而非行边界。
/// 原先按 '\n' 裸切，含换行的日记内容往返导入会被腰斩（后半段缺列被丢弃）
List<String> splitCsvRecords(String csvContent) {
  final records = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < csvContent.length; i++) {
    final char = csvContent[i];
    if (char == '"') {
      inQuotes = !inQuotes;
      current.write(char);
    } else if (char == '\n' && !inQuotes) {
      records.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  if (current.isNotEmpty) records.add(current.toString());
  return records;
}

/// 库内 created_at 统一为 toIso8601String() 形态（T 分隔 + 亚秒）。
/// 老备份（2026-09 之前）导出时被格式化成 'yyyy-MM-dd HH:mm:ss'，原样入库
/// 会让库内并存两种格式：created_at DESC 排序错乱 + 自然键比对失配；
/// 能解析就转回 ISO，解析失败（异常数据）原样返回不抛
String normalizeCreatedAt(String raw) {
  final dt = DateTime.tryParse(raw);
  return dt?.toIso8601String() ?? raw;
}

/// 日记导入去重自然键：content + 归一化到秒的创建时间。
/// 截到秒：老备份的毫秒在导出时已丢（见 normalizeCreatedAt），逐字比对
/// 永不相等（2026-09 整包判新的根源）；秒级对齐后新旧备份往返都能命中。
/// 代价：同内容且同秒的两条会被并成一条，真实使用近乎不可能
String diaryDedupeKey(String content, String createdAt) {
  final dt = DateTime.tryParse(createdAt);
  final ts = dt == null
      ? createdAt
      : (dt.millisecondsSinceEpoch ~/ 1000).toString();
  return '$content|$ts';
}
