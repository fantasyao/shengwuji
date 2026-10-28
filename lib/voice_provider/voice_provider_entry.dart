//! fcitx5 输入法语音输入 Provider 的 headless Dart 入口。
//!
//! 由原生 [VoiceInputProviderService] 拉起独立 FlutterEngine 运行本入口
//! （不进主 App UI）。链路：
//!
//!   IME 录音(Kotlin AIDL) → 'feed'(PCM16) → Silero VAD 切段
//!   → RecognitionService.transcribe（worker isolate）
//!   → TextProcessor 热词纠错 → ContextCorrector 同音词上下文纠错
//!   → 'segmentFinal'(整段文本) → IME 上屏
//!
//! 通道协议（MethodChannel `shengwuji/voice_provider`）：
//! - Dart → Kotlin：`ready` / `segmentFinal`(String) / `sessionEnded` /
//!   `error`({code, message})
//! - Kotlin → Dart：`startSession`(params) / `feed`(PCM16 bytes) /
//!   `endStream` / `cancel`
//!
//! 与主 App 的悬浮窗引擎同理：自定义入口函数必须声明在根库（main.dart），
//! 这里只放实现（见 main.dart overlayMain 处注释）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../app_logger.dart';
import '../correction/context_corrector.dart';
import '../recognizer_singleton.dart';
import '../text_processor.dart';
import '../vad_singleton.dart';

const MethodChannel _channel = MethodChannel('shengwuji/voice_provider');

/// headless 引擎入口（main.dart 里声明符号后委托到这里）
Future<void> voiceProviderMain() async {
  AppLogger.setEngine('voice_provider');
  WidgetsFlutterBinding.ensureInitialized();
  sherpa_onnx.initBindings();
  log('🎙️ [voiceProviderMain] provider 引擎入口已执行');
  await VoiceProviderHost.instance.start();
}

/// 语音 Provider 桥接宿主：单引擎生命周期内服务多次会话。
class VoiceProviderHost {
  VoiceProviderHost._();

  static final VoiceProviderHost instance = VoiceProviderHost._();

  final TextProcessor _processor = TextProcessor();

  bool _pipelineReady = false;
  bool _sessionActive = false;

  /// 会话被 IME 侧 cancel/stop 中止。置位后丢弃所有在途识别结果
  /// （endStream 的收尾不属于中止，不受此标志影响）。
  bool _cancelled = false;

  /// 段识别串行链：保证 segmentFinal 与说话顺序一致（SenseVoice worker
  /// 内部本就串行 decode，链式排队只保证回调顺序，无额外开销）。
  Future<void> _chain = Future.value();

  Future<void> start() async {
    _channel.setMethodCallHandler(_handle);
    try {
      // 模型未部署时这里会从 APK assets 拷贝 229MB（首次安装从未打开过
      // App 的场景），耗时可能超出 fcitx 侧 12s onReady 超时——该会话会被
      // fcitx 判超时重试一次；拷贝只发生一次，之后秒就绪。
      await RecognizerSingleton.preloadModelPath();
      final ok = await RecognizerSingleton.instance.initialize();
      if (!ok) {
        log('❌ [voiceProviderMain] 模型加载失败');
        await _channel.invokeMethod('error', {
          'code': 2, // MODEL_LOAD_FAILED
          'message': 'model load failed',
        });
        return;
      }
      await VadSingleton.instance.initialize();
      await _processor.loadConfigs();
      // 上下文纠错词库/统计后台预载（不阻塞 ready；correct 内部也会自等
      // ensureLoaded，首次段识别前没载完只是那条等一下）
      unawaited(ContextCorrector.instance.ensureLoaded());
      _pipelineReady = true;
      log('✅ [voiceProviderMain] 管线就绪，上报 ready');
      await _channel.invokeMethod('ready');
    } catch (e) {
      log('❌ [voiceProviderMain] 初始化异常: $e');
      await _channel.invokeMethod('error', {'code': 0, 'message': '$e'});
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'startSession':
        _cancelled = false;
        _sessionActive = true;
        // 丢掉上次会话残留在 VAD 环形缓冲里的样本
        VadSingleton.instance.vad?.clear();
        log('🎙️ [voiceProvider] startSession params=${call.arguments}');
        return null;
      case 'feed':
        _onPcm(call.arguments as Uint8List);
        return null;
      case 'endStream':
        await _endStream();
        return null;
      case 'cancel':
        log('🎙️ [voiceProvider] cancel');
        _cancelled = true;
        _sessionActive = false;
        VadSingleton.instance.vad?.clear();
        return null;
      default:
        throw MissingPluginException('unknown method: ${call.method}');
    }
  }

