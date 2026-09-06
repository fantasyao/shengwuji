/// 常驻识别 worker isolate 服务
///
/// 架构：sherpa_onnx FFI 识别（decode）全部下沉到常驻 worker isolate，
/// 主 isolate 只收发消息——PCM（Float32List）传进、文本（String）传出，
/// 消除"主 isolate decode 导致 UI 冻结"。
///
/// 隔离边界铁律（改动本文件前必读）：
/// - FFI 对象（OfflineRecognizer / OfflineStream）永不跨 isolate
/// - 跨界消息只允许 String / Float32List / int / bool（可拷贝传输）
/// - 模型不跨界传递：worker 内用主 isolate 发来的模型目录路径重建
///
/// 上游：diary_tab / record_tab / list_tab（经 RecognizerSingleton 门面代理）
/// 下游：worker isolate 内的 sherpa_onnx FFI（config 与 recognizer_singleton.dart 逐字段一致）
/// 详见 docs/architecture/speech-recognition.md「识别 worker isolate 架构」
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

// 本文件同时运行在主 isolate 与 worker isolate，统一用 print 保持零 Flutter 依赖
// （日志前缀 🧵 [RecognitionService] 便于 logcat 过滤）
// ignore_for_file: avoid_print

// ============================================================
// 消息协议（主 → worker 请求 / worker → 主 事件）
//
// 手写消息类而非 json：Float32List 无法 json 化。
// 字段仅 int / String / Float32List / bool，天然满足 isolate 传输约束
// （不含闭包、不含 FFI 指针，send 时按拷贝语义传输）。
// ============================================================

/// 主 → worker 请求基类
abstract class _WorkerRequest {
  const _WorkerRequest(this.id);

  /// 请求关联 id：主侧分配，worker 原样带回，用于配对 _pending 里的 Completer
  final int id;
}

/// init / reload：路径变了先建新再释旧（模型热切换）
class _ReqInit extends _WorkerRequest {
  const _ReqInit(super.id, this.modelDir);

  /// 模型目录（内含 model.int8.onnx + tokens.txt）
  final String modelDir;
}

/// PCM 识别请求：Float32List 拷贝进 worker
class _ReqTranscribe extends _WorkerRequest {
  const _ReqTranscribe(super.id, this.samples);

  /// 16kHz 单声道 PCM 归一化采样
  final Float32List samples;
}

/// 预热请求：0.1s 静音 decode（幂等）
class _ReqWarmup extends _WorkerRequest {
  const _ReqWarmup(super.id);
}

/// 销毁请求：free 识别器 + Isolate.exit
class _ReqDispose extends _WorkerRequest {
  const _ReqDispose(super.id);
}

/// worker → 主 事件基类
abstract class _WorkerEvent {
  const _WorkerEvent(this.id);

  /// 对应请求的 id
  final int id;
}

/// _ReqInit 的结果
class _EvReady extends _WorkerEvent {
  const _EvReady(super.id, this.ok, [this.error]);

  final bool ok;

  /// ok=false 时的错误描述
  final String? error;
}

/// _ReqTranscribe / _ReqWarmup / _ReqDispose 的正常回执
class _EvResult extends _WorkerEvent {
  const _EvResult(super.id, this.text);

  final String text;
}

/// worker 内处理失败的回执
class _EvError extends _WorkerEvent {
  const _EvError(super.id, this.error);

  final String error;
}

// ============================================================
// worker isolate 侧
// ============================================================

