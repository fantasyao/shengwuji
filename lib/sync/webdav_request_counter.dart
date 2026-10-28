import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 本机 WebDAV 请求预算：滚动 30 分钟窗口内发出的请求数。
///
/// 坚果云只说明「免费版 600 次 / 30 分钟、付费版 1500 次」，没有剩余额度
/// 查询接口，响应也不返回限流余量，所以只能客户端自己记账。窗口按分钟
/// 归档、滚动计算，不需要判断当前落在哪个固定区间。
///
/// ⚠️ 手机有两个 FlutterEngine（主 App + 悬浮窗），两边都能发起云同步。
/// 静态单例和 SharedPreferences 内存缓存都不跨 isolate，因此这里**每个
/// engine 只追加写自己那份日志**（`webdav_requests_<engine>.log`），
/// 展示时再把另一份日志读进来合并（[refreshOtherEngine]）。追加写不需要
/// 防抖、进程被杀也不丢已发出的请求；代价是另一 engine 的新增请求要等
/// 页面打开/同步结束时刷新才可见（快照，不是实时）。
///
/// 计数只覆盖这台手机；电脑端和其它客户端发出的请求不在这里。
class WebDavRequestCounter extends ChangeNotifier {
  WebDavRequestCounter({
    required this.engine,
    this.limit = freeLimit,
    this.directory,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const int freeLimit = 600;
  static const int paidLimit = 1500;
  static const Duration windowLength = Duration(minutes: 30);
  static const int _windowMinutes = 30;
  static const String _filePrefix = 'webdav_requests_';

  /// 日志超过这么多行才在启动时压缩一次（只留窗口内时间戳）。
  /// 常态每行约 14 字节，2000 行 ≈ 28KB；不压缩的话长期使用后每次进设置页
  /// 都要读整份历史。
  static const int _compactThreshold = 2000;

  /// 本 engine 标识，决定日志文件名（main / overlay）。
  final String engine;

  /// 用于估算剩余额度的上限；默认按坚果云免费版。
  final int limit;

  /// 日志目录（应用支持目录）；为 null 时只在内存计数（单测/降级场景）。
  final Directory? directory;

  final DateTime Function() _clock;

  /// 本 engine 的分钟桶：epoch 分钟 → 请求数。
  final Map<int, int> _buckets = <int, int>{};

  /// 另一 engine 日志的分钟桶；[refreshOtherEngine] 时整份替换。
  final Map<int, int> _otherBuckets = <int, int>{};

  /// 追加写的串行链：同一 isolate 内保证行不交错。
  Future<void> _appendChain = Future<void>.value();
  Timer? _expiryTimer;
  bool _disposed = false;

  /// 本 engine 日志的逻辑行数（含还没落盘的追加），用于运行期触发压缩。
  int _lineCount = 0;

  static WebDavRequestCounter? _instance;
  static Future<WebDavRequestCounter>? _initializing;

  /// 本 engine 已初始化的单例；未初始化时为 null。
  static WebDavRequestCounter? get instanceOrNull => _instance;

  /// 每个 engine 启动时调用一次：建目录、读回自己的日志、装上 UI 到期刷新。
  static Future<WebDavRequestCounter> initialize({required String engine}) {
    final existing = _instance;
    if (existing != null) return Future<WebDavRequestCounter>.value(existing);
    return _initializing ??= _doInitialize(engine);
  }

  static Future<WebDavRequestCounter> _doInitialize(String engine) async {
    Directory? directory;
    try {
      directory = await getApplicationSupportDirectory();
    } catch (error) {
      // 拿不到私有目录时退化成只在内存计数：本次运行仍能展示，只是不跨重启
      debugPrint('获取 WebDAV 计数目录失败，本次只在内存计数：$error');
    }
    final counter = WebDavRequestCounter(engine: engine, directory: directory);
    _instance = counter;
    await counter.load();
    return counter;
  }

  File get _ownFile => File(p.join(directory!.path, '$_filePrefix$engine.log'));

  File get _otherFile {
    final other = engine == 'overlay' ? 'main' : 'overlay';
    return File(p.join(directory!.path, '$_filePrefix$other.log'));
  }

  /// 本 engine 最近 30 分钟发出的请求数（不含另一 engine）。
  int get ownRecentCount {
    _prune();
    return _total(_buckets);
  }

  /// 最近一次读取的另一 engine 计数（超出窗口的条目读时裁掉）。
  int get otherRecentCount {
    _prune();
    return _total(_otherBuckets);
  }

  /// 最近 30 分钟本机（两个 engine 合计）发出的请求数。
  ///
  /// 另一 engine 的部分是 [refreshOtherEngine] 时的快照；悬浮窗在本页打开
  /// 后新发出的请求，要等下次打开页面/同步结束刷新才计入。
  int get recentCount => ownRecentCount + otherRecentCount;

  /// 按 [limit] 估算的剩余次数；实际额度还可能被其它设备/客户端占用。
  int get remaining => math.max(0, limit - recentCount);

  /// 窗口内最早一批请求滑出窗口还要多久；窗口为空时为 null。
  Duration? get untilNextExpiry {
    _prune();
    final oldest = <int>[..._buckets.keys, ..._otherBuckets.keys];
    if (oldest.isEmpty) return null;
    final expireAt = _minuteStart(oldest.reduce(math.min)).add(windowLength);
    final left = expireAt.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// 读回本 engine 上次运行写下的日志；坏行/坏文件按空窗口处理。
  Future<void> load() async {
    if (_disposed || directory == null) return;
    final loaded = <int, int>{};
    final recent = <int>[];
    var lineCount = 0;
    final current = _minuteOf(_clock());
    final cutoff = current - (_windowMinutes - 1);
    try {
      final file = _ownFile;
      if (await file.exists()) {
        for (final line in await file.readAsLines()) {
          lineCount++;
          final ms = int.tryParse(line.trim());
          if (ms == null) continue;
          final minute = ms ~/ 60000;
          // 时钟回拨/前跳产生的越界行直接丢弃，与读时 _prune 同一口径
          if (minute < cutoff || minute > current) continue;
          loaded[minute] = (loaded[minute] ?? 0) + 1;
          recent.add(ms);
        }
      }
    } catch (error) {
      debugPrint('读取 WebDAV 请求计数失败，按空窗口处理：$error');
      loaded.clear();
      recent.clear();
    }
    if (_disposed) return;
    for (final entry in loaded.entries) {
      _buckets[entry.key] = (_buckets[entry.key] ?? 0) + entry.value;
    }
    _prune();
    _lineCount = lineCount;
    if (lineCount > _compactThreshold) {
      // 只有本 engine 写自己的日志，另一 engine 只读；临时文件 + rename
      // 保证读方看到的要么是旧文件、要么是新文件，不会读到半个文件
      await _compact(recent);
      _lineCount = recent.length;
    }
    _scheduleExpiry();
    _notify();
  }

  /// 每发出一次 HTTP 请求调用一次（失败的请求也计入，偏保守）。
  void record() {
    if (_disposed) return;
    final now = _clock();
    _prune(now);
    final minute = _minuteOf(now);
    _buckets[minute] = (_buckets[minute] ?? 0) + 1;
    _lineCount++;
    _appendTimestamp(now.millisecondsSinceEpoch);
    _maybeCompact();
    _scheduleExpiry();
    _notify();
  }

  /// 重读另一 engine 的日志（设置页打开、同步结束时各调用一次即可）。
  Future<void> refreshOtherEngine() async {
    if (_disposed || directory == null) return;
    final loaded = <int, int>{};
    try {
      final file = _otherFile;
      if (await file.exists()) {
        for (final line in await file.readAsLines()) {
          final ms = int.tryParse(line.trim());
          if (ms == null) continue;
          final minute = _minuteOf(DateTime.fromMillisecondsSinceEpoch(ms));
          loaded[minute] = (loaded[minute] ?? 0) + 1;
        }
      }
    } catch (error) {
      debugPrint('读取悬浮窗 WebDAV 请求计数失败，按空窗口处理：$error');
      loaded.clear();
    }
    if (_disposed) return;
    _otherBuckets
      ..clear()
      ..addAll(loaded);
    _prune();
    _scheduleExpiry();
    _notify();
  }

  /// 等待已入队的日志追加写完；退出前调用（追加写本身无防抖）。
  Future<void> flush() => _appendChain;

  void _appendTimestamp(int millisecondsSinceEpoch) {
    if (directory == null) return;
    final file = _ownFile;
    _appendChain = _appendChain.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '$millisecondsSinceEpoch\n',
          mode: FileMode.append,
          flush: false,
        );
      } catch (error) {
        debugPrint('保存 WebDAV 请求计数失败：$error');
      }
    });
  }

  /// 运行期压缩：进程长期不重启时也不能让日志无限变长。
  /// 排在已入队的追加之后；此刻的 record 已进内存桶，重写不会丢。
  void _maybeCompact() {
    if (directory == null || _lineCount <= _compactThreshold) return;
    final snapshot = _windowTimestamps();
    _lineCount = snapshot.length;
    _appendChain = _appendChain.then((_) => _compact(snapshot));
  }

  /// 用分钟桶还原窗口内的时间戳。同一分钟统一取分钟起点，与
  /// [untilNextExpiry] 的到期口径一致；跨 engine 只看条数，不受影响。
  List<int> _windowTimestamps() {
    _prune();
    final out = <int>[];
    for (final entry in _buckets.entries) {
      final start = _minuteStart(entry.key).millisecondsSinceEpoch;
      out.addAll(List.filled(entry.value, start));
    }
    return out;
  }

  Future<void> _compact(List<int> timestamps) async {
    final file = _ownFile;
    try {
      await file.parent.create(recursive: true);
      final text = timestamps.map((ms) => '$ms\n').join();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // Windows 上目标存在时 rename 可能失败（真机是 Android，保留兜底）
        await file.writeAsString(text, flush: true);
        if (await tmp.exists()) await tmp.delete();
      }
    } catch (error) {
      debugPrint('压缩 WebDAV 请求计数日志失败：$error');
    }
  }

  void _prune([DateTime? now]) {
    if (_buckets.isEmpty && _otherBuckets.isEmpty) return;
    final current = _minuteOf(now ?? _clock());
    final cutoff = current - (_windowMinutes - 1);
    bool stale(int minute) => minute < cutoff || minute > current;
    _buckets.removeWhere((minute, _) => stale(minute));
    _otherBuckets.removeWhere((minute, _) => stale(minute));
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_disposed) return;
    final now = _clock();
    _prune(now);
    final minutes = <int>[..._buckets.keys, ..._otherBuckets.keys];
    if (minutes.isEmpty) return;
    final expireAt = _minuteStart(minutes.reduce(math.min)).add(windowLength);
    var delay = expireAt.difference(now);
    if (delay < const Duration(milliseconds: 100)) {
      delay = const Duration(milliseconds: 100);
    }
    _expiryTimer = Timer(delay + const Duration(milliseconds: 20), () {
      _expiryTimer = null;
      _prune();
      _notify();
      _scheduleExpiry();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    super.dispose();
  }

  static int _total(Map<int, int> buckets) {
    var total = 0;
    for (final count in buckets.values) {
      total += count;
    }
    return total;
  }

  static int _minuteOf(DateTime time) => time.millisecondsSinceEpoch ~/ 60000;

  static DateTime _minuteStart(int minute) =>
      DateTime.fromMillisecondsSinceEpoch(minute * 60000);
}