  void _onPcm(Uint8List bytes) {
    if (!_sessionActive || !_pipelineReady) return;
    final vad = VadSingleton.instance.vad;
    if (vad == null) return;
    final samples = _convertBytesToFloat32(bytes);
    vad.acceptWaveform(samples);
    _drainSegments();
  }

  /// 取出 VAD 已切好的段，按序进入识别链（不 await，与搬家模式同构）
  void _drainSegments() {
    final vad = VadSingleton.instance.vad;
    if (vad == null) return;
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      final samples = seg.samples;
      if (samples.isEmpty) continue;
      _chain = _chain.then((_) => _transcribeOne(samples));
    }
  }

  Future<void> _transcribeOne(Float32List samples) async {
    if (_cancelled) return;
    try {
      final text = await RecognizerSingleton.instance.transcribe(samples);
      if (_cancelled || text.trim().isEmpty) return;
      // 两层纠错，与悬浮窗速记同款顺序：
      // 1) TextProcessor 热词纠错（字面热词 + 正则规则 + 音素热词）
      var corrected = _processor.process(text);
      // 2) 同音词上下文纠错（词库来自 assets，统计走主 App 共享的同一
      //    SQLite；过不了置信度阈值保持原文）。失败降级保留热词结果
      try {
        final ctxResult = await ContextCorrector.instance.correct(corrected);
        if (ctxResult.changed) corrected = ctxResult.text;
      } catch (e) {
        log('⚠️ [voiceProvider] 上下文纠错失败(保留热词结果): $e');
      }
      if (corrected.trim().isEmpty) return;
      log('🎙️ [voiceProvider] segment final: $corrected');
      await _channel.invokeMethod('segmentFinal', corrected);
    } catch (e) {
      log('❌ [voiceProvider] 单段识别失败: $e');
    }
  }

  /// 收尾：冲出 VAD 尾段 → 等全部在途识别完成 → 通知 Kotlin 会话结束
  Future<void> _endStream() async {
    log('🎙️ [voiceProvider] endStream');
    _sessionActive = false;
    if (!_pipelineReady) return;
    VadSingleton.instance.vad?.flush();
    _drainSegments();
    final pending = _chain;
    await pending;
    if (_cancelled) return; // cancel 路径已由 Kotlin 回 onSessionEnded
    try {
      await _channel.invokeMethod('sessionEnded');
    } catch (e) {
      log('❌ [voiceProvider] sessionEnded 上报失败: $e');
    }
  }

  /// PCM16 little-endian → 归一化 Float32（与 record_tab._convertBytesToFloat32
  /// 同构；ByteData.sublistView 兼容非对齐 offset）
  Float32List _convertBytesToFloat32(Uint8List bytes) {
    final int sampleCount = bytes.lengthInBytes ~/ 2;
    final float32Data = Float32List(sampleCount);
    final byteData = ByteData.sublistView(bytes);
    for (int i = 0; i < sampleCount; i++) {
      final int sample = byteData.getInt16(i * 2, Endian.little);
      float32Data[i] = sample / 32768.0;
    }
    return float32Data;
  }
}
