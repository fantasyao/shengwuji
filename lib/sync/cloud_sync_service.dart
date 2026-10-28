import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../app_logger.dart';
import '../db_helper.dart';
import '../text_processor.dart';
import '../utils/cloud_sync_data_version.dart'; // 待同步检测：同步成功快照数据版本
import '../utils/diary_sync_bridge.dart';
import 'image_sync.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_v2.dart';
import 'sync_v2_merge.dart';
import 'webdav_request_counter.dart';

/// WebDAV 云同步服务（手动触发，见 docs/architecture/cloud-sync.md）。
///
/// 云端目录：v1 投影 manifest.json + diary.json + items.json +
/// hotwords.txt + correction_pairs.json + audio_index.json，以及 v2 命名
/// 空间 v2/manifest.json + v2/notes.json + v2/tombstones.json（编辑/删除
/// 跨端传播，与电脑端同一套协议）；录音本体在 audio/，图片本体在电脑端
/// 共享的 v2/assets/（内容寻址）。
/// 文本每次同步 12~16 个请求；录音/截图按各自索引分批，单次上限防
/// 坚果云 600 请求/30 分钟限流。
///
/// 合并边界：日记走 v2 三方合并（基线哈希 + LWW + 墓碑，支持编辑与删除）；
/// v1 diary.json 仍全量回写投影给旧客户端；物品仍为新增并集。录音文件
/// 走独立开关，默认不同步，同步失败只记提示不拖垮文本同步。

/// 同步配置存取：地址/账号/远端目录存 SharedPreferences（设置入口行摘要
/// 要同步读），密码存 flutter_secure_storage（Android Keystore 加密，
/// 坚果云要求用「应用密码」而非登录密码）。
class CloudSyncConfig {
  CloudSyncConfig({
    required this.serverUrl,
    required this.account,
    required this.password,
    required this.remotePath,
    this.syncAudio = false,
  });

  static const kServerUrl = 'cloud_sync_server_url';
  static const kAccount = 'cloud_sync_account';
  static const kRemotePath = 'cloud_sync_remote_path';
  static const kPassword = 'cloud_sync_password'; // flutter_secure_storage
  static const kDeviceId = 'cloud_sync_device_id';
  static const kLastSyncAt = 'cloud_sync_last_sync_at';
  static const kLastSyncSummary = 'cloud_sync_last_sync_summary';

  /// 是否同步录音文件（默认关：WAV 约 2MB/分钟，开启属用户显式决定）
  static const kSyncAudio = 'cloud_sync_audio';

  /// 默认远端目录（ASCII 路径，规避个别 WebDAV 服务端对非 ASCII 路径的
  /// 编码差异；坚果云/WebDAV 常见用法是网盘根下建一个应用专属目录）
  static const defaultRemotePath = '/shengwuji_sync';

  final String serverUrl;
  final String account;
  final String password;
  final String remotePath;

  /// 是否同步录音文件（见 kSyncAudio；默认 false）
  final bool syncAudio;

  bool get isConfigured =>
      serverUrl.trim().isNotEmpty &&
      account.trim().isNotEmpty &&
      password.isNotEmpty;

  static Future<CloudSyncConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final password =
        await const FlutterSecureStorage().read(key: kPassword) ?? '';
    return CloudSyncConfig(
      serverUrl: prefs.getString(kServerUrl) ?? '',
      account: prefs.getString(kAccount) ?? '',
      password: password,
      remotePath:
          prefs.getString(kRemotePath) ?? defaultRemotePath,
      syncAudio: prefs.getBool(kSyncAudio) ?? false,
    );
  }

  /// 录音同步开关独立即时保存（不随配置页「保存配置」按钮）
  static Future<void> saveSyncAudio(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kSyncAudio, enabled);
    log('[云同步] 录音同步开关 → $enabled');
  }

  static Future<void> save({
    required String serverUrl,
    required String account,
    required String password,
    required String remotePath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kServerUrl, serverUrl.trim());
    await prefs.setString(kAccount, account.trim());
    await prefs.setString(
      kRemotePath,
      remotePath.trim().isEmpty ? defaultRemotePath : remotePath.trim(),
    );
    await const FlutterSecureStorage().write(key: kPassword, value: password);
    log('[云同步] 配置已保存（服务器/账号/远端目录 → prefs，密码 → 安全存储）');
  }

  /// 本机设备标识（软锁与日志用，首次生成后固定）
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(kDeviceId, id);
    }
    return id;
  }

  /// 上次同步时间与摘要（设置入口行/二级页状态区显示；从未同步返回 null）
  static Future<(DateTime, String)?> lastSyncInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getString(kLastSyncAt);
    final summary = prefs.getString(kLastSyncSummary);
    if (at == null || summary == null) return null;
    final t = DateTime.tryParse(at);
    if (t == null) return null;
    return (t, summary);
  }

  /// 入口行/二级页共用的状态文案（纯函数，单测覆盖）。
  /// hasPending=true 优先展示「有新数据待同步」——卡片若只显示上次同步
  /// 结果快照，用户在同步后新增数据会误以为云端一致（真机反馈 2026-09-22）
  static String buildEntrySubtitle({
    required bool configured,
    required bool hasPending,
    required (DateTime, String)? lastSync,
  }) {
    if (!configured) return '未配置 · 支持 WebDAV 网盘（坚果云等）';
    if (lastSync == null) return '已配置 · 尚未同步';
    final t = lastSync.$1;
    final when =
        '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return hasPending
        ? '有新数据待同步 · 上次同步：$when'
        : '$when · ${lastSync.$2}';
  }

  static Future<void> recordLastSync(String summary) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kLastSyncAt,
      DateTime.now().toIso8601String(),
    );
    await prefs.setString(kLastSyncSummary, summary);
  }
}

/// 同步结果：ok + 一句话结论 + 分项统计（UI 状态区展开显示）
class CloudSyncResult {
  const CloudSyncResult({
    required this.ok,
    required this.message,
    this.details = const [],
  });

  final bool ok;
  final String message;
  final List<String> details;

  /// 下拉刷新的结果一句话（随手记 SnackBar / 悬浮窗原生 Toast 共用）：
  /// 成功且无新增 → 明确告知云端一致；有新增 → 带分项统计；失败 → 友好错误
  String get pullRefreshMessage => ok
      ? (details.isEmpty ? '同步完成，云端与本地一致' : '同步完成：${details.join('，')}')
      : message;
}

class CloudSyncService {
  CloudSyncService({
    required this.dbHelper,
    required this.processor,
    WebDavRequestCounter? requestCounter,
  }) : requestCounter = requestCounter ?? WebDavRequestCounter.instanceOrNull;

  final DbHelper dbHelper;
  final TextProcessor processor;

