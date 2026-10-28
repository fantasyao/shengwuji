import 'package:uuid/uuid.dart';

import 'sync_v2.dart';

/// v2 笔记三方合并（纯函数，无 IO，单测覆盖 test/sync_v2_test.dart）。
///
/// 与电脑端 `SyncMerger` 同一套规则：
/// - 墓碑优先于内容；`updated_at > deleted_at` 的编辑允许复活
/// - 有基线哈希时判断「谁改过」：只有一方改过 → 改的一方赢，不产生冲突
/// - 双方都改过 → LWW；时间相差 ≤5 分钟时给输家生成冲突副本（只在
///   输家设备本地生成一次，避免两台设备各建一条）
/// - 平局用载荷哈希字典序做确定性裁决，所有设备算出的赢家一致

class V2MergeInput {
  const V2MergeInput({
    required this.localNotes,
    required this.localTombstones,
    required this.remoteNotes,
    required this.remoteTombstones,
    required this.bases,
    required this.nowMs,
  });

  final List<V2Note> localNotes;
  final Map<String, V2Tombstone> localTombstones;
  final List<V2Note> remoteNotes;
  final Map<String, V2Tombstone> remoteTombstones;

  /// uuid → 上次成功同步时的载荷哈希
  final Map<String, String> bases;
  final int nowMs;
}

class V2MergeOutput {
  const V2MergeOutput({
    required this.notes,
    required this.tombstones,
    required this.appliedRemote,
    required this.keptLocal,
    required this.conflictCopies,
    required this.remoteDeletions,
    required this.resurrected,
  });

  final Map<String, V2Note> notes;
  final Map<String, V2Tombstone> tombstones;
  final int appliedRemote;
  final int keptLocal;
  final int conflictCopies;
  final int remoteDeletions;
  final int resurrected;
}

V2MergeOutput mergeV2Notes(V2MergeInput input, {Uuid? uuid}) {
  final uuidGen = uuid ?? const Uuid();
  final notes = <String, V2Note>{
    for (final note in input.localNotes) note.uuid: note,
  };
  final tombstones = <String, V2Tombstone>{
    for (final item in input.localTombstones.values) item.uuid: item,
  };
  final remoteTombstoneUuids = <String>{};

  for (final remote in input.remoteTombstones.values) {
    remoteTombstoneUuids.add(remote.uuid);
    final existing = tombstones[remote.uuid];
    if (existing == null || remote.deletedAtMs > existing.deletedAtMs) {
      tombstones[remote.uuid] = remote;
    }
  }

  var remoteDeletions = 0;
  var resurrected = 0;
  for (final tombstone in List<V2Tombstone>.from(tombstones.values)) {
    final note = notes[tombstone.uuid];
    if (note == null) continue;
    if (note.updatedAtMs > tombstone.deletedAtMs) {
      // 墓碑之后有过编辑 → 删除后重建，允许复活
      tombstones.remove(tombstone.uuid);
      if (remoteTombstoneUuids.contains(tombstone.uuid)) resurrected++;
      continue;
    }
    notes.remove(tombstone.uuid);
    if (remoteTombstoneUuids.contains(tombstone.uuid)) remoteDeletions++;
  }

  var appliedRemote = 0;
  var keptLocal = 0;
  var conflictCopies = 0;
  for (final remote in input.remoteNotes) {
    final local = notes[remote.uuid];
    if (local == null) {
      final tombstone = tombstones[remote.uuid];
      if (tombstone != null) {
        if (remote.updatedAtMs > tombstone.deletedAtMs) {
          tombstones.remove(remote.uuid);
          notes[remote.uuid] = remote;
          appliedRemote++;
          resurrected++;
        }
        continue;
      }
      notes[remote.uuid] = remote;
      appliedRemote++;
      continue;
    }

    final decision = _resolve(
      local: local,
      remote: remote,
      baseHash: input.bases[local.uuid],
    );
    if (decision.remoteWins) {
      if (decision.conflict) {
        final copy = _conflictCopy(
          local,
          uuidGen: uuidGen,
          nowMs: input.nowMs,
        );
        notes[copy.uuid] = copy;
        conflictCopies++;
      }
      notes[remote.uuid] = remote;
      appliedRemote++;
    } else if (decision.changed) {
      keptLocal++;
    }
    // 双方同时存在时不应保留墓碑（防御异常输入）
    tombstones.remove(remote.uuid);
  }

  for (final noteUuid in notes.keys) {
    tombstones.remove(noteUuid);
  }

  return V2MergeOutput(
    notes: notes,
    tombstones: tombstones,
    appliedRemote: appliedRemote,
    keptLocal: keptLocal,
    conflictCopies: conflictCopies,
    remoteDeletions: remoteDeletions,
    resurrected: resurrected,
  );
}

