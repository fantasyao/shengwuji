/// 常驻 TTS worker isolate 服务
///
/// 架构对齐 recognition_service.dart：sherpa_onnx FFI 的 OfflineTts 构造与
/// generate 合成全部下沉到常驻 worker isolate，主 isolate 只收发消息——
/// 文本传进、WAV 文件路径写出（合成结果直接在 worker 内落盘，不跨 isolate
/// 传大 Float32List），消除「Piper 合成期间主 isolate 冻结数百 ms~秒级」。
///
/// 隔离边界铁律（改动本文件前必读）：
/// - FFI 对象（OfflineTts / GeneratedAudio）永不跨 isolate
/// - 跨界消息只允许 String / int / bool（可拷贝传输）
/// - 模型不跨界传递：worker 内用主 isolate 发来的模型文件路径构建
///
/// 上游：tts_singleton.dart（门面，TtsSingleton 公开 API 保持不变）
/// 下游：worker isolate 内的 sherpa_onnx FFI（config 与迁移前 tts_singleton 逐字段一致）
library;

import 'dart:async';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

// 本文件同时运行在主 isolate 与 worker isolate，统一用 print 保持零 Flutter 依赖
// （日志前缀 🧵 [TtsService] 便于 logcat 过滤）
// ignore_for_file: avoid_print

// ============================================================
// 消息协议（主 → worker 请求 / worker → 主 事件）
//
// 手写消息类而非 json：与 recognition_service 同理由，字段仅
// int / String / bool，天然满足 isolate 传输约束（不含闭包、不含 FFI 指针）。
// ============================================================

/// 主 → worker 请求基类
abstract class _WorkerRequest {
  const _WorkerRequest(this.id);

  /// 请求关联 id：主侧分配，worker 原样带回，用于配对 _pending 里的 Completer
  final int id;
}

/// init：worker 内构建 OfflineTts（模型热切换 = 路径变了先建新再释旧）
class _ReqInit extends _WorkerRequest {
  const _ReqInit(super.id, this.modelPath, this.tokensPath, this.dataDirPath);

  final String modelPath;
  final String tokensPath;

  /// espeak-ng-data 目录本身（sherpa-onnx 直接在其下找 phontab/phondata，
  /// 传父目录会报 ".../phontab does not exist"，实测见旧版 tts_singleton 注释）
  final String dataDirPath;
}

/// 合成请求：文本进、WAV 文件出（worker 内 generate + writeWave）
class _ReqGenerate extends _WorkerRequest {
  const _ReqGenerate(super.id, this.text, this.wavPath);

  final String text;

  /// 临时 WAV 落盘路径（主侧生成的唯一文件名，worker 直接写这里）
  final String wavPath;
}

/// 销毁请求：free TTS 引擎 + Isolate.exit
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

/// _ReqGenerate 的结果：ok=false 且 empty=true 表示合成出空音频（跳过播放）
class _EvGenerated extends _WorkerEvent {
  const _EvGenerated(super.id, {required this.ok, this.empty = false});

  final bool ok;
  final bool empty;
}

/// worker 内处理失败的通用回执
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
/// native 崩溃（SIGABRT/SIGSEGV），由主侧 _exitPort/_errorPort 感知并
/// 按重启风暴策略处理。
void _ttsWorkerEntry(SendPort mainSendPort) {
  final port = ReceivePort();
  // 握手：主侧收到 SendPort 后才开始发送业务消息
  mainSendPort.send(port.sendPort);

  // ⚠️ Dart 层 FFI 绑定必须在 worker isolate 内独立初始化：
  // 绑定查找结果缓存在各 isolate 自己的 heap，互不共享——主 isolate
  // 调过的 initBindings() 对本 worker 无效（详见 recognition_service 同款注释）。
  // writeWave 同样走 FFI 绑定，必须在 initBindings() 之后调用。
  sherpa_onnx.initBindings();

  final core = _TtsWorkerCore(mainSendPort);

  port.listen((message) {
    // 每条消息整体 try/catch：常驻服务崩了等于 TTS 全下线
    int? id;
    if (message is _WorkerRequest) id = message.id;
    try {
      core.handle(message);
    } catch (e, st) {
      print('🧵 [TtsService] ❌ worker 处理消息异常: $e\n$st');
      mainSendPort.send(_EvError(id ?? -1, e.toString()));
    }
  });
}

