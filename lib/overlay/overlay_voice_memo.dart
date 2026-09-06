// 项目策略：语音速记链路的运行日志依赖 print 输出到 logcat（对齐 recognition_service.dart 先例）
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/overlay/accessibility_overlay.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/recognizer_singleton.dart';
import 'package:shengwuji_app/text_processor.dart';
import 'package:shengwuji_app/utils/diary_sync_bridge.dart';
import 'package:shengwuji_app/utils/wav_file.dart';

/// 语音速记状态机状态
enum OverlayVoiceMemoState {
  /// 空闲：无录音、无转写（把手/面板分支正常渲染）
  idle,

  /// 录音中：PCM 流累积中，变长录音胶囊 UI
  recording,

  /// 转写中：录音已停止，转写 Future 在后台跑（三点跳动胶囊 UI）
  transcribing,
}

/// 悬浮窗语音速记控制器（ChangeNotifier）
///
/// 上下游关系：
/// - 触发方：Kotlin `triggerVoiceMemoOverlay` 长按音量上键（action=record）经
///   `com.shengwuji.app/accessibility_overlay` channel 发 `startVoiceMemo` /
///   `stopVoiceMemo` → OverlayHome 转发到本类 start()/stop()
/// - 回执方：start 成败的回执由 OverlayHome 发（voiceMemoStarted /
///   voiceMemoFailed）；stop 的回执 voiceMemoStopped 和运行期失败的
///   voiceMemoFailed 由本类自己发。Kotlin 侧 3s 超时兜底，回执晚到也幂等
/// - 互斥桥：读写 SharedPreferences 的 `is_recording`（与 diary_tab 的
///   `_setRecordingFlag` 同一 key，跨 engine 靠 reload 破缓存隔离）
/// - 临时静音：start 开录后 muteMedia、stop/fail 收尾 restoreMedia（原生
///   MediaMuteHelper，与主 App 快捷录音共用；录音中按音量减是否保持静音由
///   设置页「按音量减保持静音」开关在原生 adjustVolume 处统一标记）
/// - UI 消费方：OverlayVoiceMemoBar 监听 state / elapsedSeconds 渲染胶囊
class OverlayVoiceMemoController extends ChangeNotifier {
  OverlayVoiceMemoState _state = OverlayVoiceMemoState.idle;

  /// 当前状态（idle / recording / transcribing）
  OverlayVoiceMemoState get state => _state;

  /// 仅测试用：直接迁移状态（正常流转必须走 start/stop/fail——它们带
  /// 权限/录音资源/互斥桥的清理，绕过会泄漏）
  @visibleForTesting
  void setStateForTest(OverlayVoiceMemoState state) {
    _state = state;
    notifyListeners();
  }

  final AudioRecorder _recorder = AudioRecorder();

  /// PCM 流订阅（手动管理，stop/fail/dispose 时 cancel）
  StreamSubscription? _streamSub;

  /// 录音 PCM 字节累积缓冲（16kHz 16bit 单声道，落盘 WAV 的数据源）
  final BytesBuilder _pcmBuffer = BytesBuilder(copy: false);

  /// 录音开始时间（计算 elapsed 用，转写完成后清空）
  DateTime? _startTime;

  /// 占位入库拿到的 diary id（worker 转写完成后 updateDiary 回填 content 用）
  int? _pendingDiaryId;

  /// overlay engine 直连 sqflite 的写入句柄（对齐 overlay_data_client 的复用方式）
  final DbHelper _dbHelper = DbHelper();

  /// 100ms UI tick：驱动 notifyListeners → 胶囊变长/计时刷新
  Timer? _tickTimer;

  /// 上限自动停计时（防按忘，上限值见 OverlayConstants.voiceMemoMaxSeconds）
  Timer? _maxTimer;

  /// worker idle 释放计时（转写收尾排定，新录音 start 时取消作废）。
  /// overlay engine 是独立 isolate，RecognizerSingleton.instance 拿到的是本
  /// isolate 自己的实例（自带独立 worker，不与主 engine 共享）——闲置释放
  /// 只影响 overlay 这份，主 App 的识别不受影响
  Timer? _workerIdleTimer;

  /// 已累积的 PCM 字节数（上限 300s × 32000B/s ≈ 9.6MB，内存压力可忽略）
  int get sampleBytes => _pcmBuffer.length;

  /// 录音已进行秒数（转写态冻结在停止时刻的值，由 UI 兜底 min 上限）
  double get elapsedSeconds {
    final start = _startTime;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMilliseconds / 1000.0;
  }