/// worker isolate 入口：第一条消息回传握手 SendPort，之后常驻处理请求
///
/// ⚠️ 未捕获异常会直接杀死 worker isolate——所以每条消息的处理都整体
/// try/catch 兜底（见下方 listen），真正防不住的只有 FFI 段错误这类
/// native 崩溃，由主侧 _exitPort/_errorPort 感知并按重启风暴策略处理。
void _recognitionWorkerEntry(SendPort mainSendPort) {
  final port = ReceivePort();
  // 握手：主侧收到 SendPort 后才开始发送业务消息
  mainSendPort.send(port.sendPort);

  // ⚠️ Dart 层 FFI 绑定必须在 worker isolate 内独立初始化：
  // - 绑定查找结果（NativeFunction 指针表）缓存在各 isolate 自己的 heap，
  //   互不共享——主 isolate 调过的 initBindings() 对本 worker 无效
  // - DynamicLibrary.open 打开同一个 .so 由 OS 引用计数管理，双 isolate
  //   同时打开安全（主 isolate 的 RecognizerSingleton 与本 worker 各持一份
  //   绑定，指向同一份机器码，不会重复加载模型库本体）
  sherpa_onnx.initBindings();

  final core = _WorkerCore(mainSendPort);

  port.listen((message) {
    // 每条消息整体 try/catch：常驻服务崩了等于全局识别下线
    int? id;
    if (message is _WorkerRequest) id = message.id;
    try {
      core.handle(message);
    } catch (e, st) {
      print('🧵 [RecognitionService] ❌ worker 处理消息异常: $e\n$st');
      mainSendPort.send(_EvError(id ?? -1, e.toString()));
    }
  });
}

/// worker isolate 内的识别核心：持有 FFI 对象，生命周期与 worker 相同
/// （字段永不跨界——外界只能通过消息驱动）
class _WorkerCore {
  _WorkerCore(this._main);

  /// 回主 isolate 的发送口
  final SendPort _main;

  /// 当前识别器（FFI 对象，仅 worker isolate 内触碰）
  sherpa_onnx.OfflineRecognizer? _recognizer;

  /// 已加载的模型目录（init 幂等判断 + 热切换依据）
  String? _loadedModelDir;

  void handle(Object? message) {
    if (message is _ReqInit) {
      _handleInit(message);
    } else if (message is _ReqTranscribe) {
      if (_recognizer == null) {
        _main.send(_EvError(message.id, 'worker not ready'));
        return;
      }
      final text = _transcribe(message.samples);
      _main.send(_EvResult(message.id, text));
    } else if (message is _ReqWarmup) {
      // recognizer 为 null 时静默跳过 decode（幂等），仍回执避免主侧挂等超时
      _warmupInternal();
      _main.send(_EvResult(message.id, ''));
    } else if (message is _ReqDispose) {
      _recognizer?.free();
      _recognizer = null;
      _loadedModelDir = null;
      // Isolate.exit：原子地发送最后一条消息并退出
      // （exit 前已 send 的消息同样保证送达主 isolate）
      Isolate.exit(_main, _EvResult(message.id, ''));
    }
  }

