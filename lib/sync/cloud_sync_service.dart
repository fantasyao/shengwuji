import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'sync_merge.dart';
import 'sync_models.dart';

/// WebDAV 云同步服务（P1 手动触发，见 docs/architecture/cloud-sync.md）。
///
/// 云端目录六个文件：manifest.json（软锁+版本+计数）+ diary.json +
/// items.json + hotwords.txt + correction_pairs.json + audio_index.json
/// （录音上传索引），另有 audio/ 子目录（录音本体，开关开启才同步）。
/// 文本每次同步 8~12 个请求；录音按 audio_index.json 去重后分批上传/
/// 下载，单次上限 kAudioSyncBatchLimit 个防坚果云 600 请求/30 分钟限流。
///
/// 合并边界：新增条目双向并集（按 sync_uuid/自然键去重）；编辑、删除
/// 不跨端传播（本地删除靠墓碑防复活）；录音文件走独立开关，默认不同步，
/// 同步失败只记提示不拖垮文本同步。

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
}

class CloudSyncService {
  CloudSyncService({required this.dbHelper, required this.processor});

  final DbHelper dbHelper;
  final TextProcessor processor;

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
    try {
      final config = await CloudSyncConfig.load();
      if (!config.isConfigured) {
        return const CloudSyncResult(ok: false, message: '请先填写服务器地址、账号和应用密码');
      }
      _client = webdav.newClient(
        config.serverUrl.trim(),
        user: config.account.trim(),
        password: config.password,
        debug: false,
      );
      _client!.setConnectTimeout(15000);
      _client!.setSendTimeout(120000);
      _client!.setReceiveTimeout(120000);

      _base = _normalizeBase(config.remotePath);
      log('[云同步] 开始：$_base（设备 ${await CloudSyncConfig.deviceId()}）');

      await _client!.ping();
      await _ensureRemoteDir();

      // 1. 读清单 + 软锁
      final manifest = await _tryReadManifest();
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
      );
      lockAcquired = true;

      // 2. 下载 + 合并（本地为基，远端只补缺）
      final stats = <String>[];
      await dbHelper.ensureSyncUuids();
      final tombstones = await dbHelper.loadSyncTombstones();

      // 日记：uuid 未命中本地且未命中自然键（content|created_at）才插入
      final remoteDiary = decodeDiaryEntries(
        await _tryRead('$_base/diary.json') ?? '[]',
      );
      final diaryInserts = planDiaryInserts(
        localRows: await dbHelper.queryAllDiaries(),
        remoteEntries: remoteDiary,
        tombstones: tombstones,
      );
      await dbHelper.insertRemoteDiaries(
        diaryInserts.map((e) => e.toRow()).toList(),
      );
      if (diaryInserts.isNotEmpty) stats.add('下载日记 ${diaryInserts.length} 条');

      // 物品：同日记
      final remoteItems = decodeItemEntries(
        await _tryRead('$_base/items.json') ?? '[]',
      );
      final itemInserts = planItemInserts(
        localRows: await dbHelper.queryAll(),
        remoteEntries: remoteItems,
        tombstones: tombstones,
      );
      await dbHelper.insertRemoteItems(itemInserts.map((e) => e.toRow()).toList());
      if (itemInserts.isNotEmpty) stats.add('下载物品 ${itemInserts.length} 条');

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
      final remotePairs = decodePairEntries(
        await _tryRead('$_base/correction_pairs.json') ?? '[]',
      );
      final pairChanged = await dbHelper.mergeRemoteCorrectionPairs(
        remotePairs.map((e) => e.toDbRow()).toList(),
      );
      if (pairChanged > 0) stats.add('合并修正对 $pairChanged 条');

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

      // 3. 全量回传合并后的本地状态（自愈：顺带修复云端的历史脏数据）
      final upDiary = await dbHelper.queryAllDiaries();
      await _client!.write('$_base/diary.json', utf8.encode(encodeDiaryEntries(upDiary)));
      final upItems = await dbHelper.queryAll();
      await _client!.write('$_base/items.json', utf8.encode(encodeItemEntries(upItems)));
      final upHotwords = await processor.getLocalContent();
      await _client!.write('$_base/hotwords.txt', utf8.encode(upHotwords));
      final upPairs = await dbHelper.getAllCorrectionPairRows();
      await _client!.write(
        '$_base/correction_pairs.json',
        utf8.encode(encodePairRows(upPairs)),
      );

      // 录音上传（开关开启才跑）：本地有 audio 文件的行按云端
      // audio_index.json 去重后分批 PUT。内部失败只记提示，不拖垮文本同步
      if (config.syncAudio) {
        await _syncAudioUpload(diaryRows: upDiary, stats: stats);
      }

      // 4. 解锁 + 记录清单 + 快照「已同步数据版本」（入口行待同步检测基线：
      //    必须在全部合并/上传完成后快照，之后用户再改数据才会重新出现待同步）
      final counts = {
        'diary': upDiary.length,
        'items': upItems.length,
        'correction_pairs': upPairs.length,
      };
      await _writeManifest(lock: null, deviceId: myDevice, counts: counts);
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
          await _writeManifest(lock: null, deviceId: myDevice, counts: const {});
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
    }
  }

  /// 只测连通性（配置页「测试连接」按钮）：ping + 确保远端目录存在。
  /// 返回 null = 通过，否则返回友好错误文案
  Future<String?> testConnection() async {
    webdav.Client? client;
    try {
      final config = await CloudSyncConfig.load();
      if (!config.isConfigured) return '请先填写服务器地址、账号和应用密码';
      client = webdav.newClient(
        config.serverUrl.trim(),
        user: config.account.trim(),
        password: config.password,
        debug: false,
      );
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
  }) async {
    final m = SyncManifest(
      deviceId: deviceId,
      updatedAt: DateTime.now().toIso8601String(),
      lock: lock,
      counts: counts,
    );
    await _client!.write('$_base/manifest.json', utf8.encode(jsonEncode(m.toJson())));
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

  // ---------- 通用工具 ----------

  /// 网络异常 → 用户能看懂的文案（坚果云限流/密码错误是最高频两类）
  String _friendlyError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return '登录被拒（HTTP $status）：请检查账号与「应用密码」是否正确';
      }
      if (status == 429) {
        return '请求过于频繁（HTTP 429）：坚果云免费版每 30 分钟限 600 次请求，请几分钟后再试';
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
