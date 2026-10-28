import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 云同步 v2 协议（与电脑端 `shengwuji_desktop/lib/sync` 同一份契约）。
///
/// v1 的 diary.json 只做「新增并集」，手机端 P1 无法传播编辑/删除；v2 用
/// `v2/notes.json`（带 updated_at）+ `v2/tombstones.json` 做三方合并：
/// - 基线哈希（上次成功同步的载荷指纹）+ LWW 判断谁改过
/// - 墓碑传播删除，晚于墓碑的编辑允许复活
/// - 未知字段/附件/标签原样透传，手机写回时不能丢掉电脑端数据
///
/// 本文件只做编解码与数据模型（纯函数，单测覆盖 test/sync_v2_test.dart）；
/// 裁决在 sync_v2_merge.dart，编排在 cloud_sync_service.dart。

const int kV2ProtocolVersion = 2;
const int kV2MinReaderVersion = 2;

/// 双方都改过且时间相差不超过 5 分钟时给输家留冲突副本（与电脑端一致）
const Duration kV2ConflictWindow = Duration(minutes: 5);

// ==================== 时间工具 ====================

/// v2 协议时间：UTC、带 `Z`
String formatUtcIso(int milliseconds) => DateTime.fromMillisecondsSinceEpoch(
  milliseconds,
  isUtc: true,
).toIso8601String();

/// 手机本地展示/落库时间：本地时间、无 `Z`（与既有 created_at 逐字一致）
String formatLocalIso(int milliseconds) =>
    DateTime.fromMillisecondsSinceEpoch(milliseconds).toIso8601String();

/// 任意 ISO 字符串 → UTC 毫秒；空/坏值返回 null
int? parseIsoMillis(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value.trim())?.toUtc().millisecondsSinceEpoch;
}

// ==================== v2 笔记 ====================

class V2Attachment {
  const V2Attachment({
    required this.uuid,
    required this.kind,
    this.origin = 'download',
    this.sha256,
    this.name,
    this.mimeType,
    this.byteSize,
    this.durationMs,
    this.sortOrder = 0,
    this.rev = 1,
    this.extras = const {},
  });

  final String uuid;
  final String kind;
  final String origin;
  final String? sha256;

  /// 展示名 / 远端文件名（basename）
  final String? name;
  final String? mimeType;
  final int? byteSize;
  final int? durationMs;
  final int sortOrder;
  final int rev;

  /// 协议不认识的附件字段，原样带回
  final Map<String, dynamic> extras;

  bool get isAudio => kind == 'audio';

  bool get isImage => kind == 'image';

  /// 与电脑端 SyncNote.payloadHash 一致的附件指纹：音频按文件名（下载后
  /// 回填的 sha 不算变化），其它按内容哈希
  String get payloadKey {
    if (isAudio && name != null && name!.isNotEmpty) return 'audio:$name';
    return '$kind:${sha256 ?? name ?? ''}';
  }

  static const Set<String> _knownKeys = {
    'uuid',
    'kind',
    'origin',
    'sha256',
    'name',
    'sync_name',
    'mime',
    'mime_type',
    'size',
    'byte_size',
    'duration_ms',
    'sort_order',
    'rev',
    'extras',
  };

