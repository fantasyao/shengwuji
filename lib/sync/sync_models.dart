import 'dart:convert';

import 'package:path/path.dart' as p;

/// 云同步数据载荷模型与编解码（lib/sync）。
///
/// 云端目录固定五个文件（见 docs/architecture/cloud-sync.md）：
/// manifest.json + diary.json + items.json + hotwords.txt + correction_pairs.json。
/// 本文件只做「本地 DB 行 ↔ 云端 JSON」的无损转换，合并裁决在 sync_merge.dart，
/// 编排在 cloud_sync_service.dart。

/// 一条日记的同步载荷。audio 只存文件名（basename）：录音本体走独立开关
/// 同步（cloud_sync_page「同步录音文件」，见 docs/architecture/cloud-sync.md），
/// 开关关闭/文件未到时只传名字，开启后按名补传
class DiarySyncEntry {
  const DiarySyncEntry({
    required this.uuid,
    required this.content,
    required this.createdAt,
    this.audioName,
    this.duration,
    this.isArchived = false,
    this.isLocked = false,
    this.tag,
  });

  final String uuid;
  final String content;
  final String createdAt;

  /// 录音文件名（无路径），无录音为 null
  final String? audioName;
  final int? duration;
  final bool isArchived;

  /// 用户手动锁定的笔记（is_locked 列）。仅随「新插入行」跨端传播
  /// （合并只做新增并集，已有行的锁定状态不跨端同步）
  final bool isLocked;

  /// 标注（'urgent'/'star'/'idea'，null=无）
  final String? tag;

  /// 本地 diary 表行 → 载荷（audio_path 全路径取 basename）
  factory DiarySyncEntry.fromRow(Map<String, dynamic> row) {
    final audioPath = row['audio_path'] as String?;
    return DiarySyncEntry(
      uuid: (row['sync_uuid'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      createdAt: (row['created_at'] as String?) ?? '',
      audioName: (audioPath == null || audioPath.isEmpty)
          ? null
          : p.basename(audioPath),
      duration: row['duration'] as int?,
      isArchived: (row['is_archived'] as int? ?? 0) != 0,
      isLocked: (row['is_locked'] as int? ?? 0) != 0,
      tag: row['tag'] as String?,
    );
  }

  /// 载荷 → 本地表行（云端下载落库用；audio_path 恒为 null，见类注释）
  Map<String, dynamic> toRow() => {
    'sync_uuid': uuid,
    'content': content,
    'created_at': createdAt,
    'duration': duration,
    'is_archived': isArchived ? 1 : 0,
    'is_locked': isLocked ? 1 : 0,
    'tag': tag,
  };

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'content': content,
    'created_at': createdAt,
    if (audioName != null) 'audio': audioName,
    if (duration != null) 'duration': duration,
    if (isArchived) 'archived': 1,
    if (isLocked) 'locked': 1,
    if (tag != null) 'tag': tag,
  };

  static DiarySyncEntry fromJson(Map<String, dynamic> j) => DiarySyncEntry(
    uuid: (j['uuid'] as String?) ?? '',
    content: (j['content'] as String?) ?? '',
    createdAt: (j['created_at'] as String?) ?? '',
    audioName: j['audio'] as String?,
    duration: (j['duration'] as num?)?.toInt(),
    isArchived: j['archived'] == 1,
    isLocked: j['locked'] == 1,
    tag: j['tag'] as String?,
  );
}

/// 一条物品记录的同步载荷（name+location 即业务全量）
class ItemSyncEntry {
  const ItemSyncEntry({
    required this.uuid,
    required this.name,
    required this.location,
  });

  final String uuid;
  final String name;
  final String location;

