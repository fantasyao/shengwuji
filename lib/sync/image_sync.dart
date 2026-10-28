import 'dart:convert';
import 'dart:typed_data';

/// 截图附件云同步（双向，见 docs/architecture/cloud-sync.md）。
///
/// 图片本体复用电脑端既有的内容寻址资产目录
/// `v2/assets/<sha 前两位>/<sha256>.<ext>`；本文件维护根目录的
/// `image_index.json`，把笔记 sync_uuid 映射到图片 sha 与格式。
///
/// 一条笔记可以有多张图：手机自拍截图（diary.image_path，最多一张）与
/// 电脑端笔记里的图片附件（可多张），各自以「设备」身份发布条目。索引按
/// (note_uuid, device_id, sha256) 唯一、position 决定展示顺序；每台设备
/// 只负责替换/移除自己写的条目，不碰其他设备的图片。

/// 云端图片协议版本（与电脑端 v2/manifest.json 对齐）。远端要求的最低
/// 读取版本更高时跳过截图同步，绝不按旧规则写新命名空间。
const int kImageSyncProtocolVersion = 2;

/// 单次同步上传/下载图片上限（张）。坚果云免费版 600 请求/30 分钟；
/// 首次同步几十张截图 = 每张 1 PUT/GET + 1 次索引读写，分批留出余量。
const int kImageSyncBatchLimit = 80;

/// 与电脑端一致的图片大小上限（超过会被桌面端拒收）
const int kMaxSyncedImageBytes = 20 * 1024 * 1024;

final RegExp _shaPattern = RegExp(r'^[0-9a-f]{64}$');

/// 一条截图索引：某台设备为某条笔记保存的图片。
class ImageSyncEntry {
  const ImageSyncEntry({
    required this.noteUuid,
    required this.deviceId,
    required this.sha256,
    required this.name,
    required this.mimeType,
    required this.byteSize,
    required this.updatedAt,
    this.position = 0,
    this.source = '',
  });

  /// 日记 sync_uuid（跨端身份）
  final String noteUuid;

  /// 写入该条目的设备（手机 device_id）；只有本机可以替换/移除
  final String deviceId;

  /// 图片内容哈希（小写 64 位十六进制）
  final String sha256;

  /// 云端文件名 = `<sha256>.<ext>`（电脑端按同规则推导资产路径）
  final String name;

  final String mimeType;
  final int byteSize;

  /// 写入时间（UTC ISO）。同设备同笔记的旧版本条目用它比新旧
  final String updatedAt;

  /// 同一笔记内的展示顺序（0 起，小在前）；缺省 0 兼容旧索引
  final int position;

  /// 发布方类型：'' / 'mobile' = 手机截图，'desktop' = 电脑端图片附件。
  /// 手机端只做原样透传（回写索引时不能丢，否则电脑端会把它当手机图
  /// 重复挂接）
  final String source;

  bool get isValid =>
      noteUuid.isNotEmpty &&
      _shaPattern.hasMatch(sha256) &&
      isSafeImageName(name) &&
      name.contains('.');

  /// 图片本体在云端的相对路径（`v2/assets/<前两位>/<sha>.<ext>`）
  String get remotePath =>
      'v2/assets/${sha256.substring(0, 2)}/$name';

  /// 索引唯一键：同设备同一张图为一条，position 可随重排更新
  String get key => '$noteUuid\u0000$deviceId\u0000$sha256';

  Map<String, dynamic> toJson() => {
    'note_uuid': noteUuid,
    'device_id': deviceId,
    'sha256': sha256,
    'name': name,
    'mime': mimeType,
    'size': byteSize,
    'updated_at': updatedAt,
    'position': position,
    if (source.isNotEmpty) 'source': source,
  };

  static ImageSyncEntry? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final raw = value.map((key, item) => MapEntry(key.toString(), item));
    final noteUuid = (raw['note_uuid'] ?? raw['uuid'] ?? '') as String? ?? '';
    final sha = (raw['sha256'] as String? ?? '').trim().toLowerCase();
    final name = safeImageName(raw['name'] as String? ?? '');
    if (noteUuid.isEmpty || !_shaPattern.hasMatch(sha) || name.isEmpty) {
      return null;
    }
    return ImageSyncEntry(
      noteUuid: noteUuid,
      deviceId: (raw['device_id'] as String? ?? '').trim(),
      sha256: sha,
      name: name,
      mimeType: (raw['mime'] as String? ?? '').trim(),
      byteSize: (raw['size'] as num?)?.toInt() ?? 0,
      updatedAt: (raw['updated_at'] as String? ?? '').trim(),
      position: ((raw['position'] as num?)?.toInt() ?? 0).clamp(0, 100000),
      source: (raw['source'] as String? ?? '').trim(),
    );
  }
}

/// 远端文件名安全性：只放行纯文件名，防索引被写坏后拼接路径逃出
/// `v2/assets` 目录。
bool isSafeImageName(String name) =>
    name.isNotEmpty &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('..');

/// 远端/本地文件名统一收敛成 basename
String safeImageName(String value) {
  final normalized = value.trim().replaceAll(r'\', '/');
  final last = normalized.split('/').last;
  return last.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
}

/// 解析 image_index.json；顶层不是数组（或 JSON 坏）返回 null，调用方
/// 必须把 null 当成「索引不可用」而不是「空索引」，否则会误删本机条目。
List<ImageSyncEntry>? tryDecodeImageEntries(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [for (final item in decoded) ?ImageSyncEntry.tryFromJson(item)];
  } catch (_) {
    return null;
  }
}