/// worker isolate 内的 TTS 核心：持有 FFI 对象，生命周期与 worker 相同
/// （字段永不跨界——外界只能通过消息驱动）
class _TtsWorkerCore {
  _TtsWorkerCore(this._main);

  /// 回主 isolate 的发送口
  final SendPort _main;

  /// 当前 TTS 引擎（FFI 对象，仅 worker isolate 内触碰）
  sherpa_onnx.OfflineTts? _tts;

  /// 已加载的模型路径三元组签名（init 幂等判断 + 热切换依据）
  String? _loadedSignature;

  void handle(Object? message) {
    if (message is _ReqInit) {
      _handleInit(message);
    } else if (message is _ReqGenerate) {
      if (_tts == null) {
        _main.send(_EvError(message.id, 'worker not ready'));
        return;
      }
      _handleGenerate(message);
    } else if (message is _ReqDispose) {
      _tts?.free();
      _tts = null;
      _loadedSignature = null;
      // Isolate.exit：原子地发送最后一条消息并退出
      Isolate.exit(_main, _EvGenerated(message.id, ok: true));
    }
  }

  /// init / reload：路径相同直接幂等回 ready；变了先建新再释旧（热切换不中断服务）
  void _handleInit(_ReqInit msg) {
    final signature = '${msg.modelPath}|${msg.tokensPath}|${msg.dataDirPath}';
    if (_tts != null && _loadedSignature == signature) {
      _main.send(_EvReady(msg.id, true));
      return;
    }

    final sw = Stopwatch()..start();
    try {
      // ⚠️ config 必须与迁移前 tts_singleton.dart 的 OfflineTtsConfig 逐字段一致：
      // Piper 中文模型走 espeak-ng 路径——lexicon 留空（否则与 espeak-ng 音素化冲突）、
      // numThreads 2、maxNumSenetences 2。两边配置漂移 = 音色/断句行为不一致。
      final vitsConfig = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: msg.modelPath,
        lexicon: '', // ⚠️ Piper 走 espeak-ng 路径，必须留空
        tokens: msg.tokensPath,
        dataDir: msg.dataDirPath,
      );
      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: vitsConfig,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
      final config = sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        ruleFsts: '',
        maxNumSenetences: 2,
      );

      // 先建新再释旧：OfflineTts(config) 抛异常时旧实例原封不动
      final old = _tts;
      final next = sherpa_onnx.OfflineTts(config);
      _tts = next;
      _loadedSignature = signature;
      old?.free();

      sw.stop();
      print(
        '🧵 [TtsService] worker 模型加载完成: ${sw.elapsedMilliseconds}ms, model=${msg.modelPath}',
      );
      _main.send(_EvReady(msg.id, true));
    } catch (e, st) {
      sw.stop();
      print(
        '🧵 [TtsService] ❌ worker 模型加载失败(${sw.elapsedMilliseconds}ms): $e\n$st',
      );
      _main.send(_EvReady(msg.id, false, e.toString()));
    }
  }

  /// 合成 + 落盘 WAV（音频数据不跨 isolate，只回执成败/空音频）
  ///
  /// generate 是同步 FFI 阻塞调用，但在 worker 内执行，不冻结主 isolate UI。
  /// writeWave 失败抛异常 → 外层 listen 统一转 _EvError。
  void _handleGenerate(_ReqGenerate msg) {
    final audio = _tts!.generate(text: msg.text, sid: 0, speed: 1.0);
    if (audio.samples.isEmpty) {
      _main.send(_EvGenerated(msg.id, ok: false, empty: true));
      return;
    }
    final ok = sherpa_onnx.writeWave(
      filename: msg.wavPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );
    if (!ok) {
      throw Exception('writeWave 返回 false: ${msg.wavPath}');
    }
    _main.send(_EvGenerated(msg.id, ok: true));
  }
}