  factory ItemSyncEntry.fromRow(Map<String, dynamic> row) => ItemSyncEntry(
    uuid: (row['sync_uuid'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    location: (row['location'] as String?) ?? '',
  );

  Map<String, dynamic> toRow() => {
    'sync_uuid': uuid,
    'name': name,
    'location': location,
  };

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'name': name,
    'location': location,
  };

  static ItemSyncEntry fromJson(Map<String, dynamic> j) => ItemSyncEntry(
    uuid: (j['uuid'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    location: (j['location'] as String?) ?? '',
  );
}

/// 一条修正对的同步载荷（含学习计数与时间，行级合并裁决用）
class PairSyncEntry {
  const PairSyncEntry({
    required this.error,
    required this.correct,
    this.hitCount = 1,
    this.createdAt,
    this.lastUsedAt,
  });

  final String error;
  final String correct;
  final int hitCount;
  final String? createdAt;
  final String? lastUsedAt;

  /// 本地 correction_pairs 表原始行 → 载荷
  factory PairSyncEntry.fromRow(Map<String, dynamic> row) => PairSyncEntry(
    error: (row['error_text'] as String?) ?? '',
    correct: (row['corrected_text'] as String?) ?? '',
    hitCount: (row['hit_count'] as int?) ?? 1,
    createdAt: row['created_at'] as String?,
    lastUsedAt: row['last_used_at'] as String?,
  );

  /// 载荷 → mergeRemoteCorrectionPairs 入参行
  Map<String, dynamic> toDbRow() => {
    'error_text': error,
    'corrected_text': correct,
    'hit_count': hitCount,
    'created_at': createdAt,
    'last_used_at': lastUsedAt,
  };

  Map<String, dynamic> toJson() => {
    'error': error,
    'correct': correct,
    'hit_count': hitCount,
    if (createdAt != null) 'created_at': createdAt,
    if (lastUsedAt != null) 'last_used_at': lastUsedAt,
  };

  static PairSyncEntry fromJson(Map<String, dynamic> j) => PairSyncEntry(
    error: (j['error'] as String?) ?? '',
    correct: (j['correct'] as String?) ?? '',
    hitCount: (j['hit_count'] as num?)?.toInt() ?? 1,
    createdAt: j['created_at'] as String?,
    lastUsedAt: j['last_used_at'] as String?,
  );
}

// ==================== 四类数据文件编解码 ====================
// 解码一律宽容：字段缺失/类型不对给默认值，坏行跳过不抛——云端文件可能
// 被其他（未来版本的）客户端写入，同步失败不能整包拒收

String encodeDiaryEntries(List<Map<String, dynamic>> rows) =>
    jsonEncode(rows.map(DiarySyncEntry.fromRow).map((e) => e.toJson()).toList());

List<DiarySyncEntry> decodeDiaryEntries(String raw) {
  final list = _decodeList(raw);
  return [
    for (final j in list)
      if (j is Map<String, dynamic> &&
          ((j['uuid'] as String?) ?? '').isNotEmpty)
        DiarySyncEntry.fromJson(j),
  ];
}

String encodeItemEntries(List<Map<String, dynamic>> rows) =>
    jsonEncode(rows.map(ItemSyncEntry.fromRow).map((e) => e.toJson()).toList());

List<ItemSyncEntry> decodeItemEntries(String raw) {
  final list = _decodeList(raw);
  return [
    for (final j in list)
      if (j is Map<String, dynamic> &&
          ((j['uuid'] as String?) ?? '').isNotEmpty)
        ItemSyncEntry.fromJson(j),
  ];
}

String encodePairRows(List<Map<String, dynamic>> rows) =>
    jsonEncode(rows.map(PairSyncEntry.fromRow).map((e) => e.toJson()).toList());

List<PairSyncEntry> decodePairEntries(String raw) {
  final list = _decodeList(raw);
  return [
    for (final j in list)
      if (j is Map<String, dynamic> &&
          ((j['error'] as String?) ?? '').isNotEmpty)
        PairSyncEntry.fromJson(j),
  ];
}

List<dynamic> _decodeList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded : const [];
  } catch (_) {
    return const [];
  }
}

/// 音频上传索引 audio_index.json 编解码：纯字符串数组（已确认上传到
/// 云端 audio/ 目录的文件名）。解码宽容：非字符串项跳过不抛
List<String> decodeStringList(String raw) => [
  for (final v in _decodeList(raw))
    if (v is String) v,
];

// ==================== manifest.json ====================

/// manifest 版本（载荷结构大改时递增，P1 恒为 1）
const int kSyncManifestVersion = 1;

/// 同步软锁：某设备开始同步时写入，结束后清 null。另一设备看到
/// 非本机且未超时的锁就跳过本次同步（WebDAV 无原子 test-and-set，
/// 极端并发下可能双写，软锁只防常规误并发）
class SyncLock {
  const SyncLock({required this.deviceId, required this.at});

  final String deviceId;
  final String at;

  /// 锁是否已超时失效（持锁设备中途崩溃会留下死锁，超时自动放行）
  bool isStale(DateTime now, {Duration timeout = const Duration(minutes: 10)}) {
    final t = DateTime.tryParse(at);
    if (t == null) return true;
    return now.difference(t) > timeout;
  }

  Map<String, dynamic> toJson() => {'device_id': deviceId, 'at': at};

  static SyncLock? fromJson(Map<String, dynamic> j) {
    final id = j['device_id'] as String?;
    final at = j['at'] as String?;
    if (id == null || at == null) return null;
    return SyncLock(deviceId: id, at: at);
  }
}

/// 云端清单：锁 + 最后同步者 + 各类数据条数（诊断用）
class SyncManifest {
  const SyncManifest({
    this.version = kSyncManifestVersion,
    this.deviceId,
    this.updatedAt,
    this.lock,
    this.counts = const {},
  });

  final int version;
  final String? deviceId;
  final String? updatedAt;
  final SyncLock? lock;
  final Map<String, int> counts;

  Map<String, dynamic> toJson() => {
    'v': version,
    if (deviceId != null) 'device_id': deviceId,
    if (updatedAt != null) 'updated_at': updatedAt,
    'lock': lock?.toJson(),
    'counts': counts,
  };

  static SyncManifest? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final counts = <String, int>{};
      final rawCounts = j['counts'];
      if (rawCounts is Map) {
        rawCounts.forEach((k, v) {
          if (v is num) counts[k.toString()] = v.toInt();
        });
      }
      final rawLock = j['lock'];
      return SyncManifest(
        version: (j['v'] as num?)?.toInt() ?? kSyncManifestVersion,
        deviceId: j['device_id'] as String?,
        updatedAt: j['updated_at'] as String?,
        lock: rawLock is Map<String, dynamic> ? SyncLock.fromJson(rawLock) : null,
        counts: counts,
      );
    } catch (_) {
      return null;
    }
  }
}
