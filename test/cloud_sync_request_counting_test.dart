import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';
import 'package:shengwuji_app/sync/webdav_request_counter.dart';
import 'package:shengwuji_app/text_processor.dart';

/// 断言所有 WebDAV 业务方法（含 404 探测）都经同一个出口计数。
class _FakeAdapter implements HttpClientAdapter {
  final List<String> requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    if (options.method == 'OPTIONS') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    return ResponseBody.fromString(
      'not found',
      404,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('ping 与 404 探测都计数，且先计数后发送', () async {
    final counter = WebDavRequestCounter(engine: 'main');
    addTearDown(counter.dispose);
    final service = CloudSyncService(
      dbHelper: DbHelper(),
      processor: TextProcessor(),
      requestCounter: counter,
    );
    final config = CloudSyncConfig(
      serverUrl: 'https://example.com/dav',
      account: 'user',
      password: 'app-password',
      remotePath: '/sync',
    );

    final client = service.createClient(config);
    final adapter = _FakeAdapter();
    client.c.httpClientAdapter = adapter;
    addTearDown(() => client.c.close());

    await client.ping();
    expect(counter.recentCount, 1);

    // 远端目录不存在：readProps 404 抛错，但请求确实已经发出，必须计入
    await expectLater(client.readProps('/sync'), throwsA(anything));
    expect(counter.recentCount, 2);
    expect(adapter.requests, ['OPTIONS /dav/', 'PROPFIND /dav/sync/']);
  });

  test('没有计数器时请求照常发送', () async {
    final service = CloudSyncService(
      dbHelper: DbHelper(),
      processor: TextProcessor(),
    );
    final config = CloudSyncConfig(
      serverUrl: 'https://example.com/dav',
      account: 'user',
      password: 'app-password',
      remotePath: '/sync',
    );
    final client = service.createClient(config);
    final adapter = _FakeAdapter();
    client.c.httpClientAdapter = adapter;
    addTearDown(() => client.c.close());

    await client.ping();
    expect(adapter.requests, ['OPTIONS /dav/']);
  });
}