// ============================================================
// 主 isolate 侧
// ============================================================

/// 常驻 TTS 服务（主 isolate 侧句柄）
///
/// 用法（经 tts_singleton.dart 门面代理，业务层勿直接使用）：
/// ```dart
/// final service = TtsService();
/// if (await service.initialize(modelPath: ..., tokensPath: ..., dataDirPath: ...)) {
///   final ok = await service.generateToWav(text, wavPath);
/// }
/// ```
///
/// - worker 崩溃自动重启（60s 窗口内 >=3 次死亡则放弃，等下一次显式 initialize）
/// - dispose 是终态操作：之后本实例不可再用，需要时请创建新实例
class TtsService {
  TtsService() {
    // isolate 崩溃/退出的感知通道（spawn 时注入；onError 常先于 onExit 触发，
    // 由 _deathHandled 去重）
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

  /// worker 死亡前最后使用的模型路径（自动重启后用它重新 initialize）
  String? _lastModelPath;
  String? _lastTokensPath;
  String? _lastDataDirPath;

  // ---- 重启风暴防护：60s 滑动窗口内 >=3 次死亡 → 放弃自动重启 ----
  // （dataDir 配错这类必然复现的 native 崩溃会循环杀 worker，无防护会无限重启）
  static const _crashWindow = Duration(seconds: 60);
  static const _maxCrashesInWindow = 3;
  int _crashesInWindow = 0;
  DateTime? _windowStart;

  bool _shuttingDown = false;

  /// onError 与 onExit 对同一次死亡会连续双触发，此标志去重
  bool _deathHandled = false;

  /// 是否就绪（模型已加载且 worker 存活）
  bool get isReady => _ready;

  // ============================================================
  // 公开 API
  // ============================================================

  /// 初始化 / 热切换模型。已就绪 → 幂等返回 true；否则 spawn（如需）+ 发 _ReqInit → 等 _EvReady。
  Future<bool> initialize({
    required String modelPath,
    required String tokensPath,
    required String dataDirPath,
  }) async {
    // 先记下来：worker 若死亡，自动重启要用它恢复
    _lastModelPath = modelPath;
    _lastTokensPath = tokensPath;
    _lastDataDirPath = dataDirPath;

    if (_shuttingDown) {
      print('🧵 [TtsService] initialize 拒绝：服务已 dispose');
      return false;
    }
    if (_ready && _workerPort != null) {
      return true;
    }

    final spawned = await _ensureSpawned();
    if (!spawned) return false;

    try {
      final ev = await _request<_EvReady>(
        _ReqInit(_nextId++, modelPath, tokensPath, dataDirPath),
        // 20MB x_low 模型冷加载的上限（OfflineTts 构造在 worker 内，不再卡主线程）
        const Duration(seconds: 60),
      );
      _ready = ev.ok;
      if (!ev.ok) {
        print('🧵 [TtsService] ❌ 模型加载失败: ${ev.error}');
      }
      return ev.ok;
    } catch (e) {
      _ready = false;
      print('🧵 [TtsService] ❌ initialize 异常: $e');
      return false;
    }
  }

  /// 合成文本并把结果写成 WAV 文件（wavPath 由调用方生成临时唯一路径）。
  ///
  /// 返回 false = 合成出空音频（调用方跳过播放）；
  /// 抛异常 = worker 错误/超时/死亡（调用方按失败丢弃本句）。
  Future<bool> generateToWav(String text, String wavPath) async {
    if (!_ready || _workerPort == null) {
      throw StateError('tts worker not ready');
    }
    final ev = await _request<_EvGenerated>(
      _ReqGenerate(_nextId++, text, wavPath),
      // x_low 模型单句合成典型 <2s；60s 覆盖极端长文本
      const Duration(seconds: 60),
    );
    if (ev.empty) return false;
    return ev.ok;
  }

  /// 终态销毁：通知 worker 退出，isolate 退出后清理全部端口。
  /// 之后本实例不可再用；TtsSingleton 如需重新初始化请换新实例。
  Future<void> dispose() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    print('🧵 [TtsService] dispose：通知 worker 退出');

    try {
      _workerPort?.send(_ReqDispose(_nextId++));
    } catch (e) {
      print('🧵 [TtsService] ⚠️ dispose 发送失败(忽略): $e');
    }

    // 给 worker 自行退出的时间：正常路径 _exitPort 触发 _onWorkerDied 完成清理。
    // 兜底：worker 未响应则强杀（kill 同样会触发 exitPort 走同一清理路径）
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _isolate?.kill(priority: Isolate.immediate);

    // 幂等兜底（正常路径 _onWorkerDied 的 _shuttingDown 分支已清理过）
    _failAllPending(StateError('tts worker disposed'));
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
    // 持有的那个），ignore 防止 completeError 升级为 unhandled 异常
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

    print('🧵 [TtsService] 正在 spawn worker isolate...');
    unawaited(
      Isolate.spawn(
            _ttsWorkerEntry,
            mainPort.sendPort,
            onError: _errorPort.sendPort,
            onExit: _exitPort.sendPort,
            debugName: 'ttsWorker',
          )
          .then((isolate) {
            _isolate = isolate;
            print('🧵 [TtsService] isolate 已 spawn，等待 Dart 握手...');
          })
          .catchError((Object e, StackTrace st) {
            completer.completeError(e, st);
          }),
    );

    return completer.future
        .then((_) => true)
        .catchError((Object e) {
          print('🧵 [TtsService] ❌ spawn/握手失败: $e');
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
      print('🧵 [TtsService] ✅ worker 握手完成，SendPort 已就绪');
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
      // _EvReady / _EvGenerated
      final completer = _pending.remove(msg.id);
      if (completer == null) return; // 超时清理后迟到的回复，忽略
      if (!completer.isCompleted) completer.complete(msg);
      return;
    }
    print('🧵 [TtsService] ⚠️ 收到未知消息类型: ${msg.runtimeType}');
  }

  // ============================================================
  // 内部：worker 死亡处理与自动重启
  // ============================================================

  /// worker 退出/崩溃的统一入口（_errorPort 与 _exitPort 双源触发，_deathHandled 去重）
  void _onWorkerDied(Object? error) {
    if (_shuttingDown) {
      // 主动 dispose 引发的正常退出：只做清理，不报错、不重启
      if (_deathHandled) return;
      _deathHandled = true;
      _failAllPending(StateError('tts worker disposed'));
      _cleanupAfterDeath();
      print('🧵 [TtsService] worker 已退出（dispose 流程），端口已清理');
      return;
    }
    if (_deathHandled) return; // 同一次死亡的双触发，只处理一次
    _deathHandled = true;

    print('🧵 [TtsService] ❌ worker 异常死亡: $error');

    // 所有 in-flight 请求立即失败（speak 的 await 不用干等 60s 超时）
    _failAllPending(StateError('tts worker died'));
    _ready = false;
    _workerPort = null;
    _isolate = null;

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
        '🧵 [TtsService] ❌ 60s 内已死亡 $_crashesInWindow 次，放弃自动重启（等待下一次显式 initialize）',
      );
      return;
    }

    final modelPath = _lastModelPath;
    final tokensPath = _lastTokensPath;
    final dataDirPath = _lastDataDirPath;
    if (modelPath == null || tokensPath == null || dataDirPath == null) {
      print('🧵 [TtsService] ⚠️ 无历史模型路径，跳过自动重启');
      return;
    }

    print(
      '🧵 [TtsService] 🔁 自动重启 worker（窗口内第 $_crashesInWindow 次）并恢复模型...',
    );
    unawaited(() async {
      try {
        final ok = await initialize(
          modelPath: modelPath,
          tokensPath: tokensPath,
          dataDirPath: dataDirPath,
        );
        print(
          ok
              ? '🧵 [TtsService] ✅ 自动重启成功，模型已恢复'
              : '🧵 [TtsService] ❌ 自动重启后模型加载失败',
        );
      } catch (e) {
        print('🧵 [TtsService] ❌ 自动重启异常: $e');
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
  }
}