/// 编码索引：按 (note_uuid, device_id, position, sha256) 排序，避免顺序
/// 抖动导致每轮都重传。
String encodeImageEntries(List<ImageSyncEntry> entries) {
  final sorted = List<ImageSyncEntry>.from(entries)
    ..sort((a, b) {
      final byNote = a.noteUuid.compareTo(b.noteUuid);
      if (byNote != 0) return byNote;
      final byDevice = a.deviceId.compareTo(b.deviceId);
      if (byDevice != 0) return byDevice;
      final byPosition = a.position.compareTo(b.position);
      return byPosition != 0 ? byPosition : a.sha256.compareTo(b.sha256);
    });
  return jsonEncode([for (final entry in sorted) entry.toJson()]);
}

/// 合并远端索引与本地索引。
///
/// - 其他设备写的条目（可多条）原样保留；
/// - 本机写过的条目：笔记仍在本地 → 由本次本地图片替换/移除
///   （[keepOwnFor] 里的笔记例外：本轮上传失败或超限，保留旧条目，
///   避免电脑端丢失上一张还能用的图）；
/// - 笔记在本地已不存在 → 保留旧条目（P1 删除不跨端，不能让本机
///   删笔记把电脑端还挂着的图摘掉）。
List<ImageSyncEntry> mergeImageIndex({
  required List<ImageSyncEntry> remote,
  required List<ImageSyncEntry> local,
  required String deviceId,
  required Set<String> localNoteUuids,
  Set<String> keepOwnFor = const {},
}) {
  final byKey = <String, ImageSyncEntry>{};
  for (final entry in remote) {
    if (!entry.isValid) continue;
    if (entry.deviceId == deviceId &&
        localNoteUuids.contains(entry.noteUuid) &&
        !keepOwnFor.contains(entry.noteUuid)) {
      continue;
    }
    final current = byKey[entry.key];
    if (current == null || _updatedAtMs(entry) > _updatedAtMs(current)) {
      byKey[entry.key] = entry;
    }
  }
  for (final entry in local) {
    if (!entry.isValid) continue;
    byKey[entry.key] = entry;
  }
  return byKey.values.toList(growable: false);
}

/// 一条待下载的图片：笔记 sync_uuid（落库时定位笔记）+ 来源设备 + 云端文件
typedef PendingImageDownload = ({
  String noteUuid,
  String deviceId,
  String sha256,
  String name,
  int position,
});

/// 计算本次待下载的图片。
///
/// - 只处理笔记仍在本地、未命中墓碑的条目；
/// - 其他设备的条目：本地还没下载过同 (note, device, sha) 就排队，
///   电脑端新增/替换/多张都会补下来；
/// - 本机条目：仅当本机截图丢失（[notesWithOwnImage] 不含该笔记）时，
///   取 updated_at 最新的一条恢复 image_path，其余忽略。
/// 返回 (本批, 剩余未排入数)。
(List<PendingImageDownload>, int) planImageDownloads({
  required List<ImageSyncEntry> remote,
  required String deviceId,
  required Set<String> localNoteUuids,
  required Set<String> tombstones,
  required Set<String> existingKeys,
  required Set<String> notesWithOwnImage,
  int limit = kImageSyncBatchLimit,
}) {
  final remoteCandidates = <ImageSyncEntry>[];
  final ownLatest = <String, ImageSyncEntry>{};
  for (final entry in remote) {
    if (!entry.isValid ||
        !localNoteUuids.contains(entry.noteUuid) ||
        tombstones.contains(entry.noteUuid)) {
      continue;
    }
    if (entry.deviceId == deviceId) {
      if (notesWithOwnImage.contains(entry.noteUuid)) continue;
      final current = ownLatest[entry.noteUuid];
      if (current == null || _updatedAtMs(entry) > _updatedAtMs(current)) {
        ownLatest[entry.noteUuid] = entry;
      }
      continue;
    }
    if (existingKeys.contains(entry.key)) continue;
    remoteCandidates.add(entry);
  }
  remoteCandidates.sort((a, b) {
    final byNote = a.noteUuid.compareTo(b.noteUuid);
    if (byNote != 0) return byNote;
    final byPosition = a.position.compareTo(b.position);
    if (byPosition != 0) return byPosition;
    final byDevice = a.deviceId.compareTo(b.deviceId);
    return byDevice != 0 ? byDevice : a.sha256.compareTo(b.sha256);
  });
  final pending = <PendingImageDownload>[
    for (final entry in remoteCandidates)
      (
        noteUuid: entry.noteUuid,
        deviceId: entry.deviceId,
        sha256: entry.sha256,
        name: entry.name,
        position: entry.position,
      ),
    for (final entry in ownLatest.values)
      (
        noteUuid: entry.noteUuid,
        deviceId: entry.deviceId,
        sha256: entry.sha256,
        name: entry.name,
        position: entry.position,
      ),
  ];
  if (pending.length <= limit) return (pending, 0);
  return (pending.sublist(0, limit), pending.length - limit);
}

int _updatedAtMs(ImageSyncEntry entry) =>
    DateTime.tryParse(entry.updatedAt)?.millisecondsSinceEpoch ?? 0;

/// 按文件头识别图片格式（与电脑端 image_payload.dart 同规则）；无法识别
/// 返回 null。手机截图是 JPEG，其余格式兼容历史/导入数据。
String? detectImageExtension(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'bmp';
  }
  return null;
}

String imageMimeType(String extension) {
  switch (extension.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
    default:
      return 'application/octet-stream';
  }
}