_V2Decision _resolve({
  required V2Note local,
  required V2Note remote,
  required String? baseHash,
}) {
  if (local.payloadHash == remote.payloadHash) {
    return const _V2Decision(remoteWins: false, changed: false);
  }

  if (baseHash != null) {
    final localChanged = local.payloadHash != baseHash;
    final remoteChanged = remote.payloadHash != baseHash;
    if (localChanged && !remoteChanged) {
      return const _V2Decision(remoteWins: false, changed: true);
    }
    if (!localChanged && remoteChanged) {
      return const _V2Decision(remoteWins: true, changed: true);
    }
    if (!localChanged && !remoteChanged) {
      // 基线相同但载荷不同，说明基线本身不可靠：按时间裁决
      return _lww(local: local, remote: remote, mayConflict: false);
    }
    return _lww(local: local, remote: remote, mayConflict: true);
  }

  // 没有基线（首次同步/状态丢失）：只按 LWW，不生成冲突副本，避免把
  // 存量数据差异误判成冲突
  return _lww(local: local, remote: remote, mayConflict: false);
}

_V2Decision _lww({
  required V2Note local,
  required V2Note remote,
  required bool mayConflict,
}) {
  var remoteWins = remote.updatedAtMs > local.updatedAtMs;
  var tie = false;
  if (remote.updatedAtMs == local.updatedAtMs) {
    // 平局用载荷哈希做确定性裁决，所有设备算出的赢家一致
    remoteWins = remote.payloadHash.compareTo(local.payloadHash) < 0;
    tie = true;
  }
  if (!remoteWins) {
    return const _V2Decision(remoteWins: false, changed: true);
  }
  final close =
      tie ||
      (remote.updatedAtMs - local.updatedAtMs).abs() <=
          kV2ConflictWindow.inMilliseconds;
  return _V2Decision(
    remoteWins: true,
    changed: true,
    conflict: mayConflict && close,
    loser: local,
  );
}

V2Note _conflictCopy(
  V2Note loser, {
  required Uuid uuidGen,
  required int nowMs,
}) {
  final extras = <String, dynamic>{
    for (final entry in loser.extras.entries)
      if (entry.key != 'conflict_of') entry.key: entry.value,
    'conflict_of': loser.uuid,
  };
  return V2Note(
    uuid: uuidGen.v4(),
    content: loser.content,
    createdAtMs: loser.createdAtMs,
    updatedAtMs: nowMs,
    mark: loser.mark,
    archived: false,
    locked: loser.locked,
    sortOrder: loser.sortOrder,
    rev: 1,
    tags: loser.tags,
    attachments: [
      for (final attachment in loser.attachments)
        V2Attachment(
          uuid: uuidGen.v4(),
          kind: attachment.kind,
          origin: attachment.origin,
          sha256: attachment.sha256,
          name: attachment.name,
          mimeType: attachment.mimeType,
          byteSize: attachment.byteSize,
          durationMs: attachment.durationMs,
          sortOrder: attachment.sortOrder,
          rev: 1,
          extras: attachment.extras,
        ),
    ],
    extras: extras,
  );
}

class _V2Decision {
  const _V2Decision({
    required this.remoteWins,
    required this.changed,
    this.conflict = false,
    this.loser,
  });

  final bool remoteWins;
  final bool changed;
  final bool conflict;
  final V2Note? loser;
}