  /// init / reload：路径未变直接幂等回 ready；变了先建新再释旧（热切换不中断服务）
  void _handleInit(_ReqInit msg) {
    if (_recognizer != null && _loadedModelDir == msg.modelDir) {
      _main.send(_EvReady(msg.id, true));
      return;
    }

    // 路径拼接方式与 recognizer_singleton.dart 保持一致（package:path 的 p.join）
    final modelPath = p.join(msg.modelDir, 'model.int8.onnx');
    final tokensPath = p.join(msg.modelDir, 'tokens.txt');

    final sw = Stopwatch()..start();
    try {
      // ⚠️ config 必须与 recognizer_singleton.dart 的 OfflineRecognizerConfig
      // 逐字段一致：SenseVoice / language 'zh' / useInverseTextNormalization
      // true / numThreads 1——两边配置漂移 = 同一段音频主/worker 识别结果不一致
      final config = sherpa_onnx.OfflineRecognizerConfig(
        model: sherpa_onnx.OfflineModelConfig(
          senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
            model: modelPath,
            language: 'zh',
            useInverseTextNormalization: true,
          ),
          tokens: tokensPath,
          numThreads: 1,
        ),
      );

      // 先建新再释旧：OfflineRecognizer(config) 抛异常时旧实例原封不动
      // （失败不覆盖已加载的模型，下次 init 同路径幂等重试）
      final old = _recognizer;
      final next = sherpa_onnx.OfflineRecognizer(config);
      _recognizer = next;
      _loadedModelDir = msg.modelDir;
      old?.free();

      // 内联预热（0.1s 静音 decode）：失败只打日志、不影响 ready
      // （对齐 diary_tab._warmupEngine 的容错行为——预热失败不代表模型不可用）
      try {
        _warmupInternal();
      } catch (e) {
        print('🧵 [RecognitionService] ⚠️ worker 预热失败(忽略): $e');
      }

      sw.stop();
      print(
        '🧵 [RecognitionService] worker 模型加载+预热完成: ${sw.elapsedMilliseconds}ms, dir=${msg.modelDir}',
      );
      _main.send(_EvReady(msg.id, true));
    } catch (e, st) {
      sw.stop();
      print(
        '🧵 [RecognitionService] ❌ worker 模型加载失败(${sw.elapsedMilliseconds}ms): $e\n$st',
      );
      _main.send(_EvReady(msg.id, false, e.toString()));
    }
  }

  /// 单段 PCM → 文本。写法与 diary_tab._recognizeSamplesToText 同构：
  /// createStream → acceptWaveform(16k) → decode → getResult → finally free
  /// （decode 是同步 FFI 阻塞调用，但在 worker 内执行，不冻结主 isolate UI）
  String _transcribe(Float32List samples) {
    final recognizer = _recognizer!;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  /// 静音 decode 预热：与 diary_tab._warmupEngine 同构（0.1s 全零采样）
  void _warmupInternal() {
    final recognizer = _recognizer;
    if (recognizer == null) return;

    final sampleRate = 16000;
    final silentSamples = List.filled(sampleRate ~/ 10, 0.0); // 0.1秒静音

    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(
        samples: Float32List.fromList(silentSamples),
        sampleRate: sampleRate,
      );
      recognizer.decode(stream);
      recognizer.getResult(stream);
    } finally {
      stream.free();
    }
  }
}

// ============================================================
// 主 isolate 侧
// ============================================================

/// 常驻识别服务（主 isolate 侧句柄）
///
/// 用法：
/// ```dart
/// final service = RecognitionService();
/// if (await service.initialize(modelDir)) {
///   final text = await service.transcribe(samples);
/// }
/// ```
///
/// - initialize 支持模型热切换：换 modelDir 会通知 worker 重建识别器
/// - worker 崩溃自动重启（60s 窗口内 >=3 次死亡则放弃，等下一次显式 initialize）
/// - dispose 是终态操作：之后本实例不可再用，需要时请创建新实例
class RecognitionService {
  RecognitionService() {
    // isolate 崩溃/退出的感知通道（spawn 时注入到 Isolate.spawn 的
    // onError/onExit 参数；onError 常先于 onExit 触发，由 _deathHandled 去重）
    _errorPort.listen(_onWorkerDied);
    _exitPort.listen((_) => _onWorkerDied(null));
  }

  Isolate? _isolate;
  SendPort? _workerPort;

  /// id → Completer 请求关联核心（超时/崩溃时必须清理，防泄漏与迟到回复误配）
  final _pending = <int, Completer<dynamic>>{};
  final _errorPort = ReceivePort();
  final _exitPort = ReceivePort();
  ReceivePort? _mainPort;

  /// spawn 进行中的 Completer：并发 initialize 归并等待同一次 spawn（禁止 double spawn）
  Completer<void>? _spawnCompleter;
  bool _spawning = false;

  int _nextId = 0;
  bool _ready = false;
  String? _loadedModelDir;

  // ---- 重启风暴防护：60s 滑动窗口内 >=3 次死亡 → 放弃自动重启 ----
  static const _crashWindow = Duration(seconds: 60);
  static const _maxCrashesInWindow = 3;
  int _crashesInWindow = 0;
  DateTime? _windowStart;

  bool _shuttingDown = false;

  /// worker 死亡前最后使用的模型目录（自动重启后用它重新 initialize）
  String? _lastModelDir;