  /// 本机请求预算（两个 engine 共用同一类、各自一份日志）。
  /// 未初始化（单测/降级）时为 null，联网照常但只能靠服务器 429 兜底。
  final WebDavRequestCounter? requestCounter;

  /// 防并发重入（手动按钮双击 / 多处入口）
  static bool _syncing = false;
  static bool get isSyncing => _syncing;

  webdav.Client? _client;
  String _base = '';

  // ---------- 公开入口 ----------

  /// 手动同步主流程：读清单 → 软锁 → 下载合并 → 全量回传 → 解锁。
  /// 失败时尽力释放软锁，避免死锁卡住下次同步（超时兜底 10 分钟）
  Future<CloudSyncResult> sync() async {
    if (_syncing) {
      return const CloudSyncResult(ok: false, message: '已有同步在进行中');
    }
    _syncing = true;
    bool lockAcquired = false;
    SyncManifest? v1Manifest;
    try {
      final config = await CloudSyncConfig.load();
      if (!config.isConfigured) {
        return const CloudSyncResult(ok: false, message: '请先填写服务器地址、账号和应用密码');
      }
      _client = createClient(config);
      _client!.setConnectTimeout(15000);
      _client!.setSendTimeout(120000);
      _client!.setReceiveTimeout(120000);

      _base = _normalizeBase(config.remotePath);
      log('[云同步] 开始：$_base（设备 ${await CloudSyncConfig.deviceId()}）');

      await _client!.ping();
      await _ensureRemoteDir();

      // 1. 读 v1/v2 清单 + 软锁。v2 版本守卫放在拿锁之前：远端要求更高
      //    读取版本时直接中止，绝不向新命名空间写入旧格式数据
      v1Manifest = await _tryReadManifest();
      final manifest = v1Manifest;
      final rawV2Manifest = await _tryRead('$_base/v2/manifest.json');
      final v2Manifest = V2Manifest.tryParse(rawV2Manifest);
      v2Manifest?.ensureSupported();
      final myDevice = await CloudSyncConfig.deviceId();
      final lock = manifest?.lock;
      if (lock != null &&
          lock.deviceId != myDevice &&
          !lock.isStale(DateTime.now())) {
        final msg = '另一台设备正在同步（${_shortDevice(lock.deviceId)}），请稍后再试';
        log('[云同步] 跳过：$msg');
        return CloudSyncResult(ok: false, message: msg);
      }
      await _writeManifest(
        lock: SyncLock(deviceId: myDevice, at: DateTime.now().toIso8601String()),
        deviceId: myDevice,
        counts: manifest?.counts ?? const {},
        previous: manifest?.raw,
      );
      lockAcquired = true;

      // 2. 下载 + 合并：日记走 v2 三方合并（编辑/删除传播），物品仍为
      //    新增并集；v1 diary.json 作为旧客户端投影继续读写
      final stats = <String>[];
      await dbHelper.ensureSyncUuids();
      final tombstones = await dbHelper.loadSyncTombstones();

      final rawDiary = await _tryRead('$_base/diary.json');
      final remoteDiary = decodeDiaryEntries(rawDiary ?? '[]');
      final rawItems = await _tryRead('$_base/items.json');
      final remoteItems = decodeItemEntries(rawItems ?? '[]');
      final rawV2Notes = await _tryRead('$_base/v2/notes.json');
      final rawV2Tombstones = await _tryRead('$_base/v2/tombstones.json');
      final remoteV2Notes = parseNotesV2(rawV2Notes);
      final remoteV2Tombstones = parseTombstonesV2(rawV2Tombstones);
      if (remoteV2Notes.skipped > 0) {
        stats.add('跳过 ${remoteV2Notes.skipped} 条无法解析的云端笔记');
      }

      // 物品：v1 新增并集（v2 items 尚未落地，边界见架构文档）
      stats.addAll(await mergeDownloadedText(
        remoteDiary: const [],
        remoteItems: remoteItems,
        tombstones: tombstones,
      ));
      final v2Merged = await mergeLocalDiariesV2(
        remoteDiary: remoteDiary,
        remoteNotes: remoteV2Notes,
        remoteTombstones: remoteV2Tombstones,
        stats: stats,
      );

      // 热词：行级并集（本地同错词规则优先）
      int hotwordAdded = 0;
      final remoteHotwords = await _tryRead('$_base/hotwords.txt');
      if (remoteHotwords != null) {
        final localHotwords = await processor.getLocalContent();
        final merged = mergeHotwordContent(localHotwords, remoteHotwords);
        if (merged != localHotwords) {
          await processor.saveContent(merged);
          hotwordAdded =
              countHotwordRules(merged) - countHotwordRules(localHotwords);
          if (hotwordAdded > 0) stats.add('下载热词 $hotwordAdded 条');
        }
      }

      // 修正对：行级合并（hit_count 取大、last_used_at 取新），DB 事务内裁决
      final rawPairs = await _tryRead('$_base/correction_pairs.json');
      final remotePairs = decodePairEntries(rawPairs ?? '[]');
      final pairChanged = await dbHelper.mergeRemoteCorrectionPairs(
        remotePairs.map((e) => e.toDbRow()).toList(),
      );
      if (pairChanged > 0) stats.add('合并修正对 $pairChanged 条');

      // 2.5 发布 v2 合并结果（与电脑端同一份契约）：notes 全量、墓碑全量、
      //     最后写 manifest。内容没变不 PUT，避免刷 ETag 触发对端空跑
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sortedNotes = v2Merged.notes.values.toList()
        ..sort((a, b) {
          final byCreated = a.createdAtMs.compareTo(b.createdAtMs);
          return byCreated != 0 ? byCreated : a.uuid.compareTo(b.uuid);
        });
      await _ensureRemoteDirWith(_client!, '$_base/v2');
      await _writeV2IfChanged(
        '$_base/v2/notes.json',
        encodeNotesV2(
          notes: sortedNotes,
          topExtras: remoteV2Notes.topExtras,
          deviceId: myDevice,
          nowMs: nowMs,
        ),
        previousRaw: rawV2Notes,
        ignoreKeys: const {'generated_at', 'device_id'},
        deviceId: myDevice,
      );
      await _writeV2IfChanged(
        '$_base/v2/tombstones.json',
        encodeTombstonesV2(
          tombstones: v2Merged.tombstones.values,
          preservedRows: remoteV2Tombstones.preservedRows,
          topExtras: remoteV2Tombstones.topExtras,
          nowMs: nowMs,
        ),
        previousRaw: rawV2Tombstones,
        ignoreKeys: const {'generated_at', 'device_id'},
        deviceId: myDevice,
      );
      await _writeV2IfChanged(
        '$_base/v2/manifest.json',
        encodeManifestV2(
          previous: v2Manifest,
          deviceId: myDevice,
          nowMs: nowMs,
          counts: {
            'notes': sortedNotes.length,
            'tombstones': v2Merged.tombstones.length,
          },
        ),
        previousRaw: rawV2Manifest,
        ignoreKeys: const {'updated_at', 'device_id'},
        deviceId: myDevice,
      );

      // 录音下载（开关开启才跑）：远端日记带 audio 名且本地缺文件的 →
      // GET 补齐并回填 audio_path。放在全量回传前：回填的行随后随
      // diary.json 上云，第三台设备从云端 JSON 就能看到同名音频可拉。
      // 内部失败只记提示，不拖垮文本同步
      if (config.syncAudio) {
        await _syncAudioDownload(
          remoteDiary: remoteDiary,
          tombstones: tombstones,
          stats: stats,
        );
      }

      // 3. 回传合并后的本地状态（内容没变不 PUT，见 v1FileUnchanged）。
      //    仍是「全量而非增量」：合并后本地 ⊇ 远端，全量即达成并集并顺带
      //    自愈云端历史脏数据——只是省掉了语义上完全一致的无效 PUT
      var skippedV1 = 0;
      final upDiary = await dbHelper.queryAllDiaries();
      skippedV1 += await _writeV1IfChanged(
        '$_base/diary.json',
        encodeDiaryEntries(upDiary),
        previousRaw: rawDiary,
      );
      final upItems = await dbHelper.queryAll();
      skippedV1 += await _writeV1IfChanged(
        '$_base/items.json',
        encodeItemEntries(upItems),
        previousRaw: rawItems,
      );
      final upHotwords = await processor.getLocalContent();
      skippedV1 += await _writeV1IfChanged(
        '$_base/hotwords.txt',
        upHotwords,
        previousRaw: remoteHotwords,
      );
      final upPairs = await dbHelper.getAllCorrectionPairRows();
      skippedV1 += await _writeV1IfChanged(
        '$_base/correction_pairs.json',
        encodePairRows(upPairs),
        previousRaw: rawPairs,
      );
      if (skippedV1 > 0) {
        log('[云同步] v1 数据文件 $skippedV1 个内容未变，跳过回传');
      }

      // 录音上传（开关开启才跑）：本地有 audio 文件的行按云端
      // audio_index.json 去重后分批 PUT。内部失败只记提示，不拖垮文本同步
      if (config.syncAudio) {
        await _syncAudioUpload(diaryRows: upDiary, stats: stats);
      }

      // 截图附件：image_index.json + v2/assets/（电脑端内容寻址资产目录），
      // 手机 → 电脑单向；内部失败只记提示，不拖垮文本同步
      await _syncImages(
        myDevice: myDevice,
        diaryRows: upDiary,
        stats: stats,
      );

      // 4. 解锁 + 记录清单 + 快照「已同步数据版本」（入口行待同步检测基线：
      //    必须在全部合并/上传完成后快照，之后用户再改数据才会重新出现待同步）
      final counts = {
        'diary': upDiary.length,
        'items': upItems.length,
        'correction_pairs': upPairs.length,
      };
      await _writeManifest(
        lock: null,
        deviceId: myDevice,
        counts: counts,
        previous: manifest?.raw,
      );
      lockAcquired = false;
      await CloudSyncDataVersion.markSynced();

      final summary = stats.isEmpty ? '云端与本地一致，无新数据' : stats.join('，');
      log('[云同步] 完成：$summary（上传 日记${upDiary.length}/物品${upItems.length}/修正对${upPairs.length}/热词${countHotwordRules(upHotwords)}）');
      await CloudSyncConfig.recordLastSync(summary);
      return CloudSyncResult(ok: true, message: '同步完成', details: stats);
    } catch (e, st) {
      log('[云同步] ❌ 失败：$e\n$st');
      // 尽力释放软锁，避免本次失败卡死下次同步（死锁 10 分钟自动过期兜底）
      if (lockAcquired) {
        try {
          final myDevice = await CloudSyncConfig.deviceId();
          await _writeManifest(
            lock: null,
            deviceId: myDevice,
            counts: const {},
            previous: v1Manifest?.raw,
          );
        } catch (e2) {
          log('[云同步] 释放软锁失败（等待超时自动过期）：$e2');
        }
      }
      return CloudSyncResult(ok: false, message: _friendlyError(e));
    } finally {
      // webdav_client 未暴露 close，底层 WdDio 即 Dio 实例，直接释放连接
      _client?.c.close();
      _client = null;
      _syncing = false;
      // 悬浮窗可能同时同步过：把它的日志并进展示口径（读一次文件即可）
      await requestCounter?.refreshOtherEngine();
    }
  }

