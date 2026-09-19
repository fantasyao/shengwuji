import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';
import '../db_helper.dart';
import '../utils/diary_sync_bridge.dart';
import 'diary_web_page.dart';

/// 电脑访问服务（日记页内容的局域网 HTTP 服务）
///
/// 固定端口 [defaultPort]（9527）。开启后，同一 Wi-Fi 下的电脑浏览器打开
/// http://手机IP:9527 即可查看全部日记（含录音播放），并支持在电脑上
/// 编辑 / 删除，改动实时写回本 App 数据库；手机端新增/编辑的日记也会经
/// SSE（Server-Sent Events）实时推送到浏览器刷新。
///
/// 端口稳定性策略（start）：
/// 1. 若本进程已有实例在跑，先 stop（幂等重启）；
/// 2. 绑定前探测 `127.0.0.1:9527/__identity`——若响应的是本服务身份标记
///    （另一个残留进程，如引擎重建后的旧实例），向其 `POST /__shutdown`
///    （该端点只接受本机回环请求）关掉旧实例，等端口释放后再绑定；
/// 3. 绑定失败时按"此前是否探测到自家服务"区分报错：自家实例卡死 or
///    端口被其他应用占用。
///
/// 保活：HTTP 服务跑在主 engine 的 Dart isolate 里，进程被冻结即断；
/// 由 DiaryServerService（前台服务，见 android 侧）拉住进程优先级，
/// 开关生命周期见 diary_server_controller.dart。

/// 固定端口（用户指定 9527）
const int kDiaryServerPort = 9527;

/// 身份标记：/__identity 响应中携带，用于端口被占时判断"是不是我们自己的服务"
const String kDiaryServerIdentity = 'shengwuji-diary-web';

/// 电脑访问服务的日记仓储抽象——生产走 DbHelper（SQLite），测试用内存假实现。
/// 只暴露服务需要的最小面，避免服务层直接耦合 sqflite。
abstract class DiaryNoteRepository {
  /// 全量日记（与日记页 getDiaries 同序：活跃在前，组内 created_at 倒序）
  Future<List<Map<String, dynamic>>> getAllNotes();

  /// 按 id 查单条（PUT/DELETE 前定位 audio_path 用）
  Future<Map<String, dynamic>?> getNoteById(int id);

  /// 更新内容，返回受影响行数（0 = id 不存在）
  Future<int> updateContent(int id, String content);

  /// 删除，返回受影响行数（0 = id 不存在）
  Future<int> deleteById(int id);

  /// 廉价变更签名：一次聚合查询（count / maxId / 内容总长 / 归档数）。
  /// 手机端（主 engine 或悬浮窗 engine）任何增删改都会让签名变化，
  /// 服务每秒比对一次，变了就 SSE 推浏览器刷新
  Future<String> changeSignature();
}

/// 生产仓储：包装 DbHelper
class DbDiaryNoteRepository implements DiaryNoteRepository {
  DbDiaryNoteRepository(this._dbHelper);

  final DbHelper _dbHelper;

  @override
  Future<List<Map<String, dynamic>>> getAllNotes() => _dbHelper.getDiaries();

  @override
  Future<Map<String, dynamic>?> getNoteById(int id) =>
      _dbHelper.getDiaryById(id);

  @override
  Future<int> updateContent(int id, String content) =>
      _dbHelper.updateDiary(id, content);

  @override
  Future<int> deleteById(int id) => _dbHelper.deleteDiary(id);

  @override
  Future<String> changeSignature() async {
    final dbClient = await _dbHelper.db;
    final rows = await dbClient.rawQuery(
      'SELECT COUNT(*) AS c, COALESCE(MAX(id), 0) AS m, '
      'COALESCE(SUM(LENGTH(content)), 0) AS s, '
      'COALESCE(SUM(is_archived), 0) AS a FROM diary',
    );
    final r = rows.first;
    return 'c=${r['c']},m=${r['m']},s=${r['s']},a=${r['a']}';
  }
}

