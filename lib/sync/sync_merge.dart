import 'sync_models.dart';

/// 云同步合并裁决（纯函数，无 IO，单元测试覆盖 test/sync_merge_test.dart）。
///
/// P1 合并总原则（见 docs/architecture/cloud-sync.md）：
/// - 只做「新增条目」的双向并集，编辑/删除不跨端传播（P2 引入
///   updated_at/tombstone 传播后放开）
/// - 合并键：日记/物品用 sync_uuid，辅以自然键去重（备份导入的行 uuid
///   是新造的，但 content+created_at 相同，不该重复出现）
/// - 本地删除过的 uuid 记在墓碑表，远端同名条目不再拉回（防复活）

/// 热词文本合并：本地为主，远端只补本地没有的行。
/// - 字面替换对（「错词 = 正词」）按错词键去重：同错词远端正词不同时
///   保留本地（热词是用户显式配置，本地意图优先）
/// - 音素行（「目标 | 别名」）与基础行整行精确去重
/// - 注释行/空行不参与合并（远端注释对本地无信息量，只会制造 diff 噪音）
/// - 与 parseHotwordEntries 的字面行解析保持一致（split(' = ') 恰两段）
String mergeHotwordContent(String local, String remote) {
  final localLines = <String>{};
  final localLiteralKeys = <String>{};
  for (var line in local.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    localLines.add(line);
    final parts = line.split(' = ');
    if (parts.length == 2 && parts[0].trim().isNotEmpty) {
      localLiteralKeys.add(parts[0].trim());
    }
  }

  final added = <String>[];
  final addedLiteralKeys = <String>{};
  for (var line in remote.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (localLines.contains(line) || added.contains(line)) continue;
    final parts = line.split(' = ');
    if (parts.length == 2 && parts[0].trim().isNotEmpty) {
      final key = parts[0].trim();
      // 同错词本地已有规则（或本批远端已补过）→ 保留先到者
      if (localLiteralKeys.contains(key) || addedLiteralKeys.contains(key)) {
        continue;
      }
      addedLiteralKeys.add(key);
    }
    added.add(line);
  }

  if (added.isEmpty) return local;
  final head = local.isEmpty || local.endsWith('\n')
      ? local
      : '$local\n';
  return '$head${added.join('\n')}\n';
}

/// 非空非注释行数（热词条数统计，与设置页口径一致）
int countHotwordRules(String content) => content
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .length;

/// 计算需要从远端插入本地的日记。
/// 跳过：uuid 在墓碑（本地删过，防复活）/ uuid 已存在 / 自然键
/// （content|created_at）已存在（备份导入复原的行 uuid 新但内容同）
List<DiarySyncEntry> planDiaryInserts({
  required List<Map<String, dynamic>> localRows,
  required List<DiarySyncEntry> remoteEntries,
  required Set<String> tombstones,
}) {
  final localUuids = <String>{};
  final localNaturalKeys = <String>{};
  for (final r in localRows) {
    final u = r['sync_uuid'] as String?;
    if (u != null && u.isNotEmpty) localUuids.add(u);
    localNaturalKeys.add('${r['content']}|${r['created_at']}');
  }
  return remoteEntries
      .where(
        (e) =>
            e.uuid.isNotEmpty &&
            !tombstones.contains(e.uuid) &&
            !localUuids.contains(e.uuid) &&
            !localNaturalKeys.contains('${e.content}|${e.createdAt}'),
      )
      .toList();
}

/// 计算需要从远端插入本地的物品（自然键 name|location，其余同上）
List<ItemSyncEntry> planItemInserts({
  required List<Map<String, dynamic>> localRows,
  required List<ItemSyncEntry> remoteEntries,
  required Set<String> tombstones,
}) {
  final localUuids = <String>{};
  final localNaturalKeys = <String>{};
  for (final r in localRows) {
    final u = r['sync_uuid'] as String?;
    if (u != null && u.isNotEmpty) localUuids.add(u);
    localNaturalKeys.add('${r['name']}|${r['location']}');
  }
  return remoteEntries
      .where(
        (e) =>
            e.uuid.isNotEmpty &&
            !tombstones.contains(e.uuid) &&
            !localUuids.contains(e.uuid) &&
            !localNaturalKeys.contains('${e.name}|${e.location}'),
      )
      .toList();
}

// ==================== 录音文件同步（开关启用，docs/architecture/cloud-sync.md） ====================

/// 单次同步录音上传/下载上限（个）。坚果云免费版 600 请求/30 分钟、超限封
/// 约 6 小时，文本整包 8~12 请求不碍事，录音首批动辄数百个文件——必须
/// 分批：超出的留待下次手动同步继续（audio_index.json 记已传名单防重传）
const int kAudioSyncBatchLimit = 80;

/// 文件名安全性：只放行「纯文件名」（无路径分隔符、非 `..`），防云端
/// diary.json 被写入恶意名后 GET 落盘时逃出 diary_audio 目录
bool isSafeAudioName(String name) =>
    name.isNotEmpty &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('..');

/// 计算本次待上传的录音文件名（basename，保持入参顺序）。
/// [localAudioNames]：本地 diary 行 audio_path 指向且文件实际存在的
/// basename 全集（文件存在性是 IO，由调用方筛好）；[uploadedIndex] 为云端
/// audio_index.json 已确认上传名单。
/// 返回 (本批名单, 剩余未排入数——提示用户下次同步续传)
(List<String>, int) planAudioUploads({
  required Iterable<String> localAudioNames,
  required Set<String> uploadedIndex,
  int limit = kAudioSyncBatchLimit,
}) {
  final pending = <String>[];
  final seen = <String>{};
  for (final name in localAudioNames) {
    if (name.isEmpty ||
        !isSafeAudioName(name) ||
        uploadedIndex.contains(name) ||
        !seen.add(name)) {
      continue;
    }
    pending.add(name);
  }
  if (pending.length <= limit) return (pending, 0);
  return (pending.sublist(0, limit), pending.length - limit);
}

/// 一条待下载的远端录音：日记 sync_uuid（下载成功后回填该行 audio_path）
/// + 远端音频文件名
typedef PendingAudioDownload = ({String uuid, String name});

/// 计算本次待下载的远端录音：远端日记带 audio 名、本地 diary_audio 目录
/// 没有同名文件、该日记 uuid 未命中本地墓碑（删过的行文本不拉回，音频
/// 同理不拉回）。同名多条只排一次队（下载按文件名幂等）。
/// 返回 (本批名单, 剩余未排入数)
(List<PendingAudioDownload>, int) planAudioDownloads({
  required List<DiarySyncEntry> remoteEntries,
  required Set<String> localExistingNames,
  required Set<String> tombstones,
  int limit = kAudioSyncBatchLimit,
}) {
  final pending = <PendingAudioDownload>[];
  final seen = <String>{};
  for (final e in remoteEntries) {
    final name = e.audioName;
    if (e.uuid.isEmpty ||
        name == null ||
        !isSafeAudioName(name) ||
        tombstones.contains(e.uuid) ||
        localExistingNames.contains(name) ||
        !seen.add(name)) {
      continue;
    }
    pending.add((uuid: e.uuid, name: name));
  }
  if (pending.length <= limit) return (pending, 0);
  return (pending.sublist(0, limit), pending.length - limit);
}