  /// 唯一的 WebDAV 客户端出口：所有业务方法（ping/readProps/mkdirAll/
  /// read/write…）都经 `WdDio.requestUri`，在这里挂 onRequest 一处即可
  /// 覆盖清单、v1/v2 数据、录音、图片、404 探测与「测试连接」。
  /// 先计数再发送，失败/超时/429 也计入（保守多算好过漏算）。
  @visibleForTesting
  webdav.Client createClient(CloudSyncConfig config) {
    final client = webdav.newClient(
      config.serverUrl.trim(),
      user: config.account.trim(),
      password: config.password,
      debug: false,
    );
    final counter = requestCounter;
    if (counter != null) {
      client.c.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            counter.record();
            handler.next(options);
          },
        ),
      );
    }
    return client;
  }

  /// 只测连通性（配置页「测试连接」按钮）：ping + 确保远端目录存在。
  /// 返回 null = 通过，否则返回友好错误文案
  Future<String?> testConnection() async {
    webdav.Client? client;
    try {
      final config = await CloudSyncConfig.load();
      if (!config.isConfigured) return '请先填写服务器地址、账号和应用密码';
      client = createClient(config);
      client.setConnectTimeout(15000);
      client.setReceiveTimeout(30000);
      await client.ping();
      _base = _normalizeBase(config.remotePath);
      await _ensureRemoteDirWith(client, _base);
      return null;
    } catch (e) {
      return _friendlyError(e);
    } finally {
      client?.c.close();
    }
  }

  /// 下载合并的 v1 文本部分：远端日记/物品按 uuid + 自然键去重后落库
  /// （同步主流程与单测共用的纯本地段，不依赖 WebDAV 网络）。日记自 v2
  /// 起改走 [mergeLocalDiariesV2]，主流程只用本方法合并物品。
  ///
  /// 有实际插入才 bump DiarySyncBridge：悬浮窗跑在独立 engine，展开时只
  /// 比对计数才重查库（overlay_home._syncDiariesIfChanged），云同步不 bump
  /// 就会出现「电脑端同步来的日记随手记可见、悬浮窗一直不刷新」。
  /// 返回统计文案（无插入返回空）。
  @visibleForTesting
  Future<List<String>> mergeDownloadedText({
    required List<DiarySyncEntry> remoteDiary,
    required List<ItemSyncEntry> remoteItems,
    required Set<String> tombstones,
  }) async {
    // 日记：uuid 未命中本地且未命中自然键（content|created_at）才插入
    final diaryInserts = planDiaryInserts(
      localRows: await dbHelper.queryAllDiaries(),
      remoteEntries: remoteDiary,
      tombstones: tombstones,
    );
    await dbHelper.insertRemoteDiaries(
      diaryInserts.map((e) => e.toRow()).toList(),
    );

    // 物品：同日记
    final itemInserts = planItemInserts(
      localRows: await dbHelper.queryAll(),
      remoteEntries: remoteItems,
      tombstones: tombstones,
    );
    await dbHelper.insertRemoteItems(
      itemInserts.map((e) => e.toRow()).toList(),
    );

    if (diaryInserts.isNotEmpty || itemInserts.isNotEmpty) {
      await DiarySyncBridge.bump();
    }
    return [
      if (diaryInserts.isNotEmpty) '下载日记 ${diaryInserts.length} 条',
      if (itemInserts.isNotEmpty) '下载物品 ${itemInserts.length} 条',
    ];
  }

  /// v2 日记合并落库（不含网络）：本地行 + 透传元数据 vs 远端 notes /
  /// tombstones 三方裁决后写回 DB，返回合并结果供调用方发布到云端。
  ///
  /// 与电脑端同一顺序：先把 v1 投影里「本地没有」的笔记按自然键/墓碑
  /// 过滤成导入候选（同 uuid 有 v2 记录时优先采用更完整的 v2），再做
  /// 三方合并。手机首次接 v2 时 meta 为空，本地笔记用远端同 uuid 记录做
  /// seed（标签/图片/未知字段），避免载荷差异被误判成本地编辑而覆盖电脑端。
  @visibleForTesting
  Future<V2MergeOutput> mergeLocalDiariesV2({
    required List<DiarySyncEntry> remoteDiary,
    required V2NotesParseResult remoteNotes,
    required V2TombstonesParseResult remoteTombstones,
    required List<String> stats,
  }) async {
    final meta = await dbHelper.loadSyncNoteMeta();
    final localRows = await dbHelper.queryAllDiaries();
    final tombstoneRows = await dbHelper.loadSyncTombstoneRows();
    final localTombstones = <String, V2Tombstone>{
      for (final entry in tombstoneRows.entries)
        if (entry.value['kind'] == 'diary')
          entry.key: V2Tombstone(
            uuid: entry.key,
            deletedAtMs: parseIsoMillis(entry.value['deleted_at']) ?? 0,
          ),
    };
    final remoteByUuid = {
      for (final note in remoteNotes.notes) note.uuid: note,
    };

    // 本地笔记：有 meta 用 meta 的透传字段；首次接 v2（meta 为空）用远端
    // 同 uuid 记录做 seed，保住电脑端标签/图片/未知字段
    final localNotes = <V2Note>[];
    for (final row in localRows) {
      final uuid = (row['sync_uuid'] as String?) ?? '';
      if (uuid.isEmpty) continue;
      final noteMeta = meta[uuid];
      localNotes.add(
        noteFromDiaryRow(
          row,
          meta: noteMeta,
          seed: noteMeta == null ? remoteByUuid[uuid] : null,
        ),
      );
    }

    // v1 投影导入：自然键去重 + 墓碑过滤；同 uuid 的 v2 记录更完整时用它
    final v1Imports = planDiaryInserts(
      localRows: localRows,
      remoteEntries: remoteDiary,
      tombstones: {...localTombstones.keys, ...remoteTombstones.tombstones.keys},
    );
    final importedNotes = <V2Note>[];
    for (final entry in v1Imports) {
      final fromV1 = _noteFromV1Entry(entry);
      final richer = remoteByUuid[entry.uuid];
      importedNotes.add(
        richer != null && richer.updatedAtMs >= fromV1.updatedAtMs
            ? richer
            : fromV1,
      );
    }

    final bases = <String, String>{
      for (final entry in meta.entries)
        if (entry.value['base_hash'] is String &&
            (entry.value['base_hash'] as String).isNotEmpty)
          entry.key: entry.value['base_hash'] as String,
    };
    final merged = mergeV2Notes(
      V2MergeInput(
        localNotes: [...localNotes, ...importedNotes],
        localTombstones: localTombstones,
        remoteNotes: remoteNotes.notes,
        remoteTombstones: remoteTombstones.tombstones,
        bases: bases,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    // 只有落库字段真的变了才算「更新」；仅基线变化不打扰用户
    final localByUuid = <String, Map<String, dynamic>>{
      for (final row in localRows)
        if ((row['sync_uuid'] as String?)?.isNotEmpty ?? false)
          row['sync_uuid'] as String: row,
    };
    final upserts = <Map<String, dynamic>>[];
    var newCount = 0;
    var updatedCount = 0;
    for (final note in merged.notes.values) {
      final patch = diaryRowFromV2Note(note);
      final row = localByUuid[note.uuid];
      if (row == null) {
        upserts.add(patch);
        // 冲突副本是本机裁决产物，不计入「下载日记」
        if (note.extras['conflict_of'] is! String) newCount++;
      } else if (_diaryRowDiffers(row, patch)) {
        upserts.add(patch);
        updatedCount++;
      }
    }
    final deletes = <String>[
      for (final uuid in localByUuid.keys)
        if (!merged.notes.containsKey(uuid) &&
            merged.tombstones.containsKey(uuid))
          uuid,
    ];
    final metaRows = [
      for (final note in merged.notes.values)
        metaRowFromV2Note(note, baseHash: note.payloadHash),
    ];
    await dbHelper.applySyncV2Notes(
      upserts: upserts,
      deletes: deletes,
      metaRows: metaRows,
    );

    // 远端墓碑落库（截图清理/v1 导入过滤都读它）；复活的那批清掉本地残留
    final remoteTombstonesByUuid = <String, int>{
      for (final item in remoteTombstones.tombstones.values)
        item.uuid: item.deletedAtMs,
    };
    await dbHelper.applyRemoteTombstones({
      for (final entry in remoteTombstonesByUuid.entries)
        if (merged.tombstones.containsKey(entry.key)) entry.key: entry.value,
    });
    await dbHelper.removeSyncTombstones([
      for (final uuid in remoteTombstonesByUuid.keys)
        if (!merged.tombstones.containsKey(uuid)) uuid,
    ]);

    if (upserts.isNotEmpty || deletes.isNotEmpty) {
      await DiarySyncBridge.bump();
    }

    if (newCount > 0) stats.add('下载日记 $newCount 条');
    if (updatedCount > 0) stats.add('更新日记 $updatedCount 条');
    if (deletes.isNotEmpty) stats.add('删除日记 ${deletes.length} 条');
    if (merged.conflictCopies > 0) {
      stats.add('保留冲突副本 ${merged.conflictCopies} 条');
    }
    log(
      '[云同步] v2 合并：新增 $newCount，更新 $updatedCount，删除 ${deletes.length}，'
      '冲突副本 ${merged.conflictCopies}，墓碑 ${merged.tombstones.length}',
    );
    return merged;
  }

  /// v1 投影条目 → v2 笔记（v2 没有同 uuid 记录时的导入兜底）。
  /// updated_at 取 created_at：v1 无编辑时间，不能凭空压过电脑端真实编辑
  V2Note _noteFromV1Entry(DiarySyncEntry entry) {
    final createdAtMs = parseIsoMillis(entry.createdAt) ?? 0;
    final audioName = entry.audioName;
    return V2Note(
      uuid: entry.uuid,
      content: entry.content,
      createdAtMs: createdAtMs,
      updatedAtMs: createdAtMs,
      mark: entry.tag,
      archived: entry.isArchived,
      locked: entry.isLocked,
      sortOrder: entry.sortOrder,
      attachments: [
        if (audioName != null && isSafeAudioName(audioName))
          V2Attachment(
            uuid: audioAttachmentUuid(entry.uuid, audioName),
            kind: 'audio',
            origin: 'download',
            name: audioName,
            durationMs: entry.duration == null
                ? null
                : entry.duration! * 1000,
          ),
      ],
    );
  }

  /// 本地行与 v2 目标行的落库字段是否有实际差异。排序按
  /// applySyncV2Notes 的真实语义比较：归档恒 null；远端没给顺序时保留本机
  bool _diaryRowDiffers(
    Map<String, dynamic> local,
    Map<String, dynamic> patch,
  ) {
    if ((local['content'] as String? ?? '') !=
        (patch['content'] as String? ?? '')) {
      return true;
    }
    if (_localMillis(local['created_at']) !=
        _localMillis(patch['created_at'])) {
      return true;
    }
    // duration 只随录音附件有意义：无音频时 0 与 null 等价，避免老数据
    // （内置说明卡片 duration=0）每次同步都被判成变更
    if ((local['duration'] as int? ?? 0) !=
        (patch['duration'] as int? ?? 0)) {
      return true;
    }
    if ((local['is_archived'] as int? ?? 0) !=
        (patch['is_archived'] as int? ?? 0)) {
      return true;
    }
    if ((local['is_locked'] as int? ?? 0) !=
        (patch['is_locked'] as int? ?? 0)) {
      return true;
    }
    if ((local['tag'] as String?) != (patch['tag'] as String?)) return true;
    var effectiveOrder = local['sort_order'] as int?;
    if ((patch['is_archived'] as int? ?? 0) != 0) {
      effectiveOrder = null;
    } else if (patch['sort_order'] is int) {
      effectiveOrder = patch['sort_order'] as int;
    }
    if ((local['sort_order'] as int?) != effectiveOrder) return true;
    final localUpdated =
        (local['updated_at'] as int?) ?? _localMillis(local['created_at']);
    final patchUpdated =
        (patch['updated_at'] as int?) ?? _localMillis(patch['created_at']);
    return localUpdated != patchUpdated;
  }

  /// 本地无 Z 时间字符串 → 毫秒瞬时（比较用，统一按本机时区解释）
  static int _localMillis(Object? value) {
    if (value is! String || value.trim().isEmpty) return 0;
    return DateTime.tryParse(value.trim())?.millisecondsSinceEpoch ?? 0;
  }

  // ---------- 内部工具 ----------

  /// 远端根目录规整：保证前导 /、去掉尾部 /；空值回默认目录
  String _normalizeBase(String raw) {
    var base = raw.trim();
    if (base.isEmpty) base = CloudSyncConfig.defaultRemotePath;
    if (!base.startsWith('/')) base = '/$base';
    return base.replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> _ensureRemoteDir() => _ensureRemoteDirWith(_client!, _base);

  /// 目录不存在则递归创建（readProps 404 → mkdirAll；已存在直接放行）。
  /// mkdirAll 对已存在目录在部分服务端会报错，所以先探测再创建
  Future<void> _ensureRemoteDirWith(webdav.Client client, String path) async {
    try {
      await client.readProps(path);
      return;
    } catch (_) {
      await client.mkdirAll(path);
    }
  }

  Future<SyncManifest?> _tryReadManifest() async {
    final raw = await _tryRead('$_base/manifest.json');
    if (raw == null) return null;
    return SyncManifest.tryParse(raw);
  }

  Future<void> _writeManifest({
    required SyncLock? lock,
    required String deviceId,
    required Map<String, int> counts,
    Map<String, dynamic>? previous,
  }) async {
    final m = SyncManifest(
      deviceId: deviceId,
      updatedAt: DateTime.now().toIso8601String(),
      lock: lock,
      counts: counts,
    );
    // 先铺远端原字段再覆盖本机字段：电脑端/未来版本加的清单字段不能被
    // 手机整包重写抹掉（与 v2 清单同一保真原则）
    final json = <String, dynamic>{...?previous, ...m.toJson()};
    await _client!.write('$_base/manifest.json', utf8.encode(jsonEncode(json)));
  }

  /// v2 文件写入：内容（除生成时间/写入设备与本机 writers.last_seen）没变
  /// 就不 PUT，避免每次同步刷新 ETag 触发电脑端空跑一轮
  Future<void> _writeV2IfChanged(
    String path,
    Map<String, dynamic> next, {
    required String? previousRaw,
    required Set<String> ignoreKeys,
    required String deviceId,
  }) async {
    Object? previous;
    if (previousRaw != null && previousRaw.trim().isNotEmpty) {
      try {
        previous = jsonDecode(previousRaw);
      } catch (_) {
        previous = null;
      }
    }
    if (sameV2Content(
      previous,
      next,
      ignoreKeys: ignoreKeys,
      deviceId: deviceId,
    )) {
      return;
    }
    await _client!.write(path, utf8.encode(jsonEncode(next)));
  }

  /// v1 数据文件写入：内容没变则跳过 PUT 并返回 1（供调用方计数日志），
  /// 实际写了返回 0。老版本 App 只认 v1，这些文件必须继续回传，省不掉
  /// 「写」只能省掉「重复写同一份内容」
  Future<int> _writeV1IfChanged(
    String path,
    String next, {
    required String? previousRaw,
  }) async {
    if (v1FileUnchanged(previousRaw: previousRaw, next: next)) return 1;
    await _client!.write(path, utf8.encode(next));
    return 0;
  }

  /// 「云端现有内容 == 本机待回传内容」判断（纯函数，单测覆盖）：
  /// - 逐字符相同 → 未变（hotwords.txt 这类纯文本走这条）
  /// - 否则两侧都能解析成 JSON → 递归排序对象键后比（另一端写的键序/
  ///   缩进差异不该被当成变更；**数组顺序参与比较**，行序真变了就 PUT，
  ///   宁可多写一次也不漏写）
  /// - previousRaw 为 null（首次同步云端还没这个文件）恒为「有变」
  /// - 云端文件解析失败 → 按「有变」整包覆盖（本机是合并后的超集）
  @visibleForTesting
  static bool v1FileUnchanged({
    required String? previousRaw,
    required String next,
  }) {
    if (previousRaw == null) return false;
    if (previousRaw == next) return true;
    try {
      return sameJsonContent(jsonDecode(previousRaw), jsonDecode(next));
    } catch (_) {
      return false;
    }
  }

  /// 读文件，404 返回 null（首次同步云端还没有数据文件属正常），
  /// 其余错误向上抛
  Future<String?> _tryRead(String path) async {
    try {
      final bytes = await _client!.read(path);
      return utf8.decode(bytes);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 读二进制文件（录音本体用），404 返回 null，其余错误向上抛
  Future<List<int>?> _tryReadBytes(String path) async {
    try {
      return await _client!.read(path);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // ---------- 录音文件同步（开关开启才跑，docs/architecture/cloud-sync.md） ----------

  /// 本地录音目录（与 diary_tab._writeWavFile / overlay_voice_memo 落盘
  /// 同一个 diary_audio/，悬浮窗录的音也在里面）
  Future<Directory> _audioDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'diary_audio'));
  }

  /// 下载侧：远端 diary.json 里带 audio 名、本地缺文件的 → 逐个 GET 到
  /// diary_audio/ 并回填该行 audio_path。任何失败只记 stats 提示，同步
  /// 整体继续（音频是补齐性质，文本成功不该被它否决）
  Future<void> _syncAudioDownload({
    required List<DiarySyncEntry> remoteDiary,
    required Set<String> tombstones,
    required List<String> stats,
  }) async {
    try {
      final dir = await _audioDir();
      final localNames = <String>{
        if (dir.existsSync())
          for (final f in dir.listSync())
            if (f is File) p.basename(f.path),
      };
      final (batch, overflow) = planAudioDownloads(
        remoteEntries: remoteDiary,
        localExistingNames: localNames,
        tombstones: tombstones,
      );
      if (batch.isEmpty) return;
      if (!dir.existsSync()) dir.createSync(recursive: true);

      int done = 0, missing = 0;
      for (final item in batch) {
        final bytes = await _tryReadBytes('$_base/audio/${item.name}');
        if (bytes == null) {
          // 云端 diary.json 声称有音频但 audio/ 里没有（上传中断残留/
          // 网盘端被手动清理），跳过不算错
          missing++;
          continue;
        }
        final localPath = p.join(dir.path, item.name);
        await File(localPath).writeAsBytes(bytes, flush: true);
        await dbHelper.updateDiaryAudioPathByUuid(item.uuid, localPath);
        done++;
      }
      if (done == 0 && missing == 0 && overflow == 0) return;
      var msg = '下载录音 $done 条';
      if (missing > 0) msg += '（$missing 个云端缺失跳过）';
      if (overflow > 0) msg += '，还有 $overflow 条待下次同步';
      stats.add(msg);
      log('[云同步] 录音下载：done=$done missing=$missing overflow=$overflow');
    } catch (e, st) {
      log('[云同步] ⚠️ 录音下载失败（不影响文本同步）：$e\n$st');
      stats.add('录音下载部分失败，下次同步续传');
    }
  }

  /// 上传侧：本地行 audio_path 指向且文件实际存在的 → 与云端
  /// audio_index.json 求差后分批 PUT，成功的逐个记入索引（中途失败也要
  /// 把已成功部分落盘，防下次重传；重传本身幂等，只是浪费流量）。任何
  /// 失败只记 stats 提示，同步整体继续
  Future<void> _syncAudioUpload({
    required List<Map<String, dynamic>> diaryRows,
    required List<String> stats,
  }) async {
    // 声明在 try 外：catch 里要尽力把已成功部分回写云端索引
    List<String> uploadedIndex = const [];
    try {
      final localNames = <String>[];
      for (final r in diaryRows) {
        final ap = r['audio_path'] as String?;
        if (ap == null || ap.isEmpty) continue;
        final f = File(ap);
        if (!f.existsSync()) continue;
        localNames.add(p.basename(ap));
      }
      uploadedIndex = decodeStringList(
        await _tryRead('$_base/audio_index.json') ?? '[]',
      );
      final (batch, overflow) = planAudioUploads(
        localAudioNames: localNames,
        uploadedIndex: uploadedIndex.toSet(),
      );
      if (batch.isEmpty) return;

      final dir = await _audioDir();
      await _ensureRemoteDirWith(_client!, '$_base/audio');
      int done = 0;
      for (final name in batch) {
        final bytes = await File(p.join(dir.path, name)).readAsBytes();
        await _client!.write('$_base/audio/$name', bytes);
        uploadedIndex.add(name);
        done++;
      }
      await _client!.write(
        '$_base/audio_index.json',
        utf8.encode(jsonEncode(uploadedIndex)),
      );
      var msg = '上传录音 $done 条';
      if (overflow > 0) msg += '，还有 $overflow 条待下次同步';
      stats.add(msg);
      log('[云同步] 录音上传：done=$done overflow=$overflow index=${uploadedIndex.length}');
    } catch (e, st) {
      log('[云同步] ⚠️ 录音上传失败（不影响文本同步）：$e\n$st');
      try {
        await _client!.write(
          '$_base/audio_index.json',
          utf8.encode(jsonEncode(uploadedIndex)),
        );
      } catch (e2) {
        // 索引没落盘的后果只是下次同步重传已成功文件（PUT 幂等），无害
        log('[云同步] 录音索引回写失败：$e2');
      }
      stats.add('录音上传部分失败，下次同步续传');
    }
  }

  // ---------- 图片附件同步（双向，docs/architecture/cloud-sync.md） ----------

  /// 本地截图目录（与悬浮窗截屏落盘同一个 diary_images/）
  Future<Directory> _imageDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'diary_images'));
  }

  /// 图片同步：索引走根目录 image_index.json，图片本体写电脑端已有的
  /// 内容寻址目录 `v2/assets/<sha 前两位>/<sha>.<ext>`。
  ///
  /// 手机上送：本地自拍截图且云端缺对应 sha 的 → 分批 PUT，成功的才发布
  /// 索引条目（避免电脑端按索引拉到不存在的资产）；上传失败/超限保留本机
  /// 旧条目，不让电脑端丢掉上一张还能看的图。手机下收：其他设备（电脑端）
  /// 发布的图片按 (note, device, sha) 补齐到 diary_images，多张全部保留；
  /// 本机截图丢失时按索引恢复一张到 image_path。任何失败只记提示，不拖垮
  /// 文本同步。
  Future<void> _syncImages({
    required String myDevice,
    required List<Map<String, dynamic>> diaryRows,
    required List<String> stats,
  }) async {
    try {
      final rawIndex = await _tryRead('$_base/image_index.json');
      List<ImageSyncEntry> remoteIndex;
      if (rawIndex == null) {
        remoteIndex = const [];
      } else {
        final decoded = tryDecodeImageEntries(rawIndex);
        if (decoded == null) {
          // 索引损坏按「不可用」处理：绝不能当成空索引回写，否则会抹掉
          // 其它手机已发布的条目
          log('[云同步] ⚠️ image_index.json 不是合法索引，本次跳过截图同步');
          stats.add('截图索引损坏，本次未同步截图');
          return;
        }
        remoteIndex = decoded;
      }

      final tombstones = await dbHelper.loadSyncTombstones();
      final localUuids = <String>{
        for (final row in diaryRows)
          if ((row['sync_uuid'] as String?)?.isNotEmpty ?? false)
            row['sync_uuid'] as String,
      };

      // 1. 汇总本地截图（每行最多一张；下载来的 diary_sync_* 副本不再
      //    以自己的设备身份转发，否则来源设备换图后旧图会被复活）
      final localImages = <String, ({ImageSyncEntry entry, File file})>{};
      final keepOwnFor = <String>{}; // 本轮不发布本机条目（保留云端旧条目）
      var unsupported = 0;
      for (final row in diaryRows) {
        final uuid = (row['sync_uuid'] as String?) ?? '';
        final path = row['image_path'] as String?;
        if (uuid.isEmpty || path == null || path.isEmpty) continue;
        if (p.basename(path).startsWith('diary_sync_')) continue;
        final file = File(path);
        if (!file.existsSync()) {
          // 索引有、文件丢了（清理/迁移残留）：保留云端旧条目
          keepOwnFor.add(uuid);
          continue;
        }
        final size = await file.length();
        if (size <= 0 || size > kMaxSyncedImageBytes) {
          unsupported++;
          keepOwnFor.add(uuid);
          continue;
        }
        final bytes = await file.readAsBytes();
        final extension = detectImageExtension(bytes);
        if (extension == null) {
          unsupported++;
          keepOwnFor.add(uuid);
          continue;
        }
        final sha = sha256.convert(bytes).toString();
        localImages[uuid] = (
          entry: ImageSyncEntry(
            noteUuid: uuid,
            deviceId: myDevice,
            sha256: sha,
            name: '$sha.$extension',
            mimeType: imageMimeType(extension),
            byteSize: bytes.length,
            updatedAt: (await file.lastModified()).toUtc().toIso8601String(),
          ),
          file: file,
        );
      }

      // 已下载的电脑端多图行：参与幂等判断、失效行清理与补下决策
      final localImageRows = await dbHelper.loadDiaryImageRows();

      if (localImages.isEmpty &&
          remoteIndex.isEmpty &&
          localImageRows.isEmpty) {
        return;
      }

      // 2. 远端协议保护：电脑端要求的最低读取版本更高时不写新命名空间
      final rawV2Manifest = await _tryRead('$_base/v2/manifest.json');
      if (rawV2Manifest != null && rawV2Manifest.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(rawV2Manifest);
          final minReader = decoded is Map ? decoded['min_reader_version'] : null;
          if (minReader is num && minReader.toInt() > kImageSyncProtocolVersion) {
            log('[云同步] 远端要求协议 v${minReader.toInt()}，跳过截图同步');
            stats.add('云端同步协议版本较高，本次未同步截图');
            return;
          }
        } on FormatException catch (e) {
          // 清单坏了不猜规则，交给文本同步去报错；截图本轮不动
          log('[云同步] ⚠️ v2/manifest.json 解析失败，跳过截图同步：$e');
          return;
        }
      }

      // 3. 上传缺失资产（内容寻址：远端索引里已有同 sha 就视为已存在）
      final knownShas = <String>{
        for (final entry in remoteIndex)
          if (entry.isValid) entry.sha256,
      };
      final pending = <String>[
        for (final item in localImages.entries)
          if (!knownShas.contains(item.value.entry.sha256)) item.key,
      ];
      final uploadBatch = pending.take(kImageSyncBatchLimit).toList();
      final uploadOverflow = pending.length - uploadBatch.length;
      for (final uuid in pending.skip(kImageSyncBatchLimit)) {
        keepOwnFor.add(uuid);
      }

      final ensuredDirs = <String>{};
      var uploaded = 0;
      var uploadFailed = 0;
      for (final uuid in uploadBatch) {
        final item = localImages[uuid]!;
        final entry = item.entry;
        final sha = entry.sha256;
        if (knownShas.contains(sha)) continue; // 同 sha 的多条笔记只传一次
        try {
          final prefix = sha.substring(0, 2);
          if (ensuredDirs.add(prefix)) {
            await _ensureRemoteDirWith(_client!, '$_base/v2/assets/$prefix');
          }
          final bytes = await item.file.readAsBytes();
          if (sha256.convert(bytes).toString() != sha) {
            // 同步期间又被新截图替换了，下一轮再传
            keepOwnFor.add(uuid);
            continue;
          }
          await _client!.write('$_base/${entry.remotePath}', bytes);
          knownShas.add(sha);
          uploaded++;
        } catch (e, st) {
          keepOwnFor.add(uuid);
          uploadFailed++;
          log('[云同步] ⚠️ 截图上传失败 $uuid：$e\n$st');
        }
      }

      // 4. 合并索引并回写（只发布本轮确认可拉取的条目）
      final localEntries = <ImageSyncEntry>[
        for (final item in localImages.entries)
          if (!keepOwnFor.contains(item.key)) item.value.entry,
      ];
      final merged = mergeImageIndex(
        remote: remoteIndex,
        local: localEntries,
        deviceId: myDevice,
        localNoteUuids: localUuids,
        keepOwnFor: keepOwnFor,
      );
      final mergedText = encodeImageEntries(merged);
      if (rawIndex == null
          ? merged.isNotEmpty
          : mergedText.trim() != rawIndex.trim()) {
        await _client!.write(
          '$_base/image_index.json',
          utf8.encode(mergedText),
        );
      }

      // 5. 对账已下载的电脑端多图：远端已摘掉的条目删行删文件；笔记已在
      //    本地删除（命中墓碑）的清干净。文件丢失的行保留，下面补下会覆盖
      final mergedKeys = {for (final entry in merged) entry.key};
      final existingKeys = <String>{};
      var pruned = 0;
      for (final row in localImageRows) {
        final note = (row['note_uuid'] as String?) ?? '';
        final key = '$note\u0000${row['device_id']}\u0000${row['sha256']}';
        final path = row['image_path'] as String?;
        final fileOk =
            path != null && path.isNotEmpty && File(path).existsSync();
        final noteLocal = localUuids.contains(note);
        final drop = (noteLocal && !mergedKeys.contains(key)) ||
            (!noteLocal && tombstones.contains(note));
        if (drop) {
          await dbHelper.deleteDiaryImageRow(row['id'] as int);
          pruned++;
          if (fileOk) {
            try {
              await File(path).delete();
            } catch (e) {
              log('[云同步] ⚠️ 失效图片文件删除失败（库行已删）：$e');
            }
          }
          continue;
        }
        if (fileOk) existingKeys.add(key);
      }
      if (pruned > 0) await DiarySyncBridge.bump();

      // 6. 下载：其他设备新增/替换/多张图片全部补齐；本机截图丢失时按
      //    索引恢复一张到 image_path；已下载过的 (note, device, sha) 不重下
      final notesWithOwnImage = <String>{};
      for (final row in diaryRows) {
        final uuid = (row['sync_uuid'] as String?) ?? '';
        final path = row['image_path'] as String?;
        if (uuid.isEmpty || path == null || path.isEmpty) continue;
        if (File(path).existsSync()) notesWithOwnImage.add(uuid);
      }
      var downloaded = 0;
      var downloadMissing = 0;
      var downloadInvalid = 0;
      var downloadOverflow = 0;
      {
        final dir = await _imageDir();
        final (batch, overflow) = planImageDownloads(
          remote: merged,
          deviceId: myDevice,
          localNoteUuids: localUuids,
          tombstones: tombstones,
          existingKeys: existingKeys,
          notesWithOwnImage: notesWithOwnImage,
        );
        downloadOverflow = overflow;
        if (batch.isNotEmpty && !dir.existsSync()) {
          await dir.create(recursive: true);
        }
        for (final item in batch) {
          final bytes = await _tryReadBytes(
            '$_base/v2/assets/${item.sha256.substring(0, 2)}/${item.name}',
          );
          if (bytes == null) {
            downloadMissing++;
            continue;
          }
          if (bytes.length > kMaxSyncedImageBytes ||
              sha256.convert(bytes).toString() != item.sha256) {
            downloadInvalid++;
            continue;
          }
          final localPath = p.join(
            dir.path,
            'diary_sync_${item.noteUuid}_${item.sha256}.'
            '${_extensionOfImage(item.name)}',
          );
          await File(localPath).writeAsBytes(bytes, flush: true);
          if (item.deviceId == myDevice) {
            // 本机截图丢失的历史恢复：回到 diary.image_path 单图位
            await dbHelper.updateDiaryImagePathByUuid(item.noteUuid, localPath);
          } else {
            await dbHelper.upsertDiaryImage(
              noteUuid: item.noteUuid,
              deviceId: item.deviceId,
              sha256: item.sha256,
              imagePath: localPath,
              remoteName: item.name,
              position: item.position,
              byteSize: bytes.length,
            );
          }
          downloaded++;
        }
        if (downloaded > 0) await DiarySyncBridge.bump();
      }

      // 7. 统计文案（与录音同步同口径：只报实际发生的动作）
      if (uploaded > 0) {
        var msg = '上传截图 $uploaded 张';
        if (uploadOverflow > 0) msg += '，还有 $uploadOverflow 张待下次同步';
        stats.add(msg);
      }
      if (downloadOverflow > 0 && downloaded == 0) {
        stats.add('截图还有 $downloadOverflow 张待下次同步');
      } else if (downloaded > 0 || downloadMissing > 0 || downloadInvalid > 0) {
        var msg = '下载截图 $downloaded 张';
        if (downloadMissing > 0) msg += '（$downloadMissing 张云端缺失跳过）';
        if (downloadInvalid > 0) msg += '，$downloadInvalid 张校验失败';
        if (downloadOverflow > 0) msg += '，还有 $downloadOverflow 张待下次同步';
        stats.add(msg);
      }
      if (unsupported > 0) {
        stats.add('$unsupported 张截图格式或大小不支持，未同步');
      }
      if (uploadFailed > 0) {
        stats.add('截图上传部分失败，下次同步续传');
      }
      log(
        '[云同步] 截图：上传 $uploaded（失败 $uploadFailed，超限 $uploadOverflow）'
        '下载 $downloaded（缺失 $downloadMissing，校验失败 $downloadInvalid，超限 $downloadOverflow）'
        '索引 ${merged.length} 条，已下载 ${existingKeys.length + downloaded} 张',
      );
    } catch (e, st) {
      log('[云同步] ⚠️ 截图同步失败（不影响文本同步）：$e\n$st');
      stats.add('截图同步失败，下次同步重试');
    }
  }

  static String _extensionOfImage(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension) ? extension : 'jpg';
  }

  // ---------- 通用工具 ----------

  /// 网络异常 → 用户能看懂的文案（坚果云限流/密码错误是最高频两类）
  String _friendlyError(Object e) {
    // v2 清单/数据文件格式错误：抛错方已写好中文原因，直接透出
    if (e is FormatException) return e.message.toString();
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return '登录被拒（HTTP $status）：请检查账号与「应用密码」是否正确';
      }
      if (status == 429) {
        // 本机计数只是参考：账号额度可能已被电脑端/其它客户端耗尽，
        // 即使本机显示还有剩，也可能已经处于封锁期，所以不给「马上能用」
        // 的暗示。超限后坚果云通常封锁数小时。
        final recent = requestCounter?.recentCount;
        final budget = recent == null ? '' : '（本机最近 30 分钟已发出 $recent 次请求）';
        return '请求过于频繁（HTTP 429）：坚果云免费版每 30 分钟限 600 次请求，'
            '超限后可能被封锁数小时，请稍后再试$budget';
      }
      if (status == 507) return '网盘空间不足（HTTP 507）';
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '连接超时：请检查网络与服务器地址';
        case DioExceptionType.connectionError:
          return '无法连接服务器：请检查地址与网络';
        default:
          break;
      }
      if (status != null) return '服务器返回 HTTP $status';
      return '网络错误：${e.message ?? e}';
    }
    return '$e';
  }

  /// 设备标识截短（提示文案里可读即可）
  String _shortDevice(String id) => id.length <= 8 ? id : id.substring(0, 8);
}