/// start() 的结果
enum DiaryServerStartStatus {
  /// 已启动
  started,

  /// 端口被其他应用占用（探测到不是自家服务）
  portBusyByOther,

  /// 自家旧实例占用端口且关停失败（极罕见：shutdown 指令发了但端口未释放）
  ownInstanceStuck,

  /// 其他失败（读目录等）
  failed,
}

class DiaryServerStartResult {
  const DiaryServerStartResult(this.status, {this.errorDetail});

  final DiaryServerStartStatus status;
  final String? errorDetail;

  bool get isSuccess => status == DiaryServerStartStatus.started;

  /// 给用户看的错误文案
  String get userMessage {
    switch (status) {
      case DiaryServerStartStatus.started:
        return '服务已启动';
      case DiaryServerStartStatus.portBusyByOther:
        return '端口 $kDiaryServerPort 被其他应用占用，无法启动电脑访问服务';
      case DiaryServerStartStatus.ownInstanceStuck:
        return '端口 $kDiaryServerPort 被旧服务实例占用且暂时无法释放，请稍后重试';
      case DiaryServerStartStatus.failed:
        return '启动失败${errorDetail == null ? '' : '：$errorDetail'}';
    }
  }
}

/// 服务的日记 JSON 行（⚠️ 不暴露文件系统绝对路径，录音只给 /audio/{id} 相对地址）
Map<String, Object?> diaryNoteToJson(Map<String, dynamic> row) {
  final audioPath = row['audio_path'] as String?;
  final hasAudio = audioPath != null && audioPath.isNotEmpty;
  final archived = row['is_archived'];
  return {
    'id': row['id'],
    'content': (row['content'] as String?) ?? '',
    'createdAt': row['created_at'],
    'duration': row['duration'],
    'isArchived': archived == 1 || archived == true,
    'tag': row['tag'],
    'hasAudio': hasAudio,
    'audioUrl': hasAudio ? '/audio/${row['id']}' : null,
  };
}

/// Range 请求头解析（纯函数，测试锁定）。
/// 返回 null = 无 Range / 不支持的形式 / 越界——调用方一律回 200 全量，
/// 浏览器对 200 全量的处理是安全的（从头播，seek 重下）。
/// 支持 `bytes=a-b`、`bytes=a-`、`bytes=-n`（最后 n 字节）。
({int start, int end})? parseRangeHeader(String? header, int totalSize) {
  if (header == null || totalSize <= 0) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final startStr = m.group(1)!;
  final endStr = m.group(2)!;
  if (startStr.isEmpty && endStr.isEmpty) return null;
  if (startStr.isEmpty) {
    // 后缀形式 bytes=-n：取最后 n 字节
    final n = int.tryParse(endStr);
    if (n == null || n <= 0) return null;
    final start = totalSize - n < 0 ? 0 : totalSize - n;
    return (start: start, end: totalSize - 1);
  }
  final start = int.tryParse(startStr);
  if (start == null || start >= totalSize) return null;
  final end = endStr.isEmpty ? totalSize - 1 : (int.tryParse(endStr) ?? 0);
  if (end < start) return null;
  return (start: start, end: end >= totalSize ? totalSize - 1 : end);
}

/// 按扩展名猜音频 MIME（本 app 录音都是自写 44 字节 header 的 wav，其余兜底）
String audioMimeFor(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.wav':
      return 'audio/wav';
    case '.mp3':
      return 'audio/mpeg';
    case '.m4a':
      return 'audio/mp4';
    case '.aac':
      return 'audio/aac';
    case '.ogg':
      return 'audio/ogg';
    default:
      return 'application/octet-stream';
  }
}

class DiaryWebServer {
  DiaryWebServer({DiaryNoteRepository? repository})
    : _injectedRepository = repository;

  /// 应用全局单例（controller / main.dart 使用）
  static final DiaryWebServer instance = DiaryWebServer();

  final DiaryNoteRepository? _injectedRepository;