  factory V2Attachment.fromRaw(Map<String, dynamic> raw) {
    final uuid = (raw['uuid'] as String?)?.trim() ?? '';
    final extras = <String, dynamic>{};
    final rawExtras = raw['extras'];
    if (rawExtras is Map) {
      rawExtras.forEach((key, value) {
        extras[key.toString()] = value;
      });
    }
    for (final entry in raw.entries) {
      if (_knownKeys.contains(entry.key)) continue;
      extras[entry.key] = entry.value;
    }
    final name = raw['name'] ?? raw['sync_name'];
    final sha = raw['sha256'];
    return V2Attachment(
      uuid: uuid,
      kind: raw['kind'] is String ? raw['kind'] as String : 'file',
      origin: raw['origin'] is String ? raw['origin'] as String : 'download',
      sha256: sha is String && sha.isNotEmpty ? sha : null,
      name: name is String && name.isNotEmpty ? name : null,
      mimeType: raw['mime'] is String
          ? raw['mime'] as String
          : raw['mime_type'] is String
          ? raw['mime_type'] as String
          : null,
      byteSize: raw['size'] is num
          ? (raw['size'] as num).toInt()
          : raw['byte_size'] is num
          ? (raw['byte_size'] as num).toInt()
          : null,
      durationMs: raw['duration_ms'] is num
          ? (raw['duration_ms'] as num).toInt()
          : null,
      sortOrder: raw['sort_order'] is num
          ? (raw['sort_order'] as num).toInt()
          : 0,
      rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 1,
      extras: extras,
    );
  }

  V2Attachment copyWith({
    String? uuid,
    String? name,
    int? durationMs,
    String? mimeType,
    String? origin,
  }) {
    return V2Attachment(
      uuid: uuid ?? this.uuid,
      kind: kind,
      origin: origin ?? this.origin,
      sha256: sha256,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      byteSize: byteSize,
      durationMs: durationMs ?? this.durationMs,
      sortOrder: sortOrder,
      rev: rev,
      extras: extras,
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'kind': kind,
    'origin': origin,
    'sha256': sha256,
    'name': name,
    'mime': mimeType,
    'size': byteSize,
    'duration_ms': durationMs,
    'sort_order': sortOrder,
    'rev': rev,
    'extras': extras,
  };
}

class V2Note {
  V2Note({
    required this.uuid,
    required this.content,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.mark,
    this.archived = false,
    this.locked = false,
    this.sortOrder,
    this.rev = 1,
    this.tags = const [],
    this.attachments = const [],
    this.extras = const {},
  });

  final String uuid;
  final String content;
  final int createdAtMs;
  final int updatedAtMs;
  final String? mark;
  final bool archived;
  final bool locked;
  final int? sortOrder;
  final int rev;

  /// 电脑端用户标签 uuid 集合（手机端不解析，只透传）
  final List<dynamic> tags;

  /// 完整附件集合（手机端只管理音频，电脑端图片等原样透传）
  final List<V2Attachment> attachments;

  /// 协议不认识的字段
  final Map<String, dynamic> extras;

  /// 三方合并的载荷指纹（与电脑端 SyncNote.payloadHash 同算法）
  late final String payloadHash = _computePayloadHash();

  String _computePayloadHash() {
    final attachmentKeys = [for (final item in attachments) item.payloadKey]
      ..sort();
    final hashExtras = <String, dynamic>{...extras};
    if (tags.isNotEmpty) hashExtras['tags'] = tags;
    final extraKeys = hashExtras.keys.toList()..sort();
    final payload = jsonEncode([
      content,
      mark,
      archived,
      locked,
      sortOrder,
      attachmentKeys,
      [
        for (final key in extraKeys) [key, hashExtras[key]],
      ],
    ]);
    return sha256.convert(utf8.encode(payload)).toString();
  }

  String get naturalKey => '$content|$createdAtMs';

  V2Note copyWith({
    String? uuid,
    int? updatedAtMs,
    bool? archived,
    int? rev,
    Map<String, dynamic>? extras,
    List<V2Attachment>? attachments,
  }) {
    return V2Note(
      uuid: uuid ?? this.uuid,
      content: content,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      mark: mark,
      archived: archived ?? this.archived,
      locked: locked,
      sortOrder: sortOrder,
      rev: rev ?? this.rev,
      tags: tags,
      attachments: attachments ?? this.attachments,
      extras: extras ?? this.extras,
    );
  }

  static const Set<String> _knownKeys = {
    'uuid',
    'content',
    'created_at',
    'updated_at',
    'rev',
    'mark',
    'archived',
    'locked',
    'sort_order',
    'tags',
    'attachments',
    'extras',
  };