  /// 开始语音速记录音。返回是否成功（失败由调用方回执 voiceMemoFailed）。
  ///
  /// 调用方：OverlayHome 收到 Kotlin `startVoiceMemo` 消息时。
  /// 失败路径全部 return false（不回执、不改状态），资源清理在各自分支内完成。
  Future<bool> start() async {
    // 1. 防重入：录音/转写中再来一次 startVoiceMemo（Kotlin toggle 正常不会发，
    //    这里兜底防状态机错乱）
    if (_state != OverlayVoiceMemoState.idle) {
      print('⚠️ [OverlayVoiceMemo] 非空闲态(${_state.name})收到 startVoiceMemo，忽略');
      return false;
    }

    // 2. 权限只查不请求：overlay engine 无 Activity，request 会直接返回 false，
    //    必须由用户先在主 App 里授予过麦克风权限（首次冷启动 SplashScreen 已请求过）
    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      print('🎤 [OverlayVoiceMemo] 麦克风权限未授予($micStatus)，语音速记无法启动');
      return false;
    }

    // 3. 互斥桥：读主 App 写的 is_recording（跨 engine prefs 内存缓存隔离，必须
    //    reload 才能读到主 engine 的新值）。为 true = 主 App 正在录音，让位
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } catch (e) {
      print('❌ [OverlayVoiceMemo] 读取互斥桥(is_recording)失败: $e');
      return false;
    }
    if (prefs.getBool('is_recording') == true) {
      print('🎤 [OverlayVoiceMemo] is_recording=true（主 App 录音中），互斥让位');
      return false;
    }

    // 4. 通过检查，先占住互斥桥再开麦（对齐 diary_tab _setRecordingFlag 的 key/写法）
    try {
      await prefs.setBool('is_recording', true);
    } catch (e) {
      print('❌ [OverlayVoiceMemo] 写入互斥桥(is_recording=true)失败: $e');
      return false;
    }

    // 5. 开录音流（对齐 record_tab 的 RecordConfig：PCM16 / 16kHz / 单声道）
    _pcmBuffer.clear();
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
    } catch (e) {
      // 开麦失败：回滚互斥桥，保持 idle（调用方回执 voiceMemoFailed）
      print('❌ [OverlayVoiceMemo] startStream 失败: $e');
      await _clearRecordingFlag();
      return false;
    }
    _streamSub = stream.listen(
      (data) => _pcmBuffer.add(data),
      onError: (Object e) {
        // 录音中途出错（被系统抢麦等）：走 fail 路径清理 + 回执
        print('❌ [OverlayVoiceMemo] 录音流出错: $e');
        fail('录音流出错: $e');
      },
    );

    // 5.5 临时静音媒体（与主 App 快捷录音同一份交互，原生同走 MediaMuteHelper）：
    //    开流成功后才静音（失败路径无需回滚）；「按音量减保持静音」的标记方在
    //    原生 adjustVolume，本类不感知开关。失败只打日志不阻塞录音（对齐
    //    diary_tab 静音失败的降级策略）
    try {
      await AccessibilityOverlay.muteMedia();
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] 静音媒体失败(不影响录音): $e');
    }

    // 6. 计时器：100ms tick 驱动 UI（胶囊变长 + mm:ss 刷新）
    _startTime = DateTime.now();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      notifyListeners();
    });
    // 7. 上限自动停（防按忘；print 标记便于区分用户主动停）
    _maxTimer = Timer(
      const Duration(seconds: OverlayConstants.voiceMemoMaxSeconds),
      () {
        print(
          '⏱️ [OverlayVoiceMemo] 录音达 ${OverlayConstants.voiceMemoMaxSeconds}s 上限，自动停止',
        );
        stop();
      },
    );

    // 8. 懒启动识别 worker（录音期间预热模型，与录音并行）：
    //    - preloadModelPath 解析模型目录（rootBundle/prefs 在 overlay engine 均
    //      可用；主 App 已拷贝过内置模型，_ensureBundledModel 见文件存在即跳过）
    //    - initialize 不 await（模型加载与录音并行，fire-and-forget），失败只
    //      print 不中断录音——_transcribeAndSave 里还有一次 await 兜底
    //    - 取消上次转写完排定的 idle 释放（新录音开始，释放计划作废；dispose
    //      会重建 worker，见 recognizer_singleton.dispose）
    _workerIdleTimer?.cancel();
    _workerIdleTimer = null;
    try {
      await RecognizerSingleton.preloadModelPath();
      unawaited(
        RecognizerSingleton.instance.initialize().then((ok) {
          print(
            ok
                ? '✅ [OverlayVoiceMemo] 识别 worker 已就绪(录音期间并行预热)'
                : '⚠️ [OverlayVoiceMemo] 识别 worker 预热失败(转写时再兜底初始化)',
          );
        }).catchError((Object e) {
          print('⚠️ [OverlayVoiceMemo] 识别 worker 预热异常(转写时再兜底): $e');
        }),
      );
    } catch (e) {
      // 路径解析失败不阻塞录音：转写阶段兜底 initialize 会再试一次
      print('⚠️ [OverlayVoiceMemo] 模型路径预加载失败(不中断录音): $e');
    }

    _state = OverlayVoiceMemoState.recording;
    notifyListeners();
    print('✅ [OverlayVoiceMemo] 录音已开始');
    return true;
  }

  /// 停止录音并进入转写。
  ///
  /// 调用方：OverlayHome 收到 Kotlin `stopVoiceMemo` 消息 / 上限 Timer。
  /// 注意入口同步置 transcribing（await 前完成），防双触发重入。
  Future<void> stop() async {
    if (_state != OverlayVoiceMemoState.recording) return;
    _state = OverlayVoiceMemoState.transcribing;
    notifyListeners(); // UI 切三点跳动胶囊

    _tickTimer?.cancel();
    _tickTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    await _streamSub?.cancel();
    _streamSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      // stop 抛错不阻塞主流程：PCM 已在内存缓冲里，继续走转写
      print('⚠️ [OverlayVoiceMemo] recorder.stop 异常(忽略): $e');
    }

    // finally 语义：无论后续转写成败，先清互斥桥 + 恢复媒体音量 + 回执 Kotlin
    // （Kotlin 侧 3s 超时兜底，回执晚于 3s 也幂等）
    await _clearRecordingFlag();
    // 恢复媒体音量：用户录音中按过音量减（开关开启时原生已标记 keep_muted）
    // 则保持静音，否则回到录音前的音量——与主 App 快捷录音停录语义一致
    try {
      await AccessibilityOverlay.restoreMedia();
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] 恢复媒体音量失败: $e');
    }
    AccessibilityOverlay.voiceMemoStopped();

    // 转写与落盘（落盘 + 占位入库 + worker isolate 转写回填，见 _transcribeAndSave）
    await _transcribeAndSave();
  }

  /// 运行期失败清理：录音资源 + 互斥桥 + 状态复位 + 回执 voiceMemoFailed。
  ///
  /// 调用方：录音流 onError（控制器内部）。Kotlin 收到回执后会隐藏浮窗。
  Future<void> fail(String reason) async {
    print('❌ [OverlayVoiceMemo] 语音速记失败: $reason');
    _tickTimer?.cancel();
    _tickTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    try {
      await _streamSub?.cancel();
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] 清理流订阅异常(忽略): $e');
    }
    _streamSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] fail 清理 recorder.stop 异常(忽略): $e');
    }
    await _clearRecordingFlag();
    // 录音已发生（可能已静音媒体），失败路径同样恢复——restore 对无静音现场
    // 幂等（原生按 saved_media_volume 判断），与 mute 是否成功解耦
    try {
      await AccessibilityOverlay.restoreMedia();
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] fail 恢复媒体音量失败(忽略): $e');
    }
    _pcmBuffer.clear();
    _startTime = null;
    _state = OverlayVoiceMemoState.idle;
    notifyListeners();
    AccessibilityOverlay.voiceMemoFailed(reason);
  }

  /// 清除 is_recording 互斥桥标志（主 App 原生层也在读这个 key 判断录音状态）
  Future<void> _clearRecordingFlag() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_recording', false);
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] 清除互斥桥(is_recording=false)失败: $e');
    }
  }

  /// 转写与落盘（防丢落盘 + 占位入库 + worker isolate 转写回填）。
  ///
  /// 对齐主 App diary_tab stopListening 阶段 2.5 的防丢模式：先把 PCM 落成
  /// WAV + insertDiary 占位行（content=''），再经 RecognizerSingleton（本
  /// isolate 自己的 worker）转写 + 热词纠错，updateDiary 回填 content。
  /// 转写崩溃/失败/识别为空时录音不丢（占位保留），用户可在主 App 里对该
  /// 卡片"再次转写"。完成后 state → idle + notifyListeners，由 OverlayHome
  /// 监听切换回展开面板并刷新日记列表（新卡在顶部）。
  Future<void> _transcribeAndSave() async {
    final durationSec = elapsedSeconds; // _startTime 尚未清空，冻结时长
    // takeBytes() 取走后 _pcmBuffer 即清空，长度信息先落到局部变量再打日志
    final pcm = _pcmBuffer.takeBytes();
    print(
      '🔄 [OverlayVoiceMemo] 进入转写(落盘入库): '
      '时长=${durationSec.toStringAsFixed(1)}s 字节=${pcm.length} '
      '(≈${(pcm.length / 32000).toStringAsFixed(1)}s PCM)',
    );

    // ── 空录音防护：<3200B ≈ 0.1s 视为误触，丢弃（对齐主 App 短录音语义） ──
    if (pcm.length < 3200) {
      print('⚠️ [OverlayVoiceMemo] 录音过短(${pcm.length}B < 3200B)，丢弃不落盘');
      // start() 可能已懒启动 worker（模型内存已占），丢弃路径同样要排定释放
      _finishTranscribe();
      return;
    }

    // ── 1. 落盘 WAV：对齐主 App 日记录音目录 diary_audio/（主 App 可见可播可再次转写） ──
    final String wavPath;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, 'diary_audio'));
      // create(recursive: true) 幂等（目录已存在不抛错），失败走 catch
      await folder.create(recursive: true);
      // 文件名时间戳格式照抄主 App diary_tab._writeWavFile
      final fileName =
          'diary_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.wav';
      wavPath = await writeWavFile(
        pcm,
        p.join(folder.path, fileName),
        sampleRate: 16000,
      );
      print('💾 [OverlayVoiceMemo] WAV 已落盘: $wavPath');
    } catch (e) {
      // 无音频可救：直接结束（不写占位行）
      print('❌ [OverlayVoiceMemo] WAV 落盘失败(丢弃本次录音): $e');
      _finishTranscribe();
      return;
    }

    // ── 2. 占位入库：content=''，转写完成后 updateDiary 回填 ──
    try {
      _pendingDiaryId = await _dbHelper.insertDiary(
        '', // 占位空文本，下方第 3 步 worker 转写后回填
        audioPath: wavPath,
        duration: durationSec.round(),
      );
      print('💾 [OverlayVoiceMemo] 占位入库 id=$_pendingDiaryId wav=$wavPath');
      // 主 App 感知占位行插入（跨 engine 计数桥，见 DiarySyncBridge）——
      // 转写尚需数秒，先 bump 让主 App 恢复前台时就能看到占位卡
      DiarySyncBridge.bump();
    } catch (e) {
      // 入库失败但保留 WAV 文件（音频数据不丢）
      print('❌ [OverlayVoiceMemo] 占位入库失败(WAV 已保留): $e');
      _finishTranscribe();
      return;
    }

    // ── 3. worker isolate 转写 → updateDiary 回填 ──

    // 3.1 initialize 兜底：start() 的懒预热若失败/未完成，这里等待完成
    //     （懒启动进行中时 initialize 内部会归并等待同一轮，不会 double spawn）
    try {
      final ok = await RecognizerSingleton.instance.initialize();
      if (!ok) {
        print('❌ [OverlayVoiceMemo] 识别引擎初始化失败，转写跳过(占位保留)');
        _finishTranscribe();
        return;
      }
    } catch (e) {
      print('❌ [OverlayVoiceMemo] 识别引擎初始化异常，转写跳过(占位保留): $e');
      _finishTranscribe();
      return;
    }

    // 3.2 PCM 字节 → Float32 归一化采样（同构复用 diary_tab._convertBytesToFloat32）
    final samples = _pcmBytesToFloat32(pcm);

    // 3.3 worker 转写（decode 在常驻 worker isolate 内，不冻结 UI；
    //     120s 超时由 RecognitionService 内部兜底，超时/异常走失败收尾）
    final String text;
    try {
      text = await RecognizerSingleton.instance.transcribe(samples);
    } catch (e) {
      print('❌ [OverlayVoiceMemo] 转写失败(占位保留，主 App 可再次转写): $e');
      _finishTranscribe();
      return;
    }
    if (text.isEmpty) {
      // 识别为空与主 App 语义一致：不写库占位文本，音频保留可再次转写
      print('⚠️ [OverlayVoiceMemo] 识别为空(占位保留，主 App 可再次转写)');
      _finishTranscribe();
      return;
    }

    // 3.4 热词纠错：TextProcessor 只依赖 assets/rules.txt(rootBundle) + 应用
    //     文档目录 user_hotwords.txt（路径解析），无 context/单例状态，overlay
    //     engine 可直接复用主 App 同款纠错（对齐 list_tab 的内部创建模式）；
    //     纠错失败降级存原始文本，不丢转写结果
    String corrected = text;
    try {
      final processor = TextProcessor();
      await processor.loadConfigs();
      corrected = processor.process(text);
    } catch (e) {
      print('⚠️ [OverlayVoiceMemo] 热词纠错失败(存原始文本): $e');
    }

    // 3.5 回填 content（占位 id 就在手，非空必达）
    try {
      await _dbHelper.updateDiary(_pendingDiaryId!, corrected);
      final preview = corrected.length > 50
          ? '${corrected.substring(0, 50)}...'
          : corrected;
      print('✅ [OverlayVoiceMemo] 转写已回填 id=$_pendingDiaryId 文本="$preview"');
      // 主 App 感知内容回填（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
    } catch (e) {
      print('❌ [OverlayVoiceMemo] 回填失败(占位保留，主 App 可再次转写): $e');
    }

    // ── 4. 收尾：回 idle（切面板/刷新列表由 overlay_home._onVoiceMemoChanged 处理） ──
    _finishTranscribe();
    print('✅ [OverlayVoiceMemo] 落盘入库转写完成，回到 idle');
  }

  /// 速记流程统一收尾：排定 worker idle 释放 + 清占位/计时状态 + 回 idle。
  ///
  /// 成功/失败/丢弃路径共用。失败时占位行保留（content='' 且音频可播——
  /// 用户在主 App 看到的是空卡片但有音频，可接受的中间态，主 App 可"再次
  /// 转写"回填）。_pendingDiaryId 清空表示本次速记流程已结束（占位行本身
  /// 不删，留在 diary 表里）。
  void _finishTranscribe() {
    // 回执原生清除浮窗常亮（voiceMemoStarted 时叠加的 FLAG_KEEP_SCREEN_ON）。
    // 本方法是全部收尾路径（空录音/WAV失败/入库失败/初始化失败/转写失败/
    // 识别为空/成功）的统一出口，一处全覆盖
    AccessibilityOverlay.voiceMemoFinished();
    _scheduleWorkerIdleRelease();
    _pendingDiaryId = null;
    _startTime = null;
    _state = OverlayVoiceMemoState.idle;
    notifyListeners();
  }

  /// 排定 worker idle 自动释放（转写收尾时调用）。
  ///
  /// 主 App 的 worker 会话期常驻；overlay 场景突发偶发，闲置 120s 释放第二
  /// 份模型内存（主 engine 的 worker 不受影响——两 isolate 各持独立实例）。
  /// 时限内再次录音时 start() 会取消本计时；释放后再次录音时 start() 的
  /// initialize 会重建 worker（RecognizerSingleton.dispose 已支持重建）。
  void _scheduleWorkerIdleRelease() {
    _workerIdleTimer?.cancel();
    _workerIdleTimer = Timer(
      const Duration(seconds: OverlayConstants.voiceMemoWorkerIdleSeconds),
      () {
        _workerIdleTimer = null;
        print(
          '🧹 [OverlayVoiceMemo] worker 闲置 ${OverlayConstants.voiceMemoWorkerIdleSeconds}s，释放识别引擎内存',
        );
        RecognizerSingleton.instance.dispose();
      },
    );
  }

  /// PCM16 字节 → Float32 归一化采样（Int16 little-endian / 32768）。
  /// 同构复用 diary_tab._convertBytesToFloat32 的实现（record 流 chunk 与
  /// BytesBuilder 拼接产物均为独立底层 buffer，asInt16List 视图转换安全）
  Float32List _pcmBytesToFloat32(Uint8List bytes) {
    final int16Data = bytes.buffer.asInt16List();
    final float32Data = Float32List(int16Data.length);
    for (int i = 0; i < int16Data.length; i++) {
      float32Data[i] = int16Data[i] / 32768.0;
    }
    return float32Data;
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _maxTimer?.cancel();
    _workerIdleTimer?.cancel(); // 取消挂起的 idle 释放（controller 都没了不再释放）
    _streamSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