  HttpServer? _server;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  bool _polling = false;
  String _lastSignature = '';

  /// SSE 客户端（浏览器 EventSource 连接的 response）
  final Set<HttpResponse> _sseClients = {};

  /// 电脑端（浏览器）发生增删改后递增——main.dart 监听它刷新日记页列表
  final ValueNotifier<int> remoteMutationTick = ValueNotifier<int>(0);

  /// 测试注入：录音目录（生产为 null，懒解析 Documents 目录下的 diary_audio）
  Directory? _audioDirOverride;

  DiaryNoteRepository? _repo;

  bool get isRunning => _server != null;

  /// 实际绑定端口（测试用 0 时为系统分配的临时端口）
  int get boundPort => _server?.port ?? kDiaryServerPort;

  /// 启动服务。幂等：已在跑先停再启。
  /// 可注入 address/port/repository/audioDir（测试用），生产用默认值。
  Future<DiaryServerStartResult> start({
    int port = kDiaryServerPort,
    InternetAddress? address,
    DiaryNoteRepository? repository,
    Directory? audioDir,
    Duration changePollInterval = const Duration(seconds: 1),
    Duration identityProbeTimeout = const Duration(milliseconds: 800),
  }) async {
    final bindAddress = address ?? InternetAddress.anyIPv4;
    log(
      '💻 [WebServer] start()：port=$port, '
      'address=${bindAddress.address}, '
      'poll=${changePollInterval.inMilliseconds}ms',
    );
    // 1. 本进程已有实例 → 先停（幂等重启）
    if (isRunning) {
      log('💻 [WebServer] 服务已在运行，先停止旧实例再重启');
      await stop();
    }

    _repo =
        repository ?? _injectedRepository ?? DbDiaryNoteRepository(DbHelper());
    _audioDirOverride = audioDir;

    // 2. 端口被占检查：探测是不是我们自己的服务，是就先关掉旧实例
    final wasOurs = await _shutdownOwnStaleInstance(port, identityProbeTimeout);
    log('💻 [WebServer] 端口探测完成：wasOurs=$wasOurs，开始绑定');

    // 3. 绑定（⚠️ 必须用 bindAddress（null 时兜底 anyIPv4）——曾有回归：
    //    传了可空的 address，生产默认路径 bind(null) 报
    //    "type 'Null' is not a subtype of type 'String'"）
    HttpServer server;
    try {
      server = await HttpServer.bind(bindAddress, port);
    } on SocketException catch (e) {
      log('💻 [WebServer] 绑定端口 $port 失败: $e（此前探测到自家服务=$wasOurs）');
      _repo = null;
      if (wasOurs) {
        return DiaryServerStartResult(
          DiaryServerStartStatus.ownInstanceStuck,
          errorDetail: e.message,
        );
      }
      return DiaryServerStartResult(
        DiaryServerStartStatus.portBusyByOther,
        errorDetail: e.message,
      );
    } catch (e, st) {
      log('💻 [WebServer] 启动失败: $e\n$st');
      _repo = null;
      return DiaryServerStartResult(
        DiaryServerStartStatus.failed,
        errorDetail: e.toString(),
      );
    }

    _server = server;
    log('💻 [WebServer] 服务已启动: http://${bindAddress.address}:$port');

    // 请求分流（监听本体错误单独兜底，防一个坏连接把 listener 打挂）
    server.listen(
      (req) => unawaited(_handleRequest(req)),
      onError: (Object e) => log('💻 [WebServer] 监听错误: $e'),
      cancelOnError: false,
    );

    // 4. 手机端数据变化轮询（1s 聚合签名比对，变了推 SSE）
    try {
      _lastSignature = await _repo!.changeSignature();
    } catch (e) {
      _lastSignature = '';
      log('💻 [WebServer] 初始签名获取失败（首轮轮询会重试）: $e');
    }
    _pollTimer = Timer.periodic(changePollInterval, (_) => _pollOnce());

    // 5. SSE 心跳：15s 一次注释行，防止中间设备掐掉空闲连接
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _writeToAllSseClients(': ping\n\n');
    });

    return const DiaryServerStartResult(DiaryServerStartStatus.started);
  }

  /// 停止服务（幂等）。关掉监听 socket 与所有活动连接（含 SSE）。
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _sseClients.clear();
    final server = _server;
    _server = null;
    _repo = null;
    if (server != null) {
      await server.close(force: true);
      log('💻 [WebServer] 服务已停止');
    }
  }

  /// 端口占用检查 + 自家旧实例关停。返回是否探测到自家服务。
  Future<bool> _shutdownOwnStaleInstance(int port, Duration timeout) async {
    final probeHit = await _probeIdentity(port, timeout);
    if (!probeHit) {
      // 没有服务或不是我们自己的（bind 时自然揭示），不刷屏只记一行
      log('💻 [WebServer] 端口 $port 探测：无自家服务实例');
      return false;
    }
    log('💻 [WebServer] 端口 $port 被自家服务实例占用，发送关停指令');
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/__shutdown'))
          .timeout(timeout);
      await request.close().timeout(timeout);
      client.close(force: true);
    } catch (e) {
      log('💻 [WebServer] 关停指令发送失败（继续尝试绑定）: $e');
    }
    // 等旧实例真正让出端口（最多 ~2s）
    for (var i = 0; i < 12; i++) {
      if (!await _probeIdentity(port, const Duration(milliseconds: 200))) {
        log('💻 [WebServer] 旧实例已退出，端口 $port 已释放');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    log('💻 [WebServer] 旧实例关停指令已发但端口仍未释放，尝试直接绑定');
    return true;
  }

  /// 探测 127.0.0.1:port 是否在跑我们自己的服务（/__identity 响应含身份标记）
  Future<bool> _probeIdentity(int port, Duration timeout) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/__identity'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return body.contains(kDiaryServerIdentity);
    } catch (_) {
      return false; // 连不上 = 没服务在跑
    } finally {
      client?.close(force: true);
    }
  }

  // ==================== 请求路由 ====================

  Future<void> _handleRequest(HttpRequest req) async {
    final method = req.method;
    final path = req.uri.path;
    // 每请求一行（排查用）：来源地址能看到是本机探测还是电脑浏览器
    log(
      '💻 [WebServer] → $method $path '
      '(from ${req.connectionInfo?.remoteAddress.address ?? '?'})',
    );
    try {
      // --- 管理端点：身份标记（端口探测用）+ 关停（只允许本机回环调用）---
      if (method == 'GET' && path == '/__identity') {
        return await _replyJson(req, {'service': kDiaryServerIdentity});
      }
      if (method == 'POST' && path == '/__shutdown') {
        return await _handleShutdown(req);
      }

      // --- 页面 ---
      if (method == 'GET' && path == '/') {
        return await _replyHtml(req);
      }

      // --- API ---
      if (method == 'GET' && path == '/api/notes') {
        return await _replyNotes(req);
      }
      if (method == 'GET' && path == '/api/events') {
        return await _openSse(req);
      }
      if (path.startsWith('/api/notes/')) {
        final id = int.tryParse(path.substring('/api/notes/'.length));
        if (id == null) {
          return await _replyJson(req, {'error': 'bad id'}, status: 400);
        }
        if (method == 'PUT') return await _handleUpdateNote(req, id);
        if (method == 'DELETE') return await _handleDeleteNote(req, id);
      }
      if (method == 'GET' && path.startsWith('/audio/')) {
        final id = int.tryParse(path.substring('/audio/'.length));
        if (id == null) {
          return await _replyJson(req, {'error': 'bad id'}, status: 400);
        }
        return await _replyAudio(req, id);
      }

      await _replyJson(req, {'error': 'not found'}, status: 404);
    } catch (e, st) {
      log('💻 [WebServer] 处理请求异常: $method $path: $e\n$st');
      try {
        await _replyJson(req, {'error': 'internal error'}, status: 500);
      } catch (_) {
        // 连接已断，忽略
      }
    }
  }

  /// 关停端点：只接受本机回环请求（新实例接管端口时调用）。
  /// 局域网里的其他设备调不通——防止任何人发个 POST 就关掉服务。
  Future<void> _handleShutdown(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress;
    if (remote == null || !remote.isLoopback) {
      await _replyJson(req, {'error': 'loopback only'}, status: 403);
      return;
    }
    await _replyJson(req, {'ok': true, 'bye': true});
    // 等响应写完再停（否则 force close 会掐断响应）
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      unawaited(stop());
    });
  }

  Future<void> _replyHtml(HttpRequest req) async {
    req.response.headers.set('Content-Type', 'text/html; charset=utf-8');
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.write(diaryWebPageHtml);
    await req.response.close();
  }

  /// JSON 响应统一出口
  Future<void> _replyJson(
    HttpRequest req,
    Object? data, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  Future<void> _replyNotes(HttpRequest req) async {
    final rows = await _repo!.getAllNotes();
    await _replyJson(req, {
      'notes': [for (final r in rows) diaryNoteToJson(r)],
    });
  }

  /// 电脑端编辑：PUT /api/notes/{id}，body {"content": "..."}
  Future<void> _handleUpdateNote(HttpRequest req, int id) async {
    final raw = await utf8.decoder.bind(req).join();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return await _replyJson(req, {'error': 'bad json'}, status: 400);
    }
    if (decoded is! Map<String, dynamic> || decoded['content'] is! String) {
      return await _replyJson(
        req,
        {'error': 'content (string) required'},
        status: 400,
      );
    }
    final content = decoded['content'] as String;
    final count = await _repo!.updateContent(id, content);
    if (count == 0) {
      return await _replyJson(req, {'error': 'not found'}, status: 404);
    }
    log('💻 [WebServer] 电脑端编辑日记 id=$id（${content.length} 字）');
    await _afterMutation();
    await _replyJson(req, {'ok': true});
  }

  /// 电脑端删除：DELETE /api/notes/{id}（连同录音文件，与日记页删除语义一致）
  Future<void> _handleDeleteNote(HttpRequest req, int id) async {
    final row = await _repo!.getNoteById(id);
    if (row == null) {
      return await _replyJson(req, {'error': 'not found'}, status: 404);
    }
    await _repo!.deleteById(id);
    await _deleteAudioFileSafely(row['audio_path'] as String?);
    log('💻 [WebServer] 电脑端删除日记 id=$id');
    await _afterMutation();
    await _replyJson(req, {'ok': true});
  }

  /// 录音文件流：GET /audio/{id}（支持 Range，浏览器可拖动进度条）。
  /// 只放行 audio_path 落在录音目录内的文件——备份导入可能带来任意路径
  /// 字符串，不能把手机上的任意文件暴露到局域网
  Future<void> _replyAudio(HttpRequest req, int id) async {
    final row = await _repo!.getNoteById(id);
    final audioPath = row?['audio_path'] as String?;
    if (audioPath == null || audioPath.isEmpty) {
      return await _replyJson(req, {'error': 'no audio'}, status: 404);
    }
    if (!await _isInsideAudioDir(audioPath)) {
      log('💻 [WebServer] ⚠️ 拒绝目录外音频请求: id=$id, $audioPath');
      return await _replyJson(req, {'error': 'forbidden'}, status: 403);
    }
    final file = File(audioPath);
    if (!await file.exists()) {
      return await _replyJson(req, {'error': 'no audio'}, status: 404);
    }
    final size = await file.length();
    final mime = audioMimeFor(audioPath);
    final range = parseRangeHeader(
      req.headers.value(HttpHeaders.rangeHeader),
      size,
    );
    final res = req.response;
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.contentType = ContentType.parse(mime);
    if (range == null) {
      res.contentLength = size;
      await res.addStream(file.openRead());
    } else {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        'Content-Range',
        'bytes ${range.start}-${range.end}/$size',
      );
      res.contentLength = range.end - range.start + 1;
      await res.addStream(file.openRead(range.start, range.end + 1));
    }
    await res.close();
  }

  /// SSE：GET /api/events。推送 `data: changed`，浏览器收到后重新拉列表
  Future<void> _openSse(HttpRequest req) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers.set('Content-Type', 'text/event-stream; charset=utf-8');
    res.headers.set('Cache-Control', 'no-cache');
    res.bufferOutput = false; // 立即下发，不做缓冲
    res.write(': connected\n\n');
    await res.flush();
    _sseClients.add(res);
    unawaited(
      res.done.then((_) => _sseClients.remove(res)),
    ); // 客户端断开自动清理
    log('💻 [WebServer] 浏览器已连接 SSE（当前 ${_sseClients.length} 个客户端）');
  }

  // ==================== 变化检测与推送 ====================

  /// 手机端写入检测：每秒一次聚合签名比对，变了就推 SSE
  Future<void> _pollOnce() async {
    if (_polling || _server == null || _repo == null) return;
    _polling = true;
    try {
      final sig = await _repo!.changeSignature();
      if (sig != _lastSignature) {
        _lastSignature = sig;
        log('💻 [WebServer] 检测到手机端日记变化，推送浏览器刷新');
        await _broadcastChange();
      }
    } catch (e) {
      log('💻 [WebServer] 轮询签名失败（下轮重试）: $e');
    } finally {
      _polling = false;
    }
  }

  /// 电脑端发生增删改后的收尾：
  /// 1. DiarySyncBridge.bump——悬浮窗 engine 感知（展开时重查）
  /// 2. 刷新本地签名（避免下轮轮询把自家改动再推一遍，浏览器多刷一次）
  /// 3. SSE 广播（发起改动的浏览器与其他浏览器都重拉列表）
  /// 4. remoteMutationTick++（main.dart 监听，刷新主 App 日记页）
  Future<void> _afterMutation() async {
    unawaited(DiarySyncBridge.bump());
    try {
      _lastSignature = await _repo!.changeSignature();
    } catch (_) {}
    await _broadcastChange();
    remoteMutationTick.value++;
  }

  Future<void> _broadcastChange() async {
    _writeToAllSseClients('data: changed\n\n');
  }

  void _writeToAllSseClients(String payload) {
    for (final res in List<HttpResponse>.of(_sseClients)) {
      try {
        res.write(payload);
        unawaited(
          res.flush().catchError((_) {
            _sseClients.remove(res);
          }),
        );
      } catch (_) {
        _sseClients.remove(res);
      }
    }
  }

  // ==================== 录音目录守护 ====================

  Future<Directory?> _resolveAudioDir() async {
    if (_audioDirOverride != null) return _audioDirOverride;
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory(p.join(docs.path, 'diary_audio'));
    } catch (e) {
      log('💻 [WebServer] 解析录音目录失败: $e');
      return null;
    }
  }

  /// 文件路径是否落在录音目录内（目录外一律拒绝服务）
  Future<bool> _isInsideAudioDir(String filePath) async {
    final dir = await _resolveAudioDir();
    if (dir == null) return false;
    return p.isWithin(p.canonicalize(dir.path), p.canonicalize(filePath));
  }

  /// 删除录音文件（best-effort）：与日记页删除语义一致（DB 行删掉后顺手删
  /// 录音文件），同样受录音目录守护约束
  Future<void> _deleteAudioFileSafely(String? audioPath) async {
    if (audioPath == null || audioPath.isEmpty) return;
    if (!await _isInsideAudioDir(audioPath)) return;
    try {
      final file = File(audioPath);
      if (await file.exists()) {
        await file.delete();
        log('💻 [WebServer] 已删除录音文件: $audioPath');
      }
    } catch (e) {
      log('💻 [WebServer] ⚠️ 删除录音文件失败（不影响数据删除）: $e');
    }
  }
}
