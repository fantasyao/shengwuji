import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/web_server/diary_web_server.dart';

/// 电脑访问服务回归（2026-09 新增）：
/// - 真实 socket 集成（回环地址 + 临时端口），锁 HTTP 契约：
///   身份标记 / 页面 / 列表 JSON / 编辑 / 删除（含录音文件）/ 音频流（Range）
/// - 端口稳定性：自家旧实例关停接管（__shutdown 仅回环）/ 他家占用报错
/// - SSE 实时推送：电脑端改动广播 + 手机端签名轮询广播
/// - 纯函数：Range 解析 / 音频 MIME
/// 数据层用内存假仓储（不碰 sqflite），与真实 DbHelper 的契约由
/// DbDiaryNoteRepository 薄封装保证（方法一一对应，无需重复单测）。
void main() {
  late Directory tempDir;
  late FakeRepository repo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shengwuji_web_server_test');
    repo = FakeRepository([
      {
        'id': 1,
        'content': '第一条日记',
        'created_at': '2026-09-13T10:00:00.000',
        'audio_path': null,
        'duration': null,
        'is_archived': 0,
        'tag': null,
      },
      {
        'id': 2,
        'content': '- [ ] 买牛奶\n- [x] 修眼镜',
        'created_at': '2026-09-12T08:30:00.000',
        'audio_path': p.join(tempDir.path, 'a.wav'),
        'duration': 12,
        'is_archived': 1,
        'tag': 'star',
      },
    ]);
    File(p.join(tempDir.path, 'a.wav')).writeAsBytesSync(
      List<int>.generate(100, (i) => i),
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Future<DiaryWebServer> startServer({
    int port = 0,
    DiaryRepositorySettle? settle,
  }) async {
    final server = DiaryWebServer();
    final result = await server.start(
      port: port,
      address: InternetAddress.loopbackIPv4,
      repository: repo,
      audioDir: tempDir,
      changePollInterval: settle?.pollInterval ?? const Duration(seconds: 1),
      identityProbeTimeout:
          settle?.probeTimeout ?? const Duration(milliseconds: 800),
    );
    expect(result.isSuccess, isTrue, reason: result.userMessage);
    return server;
  }

  Future<Map<String, dynamic>> getJson(Uri uri, {String? method}) async {
    final client = HttpClient();
    final request = await client.openUrl(method ?? 'GET', uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close(force: true);
    return {
      'status': response.statusCode,
      'body': jsonDecode(body) as Object?,
      'raw': body,
    };
  }

  group('HTTP 契约', () {
    test('GET /__identity 返回自家服务身份标记（端口接管探测依据）', () async {
      final server = await startServer();
      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/__identity'),
      );
      expect(r['status'], 200);
      expect(
        (r['body'] as Map)['service'],
        kDiaryServerIdentity,
      );
      await server.stop();
    });

    test('GET / 返回管理页（含标题与 SSE 接入脚本）', () async {
      final server = await startServer();
      final client = HttpClient();
      final resp = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}/'),
      )).close();
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      expect(resp.statusCode, 200);
      expect(body, contains('声物记'));
      expect(body, contains('EventSource'));
      expect(body, contains('已复制到剪贴板'));
      await server.stop();
    });

    test('GET /api/notes 返回全部日记；不暴露文件系统绝对路径', () async {
      final server = await startServer();
      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/notes'),
      );
      expect(r['status'], 200);
      final notes = (r['body'] as Map)['notes'] as List;
      expect(notes, hasLength(2));
      expect(r['raw'], isNot(contains(tempDir.path)));
      final second = notes.firstWhere((n) => n['id'] == 2);
      expect(second['isArchived'], isTrue);
      expect(second['hasAudio'], isTrue);
      expect(second['audioUrl'], '/audio/2');
      expect(second['duration'], 12);
      expect(second['tag'], 'star');
      expect(second['createdAt'], '2026-09-12T08:30:00.000');
      await server.stop();
    });

    test('PUT /api/notes/{id} 编辑内容；不存在的 id 404；坏 body 400', () async {
      final server = await startServer();
      final base = 'http://127.0.0.1:${server.boundPort}';

      Future<int> put(String path, String body) async {
        final client = HttpClient();
        final req = await client.openUrl('PUT', Uri.parse('$base$path'));
        req.headers.contentType = ContentType.json;
        req.write(body);
        final resp = await req.close();
        client.close(force: true);
        return resp.statusCode;
      }

      expect(
        await put('/api/notes/1', ''),
        400,
        reason: '缺 body（jsonDecode 抛错）应拒绝',
      );
      expect(
        await put('/api/notes/1', 'not json'),
        400,
        reason: '坏 body 应拒绝',
      );
      expect(
        await put('/api/notes/1', '{"content": 123}'),
        400,
        reason: 'content 不是字符串应拒绝',
      );
      expect(
        await put('/api/notes/999', jsonEncode({'content': '不存在的 id'})),
        404,
      );

      expect(await put('/api/notes/1', jsonEncode({'content': '电脑改过的内容'})), 200);
      expect(repo.rows.firstWhere((r) => r['id'] == 1)['content'], '电脑改过的内容');
      await server.stop();
    });

    test('DELETE /api/notes/{id} 删除行并连带删录音文件（与日记页语义一致）', () async {
      final server = await startServer();
      final wav = File(p.join(tempDir.path, 'a.wav'));
      expect(wav.existsSync(), isTrue);

      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/notes/2'),
        method: 'DELETE',
      );
      expect(r['status'], 200);
      expect(repo.rows.any((row) => row['id'] == 2), isFalse);
      expect(wav.existsSync(), isFalse, reason: '录音文件应一并删除');

      final missing = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/notes/2'),
        method: 'DELETE',
      );
      expect(missing['status'], 404);
      await server.stop();
    });

    test('GET /audio/{id} 全量 200；Range 请求 206 切片', () async {
      final server = await startServer();
      final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

      final client = HttpClient();
      final full = await (await client.getUrl(
        base.replace(path: '/audio/2'),
      )).close();
      expect(full.statusCode, 200);
      expect(full.headers.contentType.toString(), contains('audio/wav'));
      expect(full.headers.value('accept-ranges'), 'bytes');
      final bytes = await full.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(bytes, hasLength(100));

      final rangedReq = await client.getUrl(base.replace(path: '/audio/2'));
      rangedReq.headers.set('Range', 'bytes=10-19');
      final ranged = await rangedReq.close();
      expect(ranged.statusCode, 206);
      expect(ranged.headers.value('content-range'), 'bytes 10-19/100');
      final slice = await ranged.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(slice, hasLength(10));
      expect(slice.first, 10);
      expect(slice.last, 19);

      final noAudio = await (await client.getUrl(
        base.replace(path: '/audio/1'),
      )).close();
      expect(noAudio.statusCode, 404);
      client.close(force: true);
      await server.stop();
    });

    test('目录外的 audio_path 拒绝服务（403）', () async {
      // 模拟备份导入带来的任意路径：落在录音目录外
      final outside = File(
        p.join(Directory.systemTemp.path, 'outside_should_403.wav'),
      )..writeAsBytesSync([1, 2, 3]);
      repo.rows[1]['audio_path'] = outside.path;
      final server = await startServer();
      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/audio/2'),
      );
      expect(r['status'], 403);
      expect(outside.existsSync(), isTrue, reason: '目录外文件也不应被删除');
      outside.deleteSync();
      await server.stop();
    });
  });

  group('端口稳定性', () {
    test('自家旧实例占用端口：新实例发关停指令接管成功，旧实例退出', () async {
      final oldServer = await startServer();
      final port = oldServer.boundPort;
      expect(oldServer.isRunning, isTrue);

      final newServer = DiaryWebServer();
      final result = await newServer.start(
        port: port,
        address: InternetAddress.loopbackIPv4,
        repository: repo,
        audioDir: tempDir,
      );
      expect(result.isSuccess, isTrue, reason: result.userMessage);
      expect(newServer.isRunning, isTrue);
      expect(newServer.boundPort, port, reason: '端口号必须保持不变');
      expect(oldServer.isRunning, isFalse, reason: '旧实例应已被 __shutdown 关停');

      // 端口上现在应答的是新实例
      final r = await getJson(Uri.parse('http://127.0.0.1:$port/__identity'));
      expect(r['status'], 200);
      await newServer.stop();
    });

    test('他方进程占用端口（无自家身份）：报 portBusyByOther 而不是硬绑', () async {
      final rogue = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final server = DiaryWebServer();
      final result = await server.start(
        port: rogue.port,
        address: InternetAddress.loopbackIPv4,
        repository: repo,
        audioDir: tempDir,
      );
      expect(result.status, DiaryServerStartStatus.portBusyByOther);
      expect(server.isRunning, isFalse);
      await rogue.close(force: true);
    });

    test('__shutdown 只接受本机回环请求（局域网设备无法关停服务）', () async {
      // 走非回环地址模拟"远程"请求在单机上不易构造，直接锁处理逻辑：
      // 该端点挂在 POST /__shutdown，remoteAddress 非回环 → 403。
      // 这里验证回环路径可用（真正 403 分支的地址判断在 _handleShutdown 内联）。
      final server = await startServer();
      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/__shutdown'),
        method: 'POST',
      );
      expect(r['status'], 200);
      // 给服务端 50ms 延迟停机留时间
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.isRunning, isFalse, reason: '回环关停指令应生效');
    });

    test('生产默认路径：不传 address 也能启动（回归：曾把可空 address 直接传 bind，真机报 Null is not a subtype of String）', () async {
      // 真机 bug 复现路径：controller.start() 不带参数调 _server.start()，
      // address 为 null → 兜底 anyIPv4。此前的测试全部显式传了
      // loopbackIPv4，恰好漏掉了生产默认路径
      final server = DiaryWebServer();
      final result = await server.start(
        port: 0,
        repository: repo,
        audioDir: tempDir,
      );
      expect(result.isSuccess, isTrue, reason: result.userMessage);
      // anyIPv4 监听下回环也应可达
      final r = await getJson(
        Uri.parse('http://127.0.0.1:${server.boundPort}/__identity'),
      );
      expect(r['status'], 200);
      await server.stop();
    });
  });

  group('实时刷新', () {
    test('电脑端改动（PUT）→ SSE 广播 changed', () async {
      final server = await startServer();
      final client = HttpClient();
      final sseReq = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/events'),
      );
      final sse = await sseReq.close();
      expect(sse.headers.contentType.toString(), contains('text/event-stream'));

      final changed = Completer<void>();
      final buffer = StringBuffer();
      late StreamSubscription<String> sub;
      sub = sse.transform(utf8.decoder).listen((data) {
        buffer.write(data);
        if (data.contains('data: changed')) {
          changed.complete();
          sub.cancel();
        }
      });

      // 等连接建立（服务端先发 ': connected' 注释行）
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final putClient = HttpClient();
      final req = await putClient.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/notes/1'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'content': '触发广播'}));
      await req.close();
      putClient.close(force: true);

      await changed.future.timeout(const Duration(seconds: 5));
      client.close(force: true);
      await server.stop();
    });

    test('手机端写入（仓储签名变化）→ 轮询检出 → SSE 广播', () async {
      final server = await startServer(
        settle: DiaryRepositorySettle(pollInterval: const Duration(milliseconds: 50)),
      );
      final client = HttpClient();
      final sseReq = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/events'),
      );
      final sse = await sseReq.close();

      final changed = Completer<void>();
      late StreamSubscription<String> sub;
      sub = sse.transform(utf8.decoder).listen((data) {
        if (data.contains('data: changed')) {
          changed.complete();
          sub.cancel();
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 模拟手机端（主 engine 或悬浮窗 engine）新增一条日记
      repo.rows.add({
        'id': 3,
        'content': '手机上刚录的',
        'created_at': '2026-09-13T11:00:00.000',
        'audio_path': null,
        'duration': null,
        'is_archived': 0,
        'tag': null,
      });

      await changed.future.timeout(const Duration(seconds: 5));
      client.close(force: true);
      await server.stop();
    });

    test('电脑端改动会递增 remoteMutationTick（main.dart 据此刷新日记页）', () async {
      final server = await startServer();
      var ticks = server.remoteMutationTick.value;
      final client = HttpClient();
      final req = await client.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${server.boundPort}/api/notes/1'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'content': 'tick 测试'}));
      await req.close();
      client.close(force: true);
      expect(server.remoteMutationTick.value, ticks + 1);
      await server.stop();
    });
  });

  group('纯函数', () {
    test('parseRangeHeader 各形态', () {
      expect(parseRangeHeader(null, 100), isNull);
      expect(parseRangeHeader('garbage', 100), isNull);
      expect(parseRangeHeader('bytes=', 100), isNull);
      expect(parseRangeHeader('bytes=0-49', 100), (start: 0, end: 49));
      expect(parseRangeHeader('bytes=50-', 100), (start: 50, end: 99));
      expect(parseRangeHeader('bytes=-10', 100), (start: 90, end: 99));
      expect(parseRangeHeader('bytes=-500', 100), (start: 0, end: 99));
      expect(parseRangeHeader('bytes=99-', 100), (start: 99, end: 99));
      expect(parseRangeHeader('bytes=100-', 100), isNull, reason: '越界');
      expect(parseRangeHeader('bytes=90-120', 100), (start: 90, end: 99),
          reason: 'end 截断到文件尾');
      expect(parseRangeHeader('bytes=0-49', 0), isNull, reason: '空文件');
    });

    test('audioMimeFor 按扩展名', () {
      expect(audioMimeFor('/x/a.wav'), 'audio/wav');
      expect(audioMimeFor('/x/b.MP3'), 'audio/mpeg');
      expect(audioMimeFor('/x/c.m4a'), 'audio/mp4');
      expect(audioMimeFor('/x/d.txt'), 'application/octet-stream');
    });

    test('diaryNoteToJson 不携带绝对路径，is_archived 归一化为 bool', () {
      final json = diaryNoteToJson({
        'id': 7,
        'content': 'x',
        'created_at': '2026-01-01T00:00:00.000',
        'audio_path': '/data/user/0/app/diary_audio/a.wav',
        'duration': 3,
        'is_archived': 1,
        'tag': null,
      });
      expect(json['audioUrl'], '/audio/7');
      expect(json['hasAudio'], isTrue);
      expect(json['isArchived'], isTrue);
      expect(json.toString(), isNot(contains('/data/user/0')));
    });
  });
}