  /// 解析一条 v2 note；身份/正文/时间缺失返回 null（坏行跳过）
  static V2Note? fromRaw(Map<String, dynamic> raw) {
    final uuid = (raw['uuid'] as String?)?.trim() ?? '';
    final content = raw['content'];
    final createdAt = parseIsoMillis(raw['created_at']);
    final updatedAt = parseIsoMillis(raw['updated_at']) ?? createdAt;
    if (uuid.isEmpty || content is! String || createdAt == null) return null;
    if (updatedAt == null) return null;

    final extras = <String, dynamic>{};
    final rawExtras = raw['extras'];
    if (rawExtras is Map) {
      rawExtras.forEach((key, value) {
        extras[key.toString()] = value;
      });
    }
    for (final entry in raw.entries) {
      if (_knownKeys.contains(entry.key)) continue;
      extras[entry.key] = entry.value;
    }

    final tags = <dynamic>[];
    final rawTags = raw['tags'];
    if (rawTags is List && rawTags.isNotEmpty) {
      tags.addAll(rawTags);
    } else {
      final legacyTags = extras.remove('tags');
      if (legacyTags is List) tags.addAll(legacyTags);
    }

    final attachments = <V2Attachment>[];
    final rawAttachments = raw['attachments'];
    if (rawAttachments is List) {
      for (final item in rawAttachments) {
        if (item is! Map) continue;
        final map = item.map((key, value) => MapEntry(key.toString(), value));
        final attachment = V2Attachment.fromRaw(map);
        if (attachment.uuid.isEmpty) continue;
        attachments.add(attachment);
      }
    }

    // v1 的 audio / duration 并入附件（与电脑端 normalizeAudio 同语义）：
    // 两边只有一份事实，v1 投影时再从附件反写，下载后回填 sha 不影响指纹
    final rawAudio = extras.remove('audio');
    final rawDuration = extras.remove('duration');
    final audioName = rawAudio is String ? _safeBaseName(rawAudio) : '';
    final durationMs = _durationToMs(rawDuration);
    final audioIndex = attachments.indexWhere((item) => item.isAudio);
    if (audioIndex >= 0) {
      final current = attachments[audioIndex];
      final name =
          current.name ?? (audioName.isEmpty ? null : audioName);
      final duration = current.durationMs ?? durationMs;
      final mime = current.mimeType ?? _audioMimeType(name);
      if (name != current.name ||
          duration != current.durationMs ||
          mime != current.mimeType) {
        attachments[audioIndex] = current.copyWith(
          name: name,
          durationMs: duration,
          mimeType: mime,
        );
      }
    } else if (audioName.isNotEmpty) {
      attachments.add(
        V2Attachment(
          uuid: audioAttachmentUuid(uuid, audioName),
          kind: 'audio',
          origin: 'download',
          name: audioName,
          mimeType: _audioMimeType(audioName),
          durationMs: durationMs,
        ),
      );
    }

    return V2Note(
      uuid: uuid,
      content: content,
      createdAtMs: createdAt,
      updatedAtMs: updatedAt,
      mark: raw['mark'] is String ? raw['mark'] as String : null,
      archived: raw['archived'] == true || raw['archived'] == 1,
      locked: raw['locked'] == true || raw['locked'] == 1,
      sortOrder: raw['sort_order'] is num
          ? (raw['sort_order'] as num).toInt()
          : null,
      rev: raw['rev'] is num ? (raw['rev'] as num).toInt() : 1,
      tags: tags,
      attachments: attachments,
      extras: extras,
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'content': content,
    'created_at': formatUtcIso(createdAtMs),
    'updated_at': formatUtcIso(updatedAtMs),
    'rev': rev,
    'mark': mark,
    'archived': archived,
    'locked': locked,
    'sort_order': sortOrder,
    'tags': tags,
    'attachments': [for (final item in attachments) item.toJson()],
    'extras': extras,
  };
}

class V2NotesParseResult {
  const V2NotesParseResult({
    required this.notes,
    required this.skipped,
    this.topExtras = const {},
  });