  /// onError 与 onExit 对同一次死亡会连续双触发，此标志去重
  bool _deathHandled = false;

  /// 是否就绪（模型已加载且 worker 存活）
  bool get isReady => _ready;

  /// worker 当前已加载的模型目录（主 isolate 侧镜像，与 worker 内 _loadedModelDir 同步）
  /// 暴露给外层做"模型路径是否变化"判断：与 RecognizerSingleton 的
  /// _currentModelPath（期望路径）不同 = 导入新模型后待热切换，外层守卫据此放行
  String? get loadedModelDir => _loadedModelDir;

  // ============================================================
  // 公开 API
  // ============================================================

  /// 初始化 / 热切换模型。
  /// 已就绪且路径相同 → 幂等返回 true；否则 spawn（如需）+ 发 _ReqInit → 等 _EvReady。
  /// spawn 是异步的（_workerPort 在握手完成前是 null）："spawn 中再次调用"
  /// 会归并等待同一次 spawn 完成，不会 double spawn。
  Future<bool> initialize(String modelDir) async {
    // 先记下来：worker 若死亡，自动重启要用它恢复
    _lastModelDir = modelDir;

    if (_shuttingDown) {
      print('🧵 [RecognitionService] initialize 拒绝：服务已 dispose');
      return false;
    }
    if (_ready && _loadedModelDir == modelDir && _workerPort != null) {
      return true;
    }

    final spawned = await _ensureSpawned();
    if (!spawned) return false;

    try {
      final ev = await _request<_EvReady>(
        _ReqInit(_nextId++, modelDir),
        // 229MB 模型冷加载 + 内联预热的最坏上限
        const Duration(seconds: 120),
      );
      if (ev.ok) {
        _ready = true;
        _loadedModelDir = modelDir;
      } else {
        _ready = false;
        print('🧵 [RecognitionService] ❌ 模型加载失败: ${ev.error}');
      }
      return ev.ok;
    } catch (e) {
      _ready = false;
      print('🧵 [RecognitionService] ❌ initialize 异常: $e');
      return false;
    }
  }

  /// PCM → 文本。未就绪抛 StateError；超时抛 TimeoutException。
  /// samples 为 16kHz 单声道归一化采样，与 diary_tab._recognizeSamplesToText 入参一致。
  Future<String> transcribe(Float32List samples) async {
    if (!_ready) throw StateError('recognition worker not ready');
    final port = _workerPort;
    if (port == null) throw StateError('recognition worker not ready');

    final id = _nextId++;
    final sw = Stopwatch()..start();
    final sampleSec = samples.length / 16000;
    final ev = await _request<_EvResult>(
      _ReqTranscribe(id, samples),
      const Duration(seconds: 120),
    );
    sw.stop();
    // 性能日志风格对齐 diary_tab 现有打印（[模块] 描述: Xms）
    print(
      '🧵 [RecognitionService] transcribe id=$id 音频 ${sampleSec.toStringAsFixed(2)}s 耗时 ${sw.elapsedMilliseconds}ms 字数 ${ev.text.length}',
    );
    return ev.text;
  }

  /// 预热（幂等不抛）：未就绪时静默返回
  Future<void> warmup() async {
    if (!_ready || _workerPort == null) return;
    try {
      await _request<_EvResult>(
        _ReqWarmup(_nextId++),
        const Duration(seconds: 30),
      );
    } catch (e) {
      print('🧵 [RecognitionService] ⚠️ warmup 失败(忽略): $e');
    }
  }

  /// 终态销毁：通知 worker 退出，isolate 退出后清理全部端口（listen 取消）
  Future<void> dispose() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    print('🧵 [RecognitionService] dispose：通知 worker 退出');

    try {
      _workerPort?.send(_ReqDispose(_nextId++));
    } catch (e) {
      print('🧵 [RecognitionService] ⚠️ dispose 发送失败(忽略): $e');
    }