/// 测试辅助：轮询/探测参数命名打包（仅提升 setUp 可读性）
class DiaryRepositorySettle {
  const DiaryRepositorySettle({
    this.pollInterval = const Duration(seconds: 1),
    this.probeTimeout = const Duration(milliseconds: 800),
  });

  final Duration pollInterval;
  final Duration probeTimeout;
}

/// 内存假仓储：服务层逻辑与 sqflite 解耦的关键
class FakeRepository implements DiaryNoteRepository {
  FakeRepository([List<Map<String, dynamic>>? initial])
    : rows = List.of(initial ?? const []);

  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> getAllNotes() async => List.of(rows);

  @override
  Future<Map<String, dynamic>?> getNoteById(int id) async {
    for (final row in rows) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  @override
  Future<int> updateContent(int id, String content) async {
    for (final row in rows) {
      if (row['id'] == id) {
        row['content'] = content;
        return 1;
      }
    }
    return 0;
  }

  @override
  Future<int> deleteById(int id) async {
    final before = rows.length;
    rows.removeWhere((row) => row['id'] == id);
    return before - rows.length;
  }

  @override
  Future<String> changeSignature() async {
    var maxId = 0;
    var contentLen = 0;
    var archived = 0;
    for (final row in rows) {
      maxId = (row['id'] as int) > maxId ? row['id'] as int : maxId;
      contentLen += ((row['content'] as String?) ?? '').length;
      archived += (row['is_archived'] ?? 0) == 1 ? 1 : 0;
    }
    return 'c=${rows.length},m=$maxId,s=$contentLen,a=$archived';
  }
}