  final List<V2Note> notes;
  final int skipped;

  /// notes.json 顶层的其它字段，写回时保留
  final Map<String, dynamic> topExtras;
}

/// 解析 v2/notes.json。文件不存在（null/空）返回空结果；顶层结构坏了抛
/// FormatException（调用方中止同步，绝不把坏文件当空快照覆盖）
V2NotesParseResult parseNotesV2(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const V2NotesParseResult(notes: [], skipped: 0);
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('v2/notes.json 顶层不是对象');
  }
  final map = decoded.map((key, value) => MapEntry(key.toString(), value));
  final rawNotes = map['notes'];
  if (rawNotes is! List) {
    throw const FormatException('v2/notes.json 缺少 notes 数组');
  }
  final notes = <V2Note>[];
  var skipped = 0;
  for (final item in rawNotes) {
    if (item is! Map) {
      skipped++;
      continue;
    }
    final note = V2Note.fromRaw(
      item.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (note == null) {
      skipped++;
      continue;
    }
    notes.add(note);
  }
  final topExtras = <String, dynamic>{
    for (final entry in map.entries)
      if (!const {'format', 'version', 'generated_at', 'device_id', 'notes'}
          .contains(entry.key))
        entry.key: entry.value,
  };
  return V2NotesParseResult(
    notes: notes,
    skipped: skipped,
    topExtras: topExtras,
  );
}

Map<String, dynamic> encodeNotesV2({
  required List<V2Note> notes,
  required Map<String, dynamic> topExtras,
  required String deviceId,
  required int nowMs,
}) {
  return {
    ...topExtras,
    'format': 'shengwuji.notes',
    'version': kV2ProtocolVersion,
    'generated_at': formatUtcIso(nowMs),
    'device_id': deviceId,
    'notes': [for (final note in notes) note.toJson()],
  };
}

// ==================== v2 墓碑 ====================

class V2Tombstone {
  const V2Tombstone({
    required this.uuid,
    required this.deletedAtMs,
    this.rev = 1,
    this.origin = 'local',
  });

  final String uuid;
  final int deletedAtMs;
  final int rev;
  final String origin;
}

class V2TombstonesParseResult {
  const V2TombstonesParseResult({
    required this.tombstones,
    required this.preservedRows,
    this.topExtras = const {},
  });

  final Map<String, V2Tombstone> tombstones;

  /// entity != 'note' 的其它条目（未来版本扩展），原样写回
  final List<Map<String, dynamic>> preservedRows;
  final Map<String, dynamic> topExtras;
}

V2TombstonesParseResult parseTombstonesV2(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const V2TombstonesParseResult(
      tombstones: {},
      preservedRows: [],
    );
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('v2/tombstones.json 顶层不是对象');
  }
  final map = decoded.map((key, value) => MapEntry(key.toString(), value));
  final rawTombstones = map['tombstones'];
  if (rawTombstones is! List) {
    return const V2TombstonesParseResult(
      tombstones: {},
      preservedRows: [],
    );
  }
  final tombstones = <String, V2Tombstone>{};
  final preserved = <Map<String, dynamic>>[];
  for (final item in rawTombstones) {
    if (item is! Map) continue;
    final row = item.map((key, value) => MapEntry(key.toString(), value));
    if (row['entity'] != 'note') {
      preserved.add(row);
      continue;
    }
    final uuid = (row['uuid'] as String?)?.trim() ?? '';
    final deletedAt = parseIsoMillis(row['deleted_at']);
    if (uuid.isEmpty || deletedAt == null) continue;
    tombstones[uuid] = V2Tombstone(
      uuid: uuid,
      deletedAtMs: deletedAt,
      rev: row['rev'] is num ? (row['rev'] as num).toInt() : 1,
      origin: row['origin'] is String ? row['origin'] as String : 'remote',
    );
  }
  final topExtras = <String, dynamic>{
    for (final entry in map.entries)
      if (!const {'format', 'version', 'generated_at', 'tombstones'}
          .contains(entry.key))
        entry.key: entry.value,
  };
  return V2TombstonesParseResult(
    tombstones: tombstones,
    preservedRows: preserved,
    topExtras: topExtras,
  );
}

Map<String, dynamic> encodeTombstonesV2({
  required Iterable<V2Tombstone> tombstones,
  required List<Map<String, dynamic>> preservedRows,
  required Map<String, dynamic> topExtras,
  required int nowMs,
}) {
  final sorted = List<V2Tombstone>.from(tombstones)
    ..sort((a, b) => a.uuid.compareTo(b.uuid));
  return {
    ...topExtras,
    'format': 'shengwuji.tombstones',
    'version': kV2ProtocolVersion,
    'generated_at': formatUtcIso(nowMs),
    'tombstones': [
      for (final row in preservedRows) row,
      for (final item in sorted)
        {
          'entity': 'note',
          'uuid': item.uuid,
          'deleted_at': formatUtcIso(item.deletedAtMs),
          'rev': item.rev,
          'origin': item.origin,
        },
    ],
  };
}

// ==================== v2 manifest ====================

class V2Manifest {
  const V2Manifest({
    required this.raw,
    required this.protocolVersion,
    required this.minReaderVersion,
    required this.writers,
  });