    // 给 worker 自行退出的时间：正常路径 _exitPort 触发 _onWorkerDied 完成清理。
    // 兜底：worker 未响应则强杀（kill 同样会触发 exitPort 走同一清理路径）
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _isolate?.kill(priority: Isolate.immediate);

    // 幂等兜底（正常路径 _onWorkerDied 的 _shuttingDown 分支已清理过）
    _failAllPending(StateError('recognition worker disposed'));
    _cleanupAfterDeath();
  }

  // ============================================================
  // 内部：请求关联
  // ============================================================

  /// 分配 id → 存 Completer → send → 返回带超时的 future。
  /// 超时要把 _pending 里的项清掉（防泄漏 + 迟到回复不会误配到新请求）。
  Future<T> _request<T extends _WorkerEvent>(
    _WorkerRequest req,
    Duration timeout,
  ) {
    final completer = Completer<dynamic>();
    // 原始 future 可能以 error 完成而无直接 listener（timeout 派生的才是调用方
    // 持有的那个），ignore 防止 completeError 升级为 unhandled 异常炸控制台
    completer.future.ignore();
    _pending[req.id] = completer;
    _workerPort!.send(req);
    return completer.future
        .timeout(
          timeout,
          onTimeout: () {
            _pending.remove(req.id);
            throw TimeoutException(
              '请求超时(id=${req.id}, ${req.runtimeType})',
              timeout,
            );
          },
        )
        .then((msg) => msg as T);
  }

  // ============================================================
  // 内部：spawn 与握手
  // ============================================================

  /// 确保 worker 存活且握手完成
  Future<bool> _ensureSpawned() async {
    if (_workerPort != null) return true;
    if (_spawning && _spawnCompleter != null) {
      // spawn 进行中：归并等待同一次 spawn（不 double spawn）
      try {
        await _spawnCompleter!.future;
      } catch (_) {
        // _spawn 内部已打日志，这里只关心握手是否最终达成
      }
      return _workerPort != null;
    }
    return _spawn();
  }

  /// spawn worker isolate 并等待握手（worker 回传 SendPort）完成
  Future<bool> _spawn() {
    // 归并：spawn 进行中直接等它（防 double spawn）
    final inflight = _spawnCompleter;
    if (inflight != null) {
      return inflight.future.then((_) => true).catchError((Object _) => false);
    }

    final completer = Completer<void>();
    _spawnCompleter = completer;
    _spawning = true;

    final mainPort = ReceivePort();
    _mainPort = mainPort;
    mainPort.listen(_onWorkerMessage);

    // 握手超时兜底：worker 入口第一行就回 SendPort，正常毫秒级完成；
    // 15s 未握手视为 spawn 异常，防止 initialize 永久挂起
    final handshakeTimer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('worker 握手超时(15s)'));
      }
    });

    print('🧵 [RecognitionService] 正在 spawn worker isolate...');
    unawaited(
      Isolate.spawn(
            _recognitionWorkerEntry,
            mainPort.sendPort,
            onError: _errorPort.sendPort,
            onExit: _exitPort.sendPort,
            debugName: 'recognitionWorker',
          )
          .then((isolate) {
            _isolate = isolate;
            print('🧵 [RecognitionService] isolate 已 spawn，等待 Dart 握手...');
            // 握手 SendPort 到达后由 _onWorkerMessage complete completer
          })
          .catchError((Object e, StackTrace st) {
            completer.completeError(e, st);
          }),
    );

    return completer.future
        .then((_) => true)
        .catchError((Object e) {
          print('🧵 [RecognitionService] ❌ spawn/握手失败: $e');
          return false;
        })
        .whenComplete(() {
          handshakeTimer.cancel();
          if (identical(_spawnCompleter, completer)) {
            _spawnCompleter = null;
            _spawning = false;
          }
        });
  }

  /// worker → 主 的所有消息入口（含握手 SendPort 本身）
  void _onWorkerMessage(Object? msg) {
    if (msg is SendPort) {
      _workerPort = msg;
      // 新 worker 已握手：重置死亡去重标志，允许感知下一次退出/崩溃
      _deathHandled = false;
      final c = _spawnCompleter;
      if (c != null && !c.isCompleted) c.complete();
      print('🧵 [RecognitionService] ✅ worker 握手完成，SendPort 已就绪');
      return;
    }
    if (msg is _EvError) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return; // 超时清理后迟到的回复，忽略
      if (!completer.isCompleted) {
        completer.completeError(Exception('worker error: ${msg.error}'));
      }
      return;
    }
    if (msg is _WorkerEvent) {
      // _EvReady / _EvResult
      final completer = _pending.remove(msg.id);
      if (completer == null) return; // 超时清理后迟到的回复，忽略
      if (!completer.isCompleted) completer.complete(msg);
      return;
    }
    print('🧵 [RecognitionService] ⚠️ 收到未知消息类型: ${msg.runtimeType}');
  }

  // ============================================================
  // 内部：worker 死亡处理与自动重启
  // ============================================================

  /// worker 退出/崩溃的统一入口（_errorPort 与 _exitPort 双源触发，_deathHandled 去重）
  ///
  /// _errorPort 收到的 error 是 Isolate.onError 的消息
  /// （[errorDescription, stackTrace] 的 String 列表），仅用于打印。
  void _onWorkerDied(Object? error) {
    if (_shuttingDown) {
      // 主动 dispose 引发的正常退出：只做清理，不报错、不重启
      if (_deathHandled) return;
      _deathHandled = true;
      _failAllPending(StateError('recognition worker disposed'));
      _cleanupAfterDeath();
      print('🧵 [RecognitionService] worker 已退出（dispose 流程），端口已清理');
      return;
    }
    if (_deathHandled) return; // 同一次死亡的双触发，只处理一次
    _deathHandled = true;

    print('🧵 [RecognitionService] ❌ worker 异常死亡: $error');

    // 所有 in-flight 请求立即失败（调用方的 await 不用干等 120s 超时）
    _failAllPending(StateError('recognition worker died'));
    _ready = false;
    _workerPort = null;
    _isolate = null;
    _loadedModelDir = null;

    // 重启风暴防护：60s 滑动窗口计数
    final now = DateTime.now();
    if (_windowStart == null || now.difference(_windowStart!) > _crashWindow) {
      _windowStart = now;
      _crashesInWindow = 1;
    } else {
      _crashesInWindow++;
    }
    if (_crashesInWindow >= _maxCrashesInWindow) {
      print(
        '🧵 [RecognitionService] ❌ 60s 内已死亡 $_crashesInWindow 次，放弃自动重启（等待下一次显式 initialize）',
      );
      return;
    }

    final modelDir = _lastModelDir;
    if (modelDir == null) {
      print('🧵 [RecognitionService] ⚠️ 无历史模型目录，跳过自动重启');
      return;
    }

    print(
      '🧵 [RecognitionService] 🔁 自动重启 worker（窗口内第 $_crashesInWindow 次）并恢复模型...',
    );
    unawaited(() async {
      try {
        final ok = await initialize(modelDir);
        print(
          ok
              ? '🧵 [RecognitionService] ✅ 自动重启成功，模型已恢复'
              : '🧵 [RecognitionService] ❌ 自动重启后模型加载失败',
        );
      } catch (e) {
        print('🧵 [RecognitionService] ❌ 自动重启异常: $e');
      }
    }());
  }

  /// 把所有 in-flight 请求以 error 收尾并清空（超时兜底 / worker 死亡时调用）
  void _failAllPending(Object error) {
    if (_pending.isEmpty) return;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  /// 关闭全部监听端口并复位句柄状态。
  /// 仅在终态调用：dispose 完成 / worker 正常退出（非正常死亡走重启，不关端口）。
  void _cleanupAfterDeath() {
    _mainPort?.close();
    _mainPort = null;
    _errorPort.close();
    _exitPort.close();
    _workerPort = null;
    _isolate = null;
    _ready = false;
    _loadedModelDir = null;
  }
}