  final Map<String, dynamic> raw;
  final int protocolVersion;
  final int minReaderVersion;
  final Map<String, dynamic> writers;

  /// 文件不存在返回 null；结构坏了抛 FormatException（不猜规则）
  static V2Manifest? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('v2/manifest.json 顶层不是对象');
    }
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    return V2Manifest(
      raw: map,
      protocolVersion: map['protocol_version'] is num
          ? (map['protocol_version'] as num).toInt()
          : 1,
      minReaderVersion: map['min_reader_version'] is num
          ? (map['min_reader_version'] as num).toInt()
          : 1,
      writers: map['writers'] is Map
          ? (map['writers'] as Map)
                .map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{},
    );
  }

  /// 远端要求的最低读取版本高于本机支持 → 中止（绝不写入新命名空间）
  void ensureSupported() {
    if (protocolVersion > kV2ProtocolVersion ||
        minReaderVersion > kV2MinReaderVersion) {
      throw FormatException(
        '远端同步协议版本较高（v$protocolVersion），请升级 App 后再同步',
      );
    }
  }
}

Map<String, dynamic> encodeManifestV2({
  required V2Manifest? previous,
  required String deviceId,
  required int nowMs,
  required Map<String, int> counts,
}) {
  final writers = <String, dynamic>{...(previous?.writers ?? const {})};
  writers[deviceId] = {
    'protocol': kV2ProtocolVersion,
    'last_seen': formatUtcIso(nowMs),
  };
  return {
    ...(previous?.raw ?? const {}),
    'format': 'shengwuji.manifest',
    'protocol_version': kV2ProtocolVersion,
    'min_reader_version': kV2MinReaderVersion,
    'device_id': deviceId,
    'updated_at': formatUtcIso(nowMs),
    'last_writer': deviceId,
    'writers': writers,
    'counts': counts,
  };
}

/// 判断两个 JSON 文本除指定顶层字段与本机 writers.last_seen 外是否一致。
/// 用于「内容没变就不 PUT」，避免每次同步都刷新 ETag 触发电脑端额外同步
bool sameV2Content(
  Object? previous,
  Map<String, dynamic> next, {
  required Set<String> ignoreKeys,
  required String deviceId,
}) {
  if (previous is! Map) return false;
  return sameJsonContent(
    _normalizeForCompare(previous, ignoreKeys, deviceId),
    _normalizeForCompare(next, ignoreKeys, deviceId),
  );
}

/// 通用 JSON 值比较：递归排序对象键后再比序列化结果——键序与空白差异不算
/// 变更。**数组顺序参与比较**（行序变了按「有变更」处理：宁可多 PUT 一次，
/// 也不把真有差异的内容当成没变）。任一侧为 null 按不一致处理。
bool sameJsonContent(Object? a, Object? b) {
  if (a == null || b == null) return false;
  return jsonEncode(_sortJson(a)) == jsonEncode(_sortJson(b));
}

Map<String, dynamic> _normalizeForCompare(
  Map raw,
  Set<String> ignoreKeys,
  String deviceId,
) {
  final map = <String, dynamic>{
    for (final entry in raw.entries)
      if (!ignoreKeys.contains(entry.key.toString()))
        entry.key.toString(): entry.value,
  };
  final writers = map['writers'];
  if (writers is Map) {
    final copy = <String, dynamic>{
      for (final entry in writers.entries)
        entry.key.toString(): entry.value,
    };
    final self = copy[deviceId];
    if (self is Map) {
      copy[deviceId] = {
        for (final entry in self.entries)
          if (entry.key != 'last_seen') entry.key.toString(): entry.value,
      };
    }
    map['writers'] = copy;
  }
  return _sortJson(map) as Map<String, dynamic>;
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final key in keys) key: _sortJson(value[key])};
  }
  if (value is List) return [for (final item in value) _sortJson(item)];
  return value;
}

// ==================== 本地行 → v2 笔记 ====================

/// 手机本地 diary 行 + 透传元数据 → 参与合并/上传的 v2 笔记。
///
/// 手机端只管理正文/时间/标注/归档/锁定/排序与自己的录音；电脑端的图片
/// 附件、标签、未知字段来自 meta，原样保留。
/// - meta 为 null 表示手机新建、尚未同步过的笔记
/// - [seed]：同 uuid 的远端 v2 笔记。手机首次接 v2 时 meta 还不存在，
///   若不复用远端标签/图片/未知字段，双方载荷差异会被 LWW 误判成「手机
///   改过」，把电脑端数据覆盖掉
/// - 有本机录音时重建音频附件（稳定 uuid 与电脑端一致），并丢掉元数据里
///   同 kind 但不同文件名的旧音频，避免换录音后云端留幽灵
V2Note noteFromDiaryRow(
  Map<String, dynamic> row, {
  Map<String, dynamic>? meta,
  V2Note? seed,
}) {
  final uuid = (row['sync_uuid'] as String?) ?? '';
  final createdAtMs =
      parseIsoMillis(row['created_at']) ??
      DateTime.tryParse((row['created_at'] as String?) ?? '')
          ?.millisecondsSinceEpoch ??
      0;
  final updatedAtMs = (row['updated_at'] as int?) ?? createdAtMs;

  final hasMeta = meta != null;
  final tags = hasMeta
      ? _decodeJsonList(meta['tags_json'])
      : List<dynamic>.from(seed?.tags ?? const []);
  final extras = hasMeta
      ? _decodeJsonMap(meta['extras_json'])
      : Map<String, dynamic>.from(seed?.extras ?? const {});
  extras.remove('tags');
  final attachments = hasMeta
      ? _decodeMetaAttachments(meta['attachments_json'])
      : List<V2Attachment>.from(seed?.attachments ?? const []);

  final audioPath = row['audio_path'] as String?;
  final audioName = (audioPath == null || audioPath.isEmpty)
      ? ''
      : p.basename(audioPath);
  if (audioName.isNotEmpty) {
    attachments.removeWhere(
      (item) => item.isAudio && item.name != audioName,
    );
    final durationMs = row['duration'] is int
        ? (row['duration'] as int) * 1000
        : null;
    final mime = _audioMimeType(audioName);
    final index = attachments.indexWhere(
      (item) => item.isAudio && item.name == audioName,
    );
    if (index >= 0) {
      attachments[index] = attachments[index].copyWith(
        durationMs: durationMs,
        mimeType: mime,
      );
    } else {
      attachments.add(
        V2Attachment(
          uuid: audioAttachmentUuid(uuid, audioName),
          kind: 'audio',
          origin: 'record',
          name: audioName,
          mimeType: mime,
          durationMs: durationMs,
        ),
      );
    }
  }

  return V2Note(
    uuid: uuid,
    content: (row['content'] as String?) ?? '',
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    mark: row['tag'] as String?,
    archived: (row['is_archived'] as int? ?? 0) != 0,
    locked: (row['is_locked'] as int? ?? 0) != 0,
    sortOrder: row['sort_order'] as int?,
    rev: meta != null && meta['rev'] is int ? meta['rev'] as int : (seed?.rev ?? 1),
    tags: tags,
    attachments: attachments,
    extras: extras,
  );
}

/// v2 笔记 → 本地 diary 行（applySyncV2Notes 入参形状）
Map<String, dynamic> diaryRowFromV2Note(V2Note note) => {
  'sync_uuid': note.uuid,
  'content': note.content,
  'created_at': formatLocalIso(note.createdAtMs),
  'duration': _firstAudio(note)?.durationMs != null
      ? ((_firstAudio(note)!.durationMs!) / 1000).round()
      : null,
  'is_archived': note.archived ? 1 : 0,
  'is_locked': note.locked ? 1 : 0,
  'tag': note.mark,
  'sort_order': note.archived ? null : note.sortOrder,
  'updated_at': note.updatedAtMs,
};

/// v2 笔记 → sync_note_meta 行；baseHash 为本次同步后的新基线
Map<String, dynamic> metaRowFromV2Note(V2Note note, {String? baseHash}) => {
  'note_uuid': note.uuid,
  'base_hash': baseHash ?? note.payloadHash,
  'rev': note.rev,
  'tags_json': jsonEncode(note.tags),
  'attachments_json': jsonEncode([
    for (final item in note.attachments) item.toJson(),
  ]),
  'extras_json': jsonEncode(note.extras),
};

V2Attachment? _firstAudio(V2Note note) {
  final audios = note.attachments.where((item) => item.isAudio).toList()
    ..sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      return byOrder != 0 ? byOrder : a.uuid.compareTo(b.uuid);
    });
  return audios.isEmpty ? null : audios.first;
}

/// 与电脑端 SyncCodec.audioAttachmentUuid 完全一致的稳定 v5 id
String audioAttachmentUuid(String noteUuid, String syncName) => const Uuid().v5(
  Namespace.url.value,
  'shengwuji/audio/$noteUuid/$syncName',
);

List<dynamic> _decodeJsonList(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? List<dynamic>.from(decoded) : [];
  } catch (_) {
    return [];
  }
}

Map<String, dynamic> _decodeJsonMap(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? decoded.map((key, value) => MapEntry(key.toString(), value))
        : {};
  } catch (_) {
    return {};
  }
}

List<V2Attachment> _decodeMetaAttachments(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return [
      for (final item in decoded)
        if (item is Map)
          V2Attachment.fromRaw(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ]..removeWhere((item) => item.uuid.isEmpty);
  } catch (_) {
    return [];
  }
}

String? _audioMimeType(String? name) {
  if (name == null || name.isEmpty) return null;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  switch (name.substring(dot + 1).toLowerCase()) {
    case 'wav':
      return 'audio/wav';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'ogg':
      return 'audio/ogg';
    case 'flac':
      return 'audio/flac';
    default:
      return null;
  }
}

/// 远端字段里的文件名只取 basename，防路径穿越（同电脑端 safeBaseName）
String _safeBaseName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.split(RegExp(r'[/\\]')).last;
}

/// v1 duration 是秒（兼容字符串与毫秒级旧数据由电脑端处理，这里同口径）
int? _durationToMs(Object? value) {
  final seconds = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  if (seconds == null || seconds < 0) return null;
  return (seconds * 1000).round();
}
