import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
// HardwareKeyboard / KeyEvent / KeyDownEvent / LogicalKeyboardKey
//（编辑态硬件返回键取消编辑）
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import '../ai_app_model.dart';
import '../db_helper.dart';
import '../theme/app_theme_extension.dart';
import '../utils/calendar_helper.dart';
import '../utils/diary_sync_bridge.dart';
import '../widgets/calendar_confirm_sheet.dart';
import 'accessibility_overlay.dart';
import 'overlay_constants.dart';
import 'overlay_data_client.dart';
import 'overlay_state_controller.dart';
import 'overlay_voice_memo.dart';
import 'widgets/overlay_diary_card.dart';
import 'widgets/overlay_voice_memo_bar.dart';

/// 悬浮窗主页
///
/// 根据 [OverlayStateController] 状态在「边缘小把手」和「展开面板」之间切换。
class OverlayHome extends StatefulWidget {
  const OverlayHome({super.key});

  @override
  State<OverlayHome> createState() => _OverlayHomeState();
}

/// 面板动画编排相位（窗口尺寸切换的时序真值）
///
/// idle：稳定态，渲染分支只看 controller.isCollapsed（现行为不变）；
/// expanding / collapsing：动画中，不变量 phase != idle ⇒ controller.isExpanded
///（窗口全屏）。收起方向的 controller.collapse()（=resize 触发链）延迟到动画
/// dismissed 边界才调——这是消除收起折返跑的全部秘密
enum _PanelAnimPhase { idle, expanding, collapsing }

/// 窗口 resize 空白守卫阶段
///
/// 根因：FlutterTextureView 在窗口尺寸变化、新尺寸帧尚未生成时，会把旧纹理
/// 重投影到新窗口（拉伸成巨型把手/锚定左上角）。awaitingResize 阶段 build
/// 渲染纯空白（SizedBox.expand），保证 resize 落地瞬间旧纹理不可见；
/// _maybeAdvanceMetricsStage 检测到窗口约束变化（新 metrics 已到）后解除守卫。
/// 写方：_expand / _onPanelAnimStatus（置 awaitingResize）+ _resetFromNative /
/// _onVoiceMemoChanged（清回 idle，兼作 await 续段的中断信号）
enum _MetricsStage { idle, awaitingResize }

class _OverlayHomeState extends State<OverlayHome>
    with TickerProviderStateMixin {
  final OverlayStateController _controller = OverlayStateController();
  final OverlayDataClient _dataClient = OverlayDataClient();

  List<Map<String, dynamic>> _diaries = [];
  bool _loading = true;
  bool _error = false; // 查询失败标记（显示"点击重试"错误态）
  // 上次已见的 diary 变更计数（跨 engine 脏检查，见 DiarySyncBridge）。
  // -1 = 尚未记录过（首次 _expand 必刷新，兜底所有历史遗漏）。
  // 写方：_syncDiariesIfChanged（查库前记录）；读方：_syncDiariesIfChanged
  int _lastSeenDiaryCounter = -1;
  bool _willExpand = false; // 把手水平拖拽标记
  bool _willCollapse = false; // 展开态左侧空白区水平拖拽标记

  // ── 卡片交互状态（复选框归档 + 展开全文）──
  // 展开态真值：diary id 驱动（父层管理，归档移位/列表刷新不错位；
  // 读写方：itemBuilder 传卡片 / _toggleExpand / _toggleExpandAll）
  final Set<int> _expandedIds = {};
  // 归档写库进行中的 id（_toggleArchive 入口检查，防连点错乱）
  final Set<int> _archivingIds = {};
  // 删除二次确认进行中的 id（卡片底行变「确认删除？✓✗」）
  final Set<int> _deleteConfirmIds = {};
  // 标注选择态进行中的 id（卡片底行变「❗ ⭐ 💡 ✗返回」；
  // 读写方：itemBuilder 传卡片 / _onCardTagEntry / _onCardTagPickCancel /
  // _setDiaryTag；清方：_enterEdit / _onCardDelete / _toggleExpand 收起分支 /
  // _finishCollapse / _resetFromNative——与 _deleteConfirmIds 同生命周期模式）
  final Set<int> _tagPickingIds = {};
  // 转写完成后默认展开第一条的待执行标记（写方：_onVoiceMemoChanged 转写完成
  // 分支置 true；读方/清方：_loadDiaries 成功后展开首条并清除；
  // _resetFromNative 防御性清除——浮窗被隐藏时转写完成的"展开首条"不该残留
  // 到用户下次手动打开）
  bool _expandFirstDiaryAfterLoad = false;
  // 删除写库进行中的 id（_onCardDelete 确认分支入口检查，防连点错乱）
  final Set<int> _deletingIds = {};

  // ── 展开卡正文编辑态（点击正文进入，光标定位到点击位置）──
  // 编辑卡 id 真值（null=无编辑）。写方：_enterEdit / _exitEdit；
  // 读方：itemBuilder 传参 / 手势降级判断 / onStartVoiceMemo 丢弃编辑 /
  // _resetFromNative 防御清理
  int? _editingDiaryId;
  // 编辑控制器：进入编辑时以 content + 点击偏移光标创建，退出编辑时 dispose 置 null
  TextEditingController? _editController;
  // 编辑焦点节点（懒创建复用）：requestFocus 弹软键盘 / unfocus 收键盘
  FocusNode? _editFocusNode;
  // 新增笔记占位行 id（_startNewNote 插入的 content='' 行）。
  // 空内容保存/取消时删行（对齐主 App 空白新笔记取消删占位行先例，
  // diary_tab.dart:2587-2592）；写方：_startNewNote；清方/读方：
  // _saveEdit / _cancelEdit（id 匹配时删行并从 _diaries 移除）
  int? _pendingNewNoteId;

  // 收起后延时彻底隐藏的计时器（到期 closeOverlay → 原生 hideOverlay → 发 reset 复位）
  Timer? _autoHideTimer;
  // 防 await reload 期间用户又展开的竞态：每次排定/取消计时都自增，
  // 异步回来后 generation 不一致说明期间发生了新的展开/收起/复位，本次排定作废
  int _hideScheduleGeneration = 0;

  // ── 面板推屏滑动动画（展开滑入/收起滑出，窗口 resize 编排到动画边界）──
  // value 语义 = 面板滑入进度：1=就位（稳定展开），0=整块滑出窗口右边界（稳定收起）。
  // 写方：_expand（forward）/ _collapse（reverse，缩窗延迟到 dismissed 边界）/
  // _resetFromNative、_onVoiceMemoChanged（stop 冻结）；读方：_buildPanel 动画层
  late final AnimationController _panelAnim;
  // 曲线：滑入 easeOutCubic（快进缓停）/ 滑出 easeInCubic（缓起加速推出）；
  // 中断反向续播时 CurvedAnimation 自动做 curve/reverseCurve 方向切换
  late final CurvedAnimation _panelAnimCurve;
  _PanelAnimPhase _panelAnimPhase = _PanelAnimPhase.idle;
  // 收起链路走完的一次性信号（_finishCollapse 发出缩窗 resize 时完成）。
  // 唯一等待方是 _onCardAlarm 权限缺失路径——系统授权框弹在主 App，窗口层级
  // 低于悬浮窗，必须等悬浮窗缩回把手（触摸区缩到把手）再拉起主 App，否则
  // 展开的面板会盖住授权框用户点不到。其余收起调用（复制/AI 跳转/写日历
  // 成功收起/拖拽收起）仍 fire-and-forget，不消费本信号
  Completer<void>? _collapseSettled;

  // 窗口 resize 空白守卫（见 _MetricsStage 注释）：awaitingResize 期间渲染纯透明
  _MetricsStage _metricsStage = _MetricsStage.idle;
  // 上一次 build 的窗口约束，用于检测原生 resize 已落地（约束变化=新 metrics 已到）
  // 写方：_maybeAdvanceMetricsStage（每次 build 顶层刷新）
  Size? _lastWindowConstraints;

  // ── 揭示门（语音速记冷启动隐藏窗口的揭示竞态防护）──
  // Kotlin hidden=true 窗口直建胶囊尺寸（312×64），把手尺寸的窗口在此路径
  // 中不存在——Dart 侧只需：
  //   ① handler 顶部挂门（挂门期间 build 渲染纯透明空白 SizedBox.shrink，
  //      把手/胶囊像素不进帧——即使揭示信号与翻 alpha 仍有竞态，用户看到的
  //      也是无害空窗）
  //   ② 摘门条件 = "录音/转写态的首帧"：本帧渲染的就是正确尺寸胶囊，构建完
  //      发揭示信号（postFrameCallback 锚定"正确尺寸帧已构建"）。
  //      ⚠️ addPostFrameCallback 只保证构建完不保证已呈现（光栅化 +
  //      SurfaceFlinger 合成晚 1~2 vsync），Kotlin 侧再延迟 2 vsync 翻 alpha
  // 被替代的"约束变化检测摘门"有"resize 先落地、门后挂"时序缺陷
  //（64b1c09 根治；演进详见 docs/architecture/悬浮窗录音闪烁.md）
  // 写方：onStartVoiceMemo（hiddenReveal=true 时 handler 顶部挂门）/ build 的
  // 挂门短路（录音态首帧摘门）/ _onVoiceMemoChanged 转写分支（防御性摘门）/
  // _resetFromNative（窗口移除后清门，防残留影响下个会话）；
  // 读方：build 的挂门空白短路
  bool _revealGatePending = false;

  // 真展开路径（有空白帧等待的）抑制叠加把手渲染：空白期把手已消失，
  // 恢复渲染若再满显重现会形成"消失→重现→渐隐"三段闪烁；把手的位置
  // 连续性职责已由空白+面板屏外滑入接管。中断收起路径（无空白期、把手
  // 连续渐显）不抑制。
  // 写方：_expand 主路径/稳定展开分支置 true，collapsing 中断分支置 false，
  // _resetFromNative / _onVoiceMemoChanged 冻结时防御性置 false；
  // 读方：_buildPanel 叠加把手条件
  bool _handleOverlaySuppressed = false;

  // ── 缩窗后把手回位动效（延迟+滑入渐显，见 postResizeFadeDuration 注释）──
  // 写方：_maybeAdvanceMetricsStage（缩窗方向 forward(from:0)，扩窗方向置 1）+
  // _resetFromNative / _onVoiceMemoChanged（清守卫时防御性置 1，防中途值残留）；
  // 读方：build 的 AnimatedBuilder（FractionalTranslation+Opacity）（稳定态恒为 1，无视觉影响）
  late final AnimationController _postResizeFade;
  late final CurvedAnimation _postResizeFadeCurve;

  // ── 语音速记（长按音量上键 action=record 直连录音）──
  // 状态机控制器 + 上一帧状态快照（识别"进入/离开 录音·转写态"做一次性窗口 resize，
  // 100ms tick 的 notifyListeners 不重复 resize）
  final OverlayVoiceMemoController _voiceMemo = OverlayVoiceMemoController();
  OverlayVoiceMemoState _lastVoiceMemoState = OverlayVoiceMemoState.idle;

  // ── 语音笔记回放（单实例播放器 + 当前播放卡真值，照主 App diary_tab 模式简化）──
  // 与 _expandedIds 同风格收在 State：无进度条无 seek，唯一订阅 onPlayerComplete
  //（低频）。故意不订阅 onPlayerStateChanged / onPositionChanged：audioplayers
  // 在 Android 上 state/position 流有抖动回退（见主 App diary_tab 注释），
  // 悬浮窗只有 play/pause 图标切换，用不上位置流
  final AudioPlayer _audioPlayer = AudioPlayer();
  // 当前占用播放器的卡片 id（null=空闲）。读方：itemBuilder 传卡片的
  // isPlayingAudio；写方：_toggleAudioPlay / _stopAudioPlayback / 播完回调
  int? _playingDiaryId;
  // 自管 bool：区分"同卡暂停"（resume 不重头）与"同卡播放中"（pause）两个分支
  bool _isPlaying = false;
  // 播完归零订阅（initState 注册、dispose 取消）
  StreamSubscription<void>? _playerCompleteSub;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStateChanged);
    _voiceMemo.addListener(_onVoiceMemoChanged);
    // 面板滑动动画控制器：初始 value 默认 0（dismissed）= 冷启动即收起态，
    // 无需显式设置；时长唯一真值在 OverlayConstants.panelSlideDuration
    _panelAnim = AnimationController(
      vsync: this,
      duration: OverlayConstants.panelSlideDuration,
    );
    _panelAnimCurve = CurvedAnimation(
      parent: _panelAnim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 初始 value=1（满显）：冷启动首帧不能透明。fade 只在缩窗方向恢复渲染时
    // 由 _maybeAdvanceMetricsStage 重新 forward(from:0)
    _postResizeFade = AnimationController(
      vsync: this,
      duration: OverlayConstants.postResizeFadeDuration,
      value: 1,
    );
    _postResizeFadeCurve = CurvedAnimation(
      parent: _postResizeFade,
      // 前 62.5%（300ms）保持 0：窗口 frame 移动期间完全透明；后 37.5%（180ms）
      // easeOutCubic 滑入渐显（配比换算见 postResizeFadeDuration 注释）
      curve: const Interval(0.625, 1.0, curve: Curves.easeOutCubic),
    );
    _panelAnim.addStatusListener(_onPanelAnimStatus);
    // 注册原生→Dart 消息：长按音量上键自动展开（expand）/ 彻底隐藏后复位（reset）/
    // 语音速记录音启停（startVoiceMemo / stopVoiceMemo，action=record 长按直连）
    AccessibilityOverlay.setupNativeChannel(
      onExpand: () {
        if (!mounted) return;
        // 立即 resize 会把旧纹理重投影到新窗口（巨型把手闪现），扩窗时机统一
        // 由 _expand 的空白帧协议管理；"展开态残留"由 hideOverlay 的 reset 复位
        // + _expand 稳定展开分支兜底
        _expand();
      },
      onReset: _resetFromNative,
      // Kotlin triggerVoiceMemoOverlay → 请求开始录音；成功/失败分别回执
      // voiceMemoStarted / voiceMemoFailed（Kotlin toggle 状态机的复位依据）。
      // hiddenReveal：Kotlin 负载，true = 当前是隐藏窗口（alpha=0 等揭示）
      onStartVoiceMemo: (hiddenReveal) async {
        if (!mounted) return;
        if (hiddenReveal) {
          // 隐藏窗口模式：handler 顶部立即挂门——门挂上之前的 await 链
          //（权限/prefs/开流，20~80ms）期间 state 仍是 idle，晚挂门会让
          // 把手帧在挂门前进入渲染管线
          _revealGatePending = true;
        }
        // 编辑中触发语音速记：先丢弃编辑（不写库，等同取消；含窗口 flag 回
        // default 恢复 NOT_FOCUSABLE）再继续原录音流程。必须在 _stopAudioPlayback
        // 之前——与停播同属"开录音前的现场清理"
        if (_editingDiaryId != null) {
          _cancelEdit();
        }
        // 开录音前停止回放：扬声器声音会回采进麦克风污染识别（同主 App TTS
        // 回采三层防御的动机）。录音唯一入口在此 handler（controller.start
        // 仅此处调用），_onVoiceMemoChanged 不需要重复设防；必须在 start()
        // 之前停——start 内部有多个 await，期间麦克风已可能开流，事后停就晚了
        _stopAudioPlayback();
        final ok = await _voiceMemo.start();
        if (!mounted) return;
        if (ok) {
          await AccessibilityOverlay.voiceMemoStarted();
          if (!hiddenReveal) {
            // 把手在屏上的原地切换路径（含旧版本 Kotlin 发 null 的兼容）：
            // 维持立即发——此路径 Kotlin 侧非 pendingVoiceMemoReveal，收到是
            // no-op。隐藏窗口路径（hiddenReveal=true）的揭示信号不在此发——
            // 由 build 的挂门短路在"录音态首帧"构建完后发（摘门即揭示，
            // 见 _revealGatePending 注释）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              AccessibilityOverlay.voiceMemoUiReady();
            });
          }
        } else {
          // 失败原因已由 controller print；Kotlin 收到回执后隐藏浮窗
          await AccessibilityOverlay.voiceMemoFailed('start 失败（权限/互斥/录音器）');
        }
      },
      // Kotlin toggle 停止 → 进入转写（voiceMemoStopped 回执由 controller.stop 自己发）
      onStopVoiceMemo: () {
        if (!mounted) return;
        _voiceMemo.stop();
      },
      // Kotlin overlay_new_note 手势动作 → 展开面板并新增一条笔记
      onNewNote: _onNewNote,
    );
    // 握手：告知原生 Dart handler 已注册；若原生挂起 pendingAutoExpand 会立即补发 expand
    AccessibilityOverlay.notifyDartReady();
    // 播完归零（唯一订阅，低频）：图标复位、_playingDiaryId 释放（stop/pause
    // 不触发本回调，由各调用点自己维护真值——同主 App diary_tab 行为）
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      print('🔊 [OverlayHome] 录音播放完成，状态归零');
      setState(() {
        _playingDiaryId = null;
        _isPlaying = false;
      });
    });
    _loadDiaries();
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _hideScheduleGeneration++;
    // 动画资源释放：stop 停 ticker（防泄漏）→ curve 先于 parent dispose
    //（curve 依赖 parent 存活，dispose 只是移除自身监听，此处顺序安全）
    _panelAnim.stop();
    _panelAnimCurve.dispose();
    // 缩窗恢复 fade 控制器：同样 curve 先于 parent dispose（同上模式）
    _postResizeFadeCurve.dispose();
    _postResizeFade.dispose();
    _panelAnim.dispose();
    _controller.removeListener(_onStateChanged);
    _controller.dispose();
    _voiceMemo.removeListener(_onVoiceMemoChanged);
    _voiceMemo.dispose();
    // 播放器清理：先 cancel 播完订阅再 dispose player（防 player 已释放后
    // 回调 use-after-free，同主 App diary_tab 的清理顺序）
    _playerCompleteSub?.cancel();
    _audioPlayer.dispose();
    // 编辑态资源清理：返回键 handler + controller + focusNode
    //（防御性——正常退出编辑已在 _exitEdit 清理，此处兜 dispose 时仍编辑中的边角）
    HardwareKeyboard.instance.removeHandler(_editKeyHandler);
    _editController?.dispose();
    _editFocusNode?.dispose();
    super.dispose();
  }

  /// 状态变化时同步调整悬浮窗尺寸
  void _onStateChanged() {
    final size = _controller.panelSize;
    print(
      '📐 [OverlayHome] 状态变化: ${_controller.state.name}, '
      'size=${size.width.toInt()}x${size.height.toInt()}',
    );
    AccessibilityOverlay.resizeOverlay(size.width.toInt(), size.height.toInt());
    if (mounted) {
      setState(() {});
    }
  }

  /// 语音速记状态变化：一次性窗口 resize + 转写完成切面板 + tick 刷新 UI
  void _onVoiceMemoChanged() {
    if (!mounted) return;
    final prev = _lastVoiceMemoState;
    final cur = _voiceMemo.state;
    _lastVoiceMemoState = cur;
    if (cur != prev) {
      // ignore: avoid_print
      print('🎙️ [OverlayHome] 语音速记状态: ${prev.name} → ${cur.name}');
      if (cur == OverlayVoiceMemoState.recording ||
          cur == OverlayVoiceMemoState.transcribing) {
        // 防御：录音态结束（秒停进转写）而揭示门还挂着（极端时序：build 的
        // 摘门分支尚未跑），立即发信号揭示，防窗口永远隐形（watchdog T3 66s
        // 才兜底太久）。进入录音态不摘——揭示门正是在录音开始时挂上的
        if (cur == OverlayVoiceMemoState.transcribing && _revealGatePending) {
          _revealGatePending = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            AccessibilityOverlay.voiceMemoUiReady();
          });
        }
        // 进入录音/转写：取消可能残留的自动隐藏计时（如把手倒计时中长按开录，
        // 否则计时到期会把录音中的浮窗关掉）+ 窗口 resize 成胶囊尺寸
        //（非哨兵值高度 → 原生 Gravity.CENTER_VERTICAL|END，贴右缘垂直居中）。
        // 冷启动隐藏路径窗口从创建起就是 312×64，此 resize 是同尺寸 updateViewLayout
        // 幂等无害；把手在屏上开录的暖路径仍靠它完成把手→胶囊的尺寸切换
        _hideScheduleGeneration++;
        _autoHideTimer?.cancel();
        _autoHideTimer = null;
        // 冻结面板动画：若正处收起滑出中，dismissed 回调会把语音胶囊窗口
        // resize 回把手尺寸——stop + 归 idle 吞掉后续边界回调（不置 value，
        // 转写完成的 _expand 稳定展开分支会重置位姿重播滑入）
        _panelAnim.stop();
        _panelAnimPhase = _PanelAnimPhase.idle;
        // 清空白守卫：语音胶囊需立即渲染（并作废 _expand/_finishCollapse 的
        // await 续段——stage 变化即中断信号）
        _metricsStage = _MetricsStage.idle;
        // 抑制标志复位：语音胶囊不走叠加把手，防残留抑制态影响后续中断收起路径
        _handleOverlaySuppressed = false;
        // fade 防御性置满显：语音胶囊分支在 FadeTransition 外，但防收起渐显中途
        // 进入录音时 fade 停在中途、转写完成后切面板首帧半透明
        _postResizeFade
          ..stop()
          ..value = 1;
        AccessibilityOverlay.resizeOverlay(
          OverlayConstants.voiceMemoWindowWidth,
          OverlayConstants.voiceMemoWindowHeight,
        );
      } else if (prev == OverlayVoiceMemoState.transcribing) {
        // 转写完成 → 切展开面板（_expand 内部触发 resize 哨兵值 + 重新查库，
        // 新卡在顶部）；后续收起时 _scheduleAutoHide 恢复按 overlay_auto_hide_seconds 计时
        // 置"展开首条"待执行标记：getDiaries 排序 is_archived ASC + created_at DESC，
        // 新转写条目必为首条，_loadDiaries 成功后展开它（读方在 _loadDiaries）
        _expandFirstDiaryAfterLoad = true;
        _expand();
      }
    }
    setState(() {}); // 100ms tick 也走这里 → 胶囊变长/计时刷新
  }

  /// 直连 sqflite 查询全部日记（overlay engine 内直接访问数据库）
  ///
  /// [showLoading] 为 false 时跳过开头的 _loading 置位——归档/恢复后的静默
  /// 刷新不闪 loading 圈，列表原地换数据
  Future<void> _loadDiaries({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
      });
    }
    try {
      final data = await _dataClient.getDiaries();
      if (mounted) {
        setState(() {
          _diaries = data;
          _loading = false;
          _error = false;
          // 消费"转写完成默认展开首条"标记：仅转写完成路径置位（_onVoiceMemoChanged），
          // 归档刷新/删除刷新也走本方法但标志为 false，互不影响
          if (_expandFirstDiaryAfterLoad) {
            _expandFirstDiaryAfterLoad = false;
            if (data.isNotEmpty) {
              _expandedIds.add(data.first['id'] as int);
            }
          }
        });
      }
    } catch (e) {
      print('❌ [OverlayHome] 加载日记失败: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  /// 跨 engine 脏检查：主 App 侧写库后本 engine 不知情（双 isolate 无推送），
  /// 展开时 reload prefs 比对 DiarySyncBridge 计数，变了才重查库。
  /// -1 初始值保证首次必刷新（等价旧的无条件 _loadDiaries 行为）。
  /// 计数在查库前记录：查库期间另一 engine 再 bump 的话，本批数据未含该
  /// 变更，记录旧值下次仍会触发刷新（记新值会误标已见、丢变更）
  Future<void> _syncDiariesIfChanged() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 主 engine 写入，必须 reload（项目惯例）
      final counter = DiarySyncBridge.current(prefs);
      if (counter == _lastSeenDiaryCounter) return; // 无变更
      _lastSeenDiaryCounter = counter;
      await _loadDiaries(showLoading: false);
    } catch (e) {
      print('⚠️ [OverlayHome] 跨 engine 变更检查失败: $e');
      // 检查失败退回无条件刷新（与旧行为一致，宁多查不漏数据）
      await _loadDiaries(showLoading: false);
    }
  }

  /// 切换单卡展开/收起（卡片 onTap；展开态真值在 _expandedIds 按 diary id 管理）
  void _toggleExpand(int id) {
    setState(() {
      if (_expandedIds.contains(id)) {
        _expandedIds.remove(id);
        // 收起卡片顺带退出标注选择态（防状态残留到下次展开）
        _tagPickingIds.remove(id);
      } else {
        _expandedIds.add(id);
      }
    });
  }

  /// 复选框 toggle：勾上=归档、取消勾=恢复（乐观 UI + 落库 + 延时静默刷新移位）。
  /// 由卡片 onCheckChanged 调用，参数 toArchived = 目标归档态
  Future<void> _toggleArchive(
    Map<String, dynamic> diary,
    bool toArchived,
  ) async {
    final id = diary['id'] as int;
    // 写库进行中忽略重复点击（防连点错乱）
    if (_archivingIds.contains(id)) return;
    _archivingIds.add(id);
    // 整个交互流程包进 try/finally：任何一步抛异常都解除防抖，
    // 否则 id 永久卡在 _archivingIds 里，之后点击被静默拦截
    try {
      // 乐观 UI：按 id 替换为带新标记的拷贝（卡片原地变灰划线/恢复彩色，不移动）。
      // ⚠️ sqflite 查询返回的行是 QueryRow（只读 Map），原地赋值会抛
      // "Unsupported operation: read-only"——必须拷贝出新 Map 替换列表条目
      final idx = _diaries.indexWhere((d) => d['id'] == id);
      if (idx >= 0) {
        setState(() {
          _diaries[idx] = {..._diaries[idx], 'is_archived': toArchived ? 1 : 0};
          // 归档/恢复对称规则：勾选框 toggle 永远强制收起——归档语义是"收起来"，
          // 展开的全文移位后仍占视觉空间；恢复同理对称（防"取消归档时展开/
          // 收起取决于之前状态"的心智模型混乱）
          _expandedIds.remove(id);
        });
      }
      // 轻震动确认（20ms/amplitude 50，对齐主 App 归档反馈）
      _vibrate();
      // 仅置标记不删音频（overlay 侧归档可恢复），见 OverlayDataClient 注释
      if (toArchived) {
        await _dataClient.archiveDiary(id);
      } else {
        await _dataClient.restoreDiary(id);
      }
      // 主 App 感知本次写入（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      // 停留片刻给划线反馈留被看见的时间，再静默刷新
      //（卡片移位到归档区/按 created_at 排回）
      await Future.delayed(OverlayConstants.archiveRefreshDelay);
      await _loadDiaries(showLoading: false);
    } catch (e) {
      print('❌ [OverlayHome] 归档/恢复失败: $e');
      // 回库恢复真相（乐观 UI 可能已偏离真实状态）
      await _loadDiaries(showLoading: false);
    } finally {
      _archivingIds.remove(id);
    }
  }

  /// 播放按钮 toggle（卡片 onPlayToggle 上游）。
  /// 三分支（同主 App diary_tab._togglePlay 骨架，砍掉进度三件套——悬浮窗
  /// 只有 play/pause 图标，无进度条无 seek）：
  /// 同卡播放中 → pause（再点 resume 不重头）/ 同卡已暂停 → resume /
  /// 否则（切卡/首次）→ stop 停旧 + play 新（单实例播放器，天然"播 B 停 A"，
  /// 旧卡从头计）。注意 stop() 不触发 onPlayerComplete（audioplayers 只在
  /// 自然播完时发），切卡分支必须自己 setState 换真值
  Future<void> _toggleAudioPlay(Map<String, dynamic> diary) async {
    final id = diary['id'] as int;
    final path = diary['audio_path'] as String?;
    if (path == null || path.isEmpty) return;
    try {
      if (_playingDiaryId == id && _isPlaying) {
        // 同卡播放中 → 暂停（位置冻结在播放器内，resume 从断点继续）
        await _audioPlayer.pause();
        if (mounted) setState(() => _isPlaying = false);
      } else if (_playingDiaryId == id && !_isPlaying) {
        // 同卡已暂停 → 继续（不重头）
        await _audioPlayer.resume();
        if (mounted) setState(() => _isPlaying = true);
      } else {
        // 切卡/首次：停旧（旧卡位置归零）+ 播新。
        // audio_path 是绝对路径（语音速记/主 App 落盘时入库），DeviceFileSource 直用
        await _audioPlayer.stop();
        await _audioPlayer.play(DeviceFileSource(path));
        if (mounted) {
          setState(() {
            _playingDiaryId = id;
            _isPlaying = true;
          });
        }
        print('🔊 [OverlayHome] 播放录音 id=$id');
      }
    } catch (e) {
      // 文件缺失/播放器异常：归零 + 打日志（悬浮窗无 SnackBar 上下文，静默容错）
      print('❌ [OverlayHome] 播放失败 id=$id: $e');
      if (mounted) {
        setState(() {
          _playingDiaryId = null;
          _isPlaying = false;
        });
      }
    }
  }

  /// 卡片删除按钮（底条）：两次点击流转——第一次进入确认态（底行变
  /// 「确认删除？✓✗」），确认态点 ✓ 才真删（库行 + 录音文件）。
  /// 播放中的卡被删前先停播归零。两次点击均 tick 震动（对齐复制按钮反馈）
  Future<void> _onCardDelete(Map<String, dynamic> diary) async {
    final id = diary['id'] as int;
    if (!_deleteConfirmIds.contains(id)) {
      // 进入删除确认态顺带退出标注选择态（结构上两态互斥——底行整行替换，
      // 标注态下删除按钮不可见；此处为防御性清理）
      _tagPickingIds.remove(id);
      setState(() => _deleteConfirmIds.add(id));
      AccessibilityOverlay.vibrateTick();
      return;
    }
    // 确认删除分支：写库进行中忽略重复点击（防连点错乱）
    if (_deletingIds.contains(id)) return;
    _deletingIds.add(id);
    // 整个交互流程包进 try/finally：任何一步抛异常都解除防抖，
    // 否则 id 永久卡在 _deletingIds 里，之后点击被静默拦截（同 _toggleArchive）
    try {
      // 播放中的卡被删前先停播（录音文件即将删除）
      if (_playingDiaryId == id) {
        await _stopAudioPlayback();
      }
      // 确认删除的 tick 震动（对齐复制按钮反馈；归档分支仍用 _vibrate 轻震）
      AccessibilityOverlay.vibrateTick();
      await _dataClient.deleteDiary(id, diary['audio_path'] as String?);
      // 主 App 感知本次删除（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      _deleteConfirmIds.remove(id);
      _expandedIds.remove(id);
      await _loadDiaries(showLoading: false);
    } catch (e) {
      print('❌ [OverlayHome] 删除日记失败: $e');
      // 回库恢复真相
      await _loadDiaries(showLoading: false);
    } finally {
      _deletingIds.remove(id);
    }
  }

  /// 删除确认态取消（✗）：退出确认态，底行还原
  void _onCardDeleteCancel(int id) {
    setState(() => _deleteConfirmIds.remove(id));
  }

  /// 标注入口按钮（底条 Icons.label_outline）：进入标注选择态，
  /// 底行整行替换为「❗ ⭐ 💡 ✗返回」
  void _onCardTagEntry(int id) {
    setState(() => _tagPickingIds.add(id));
  }

  /// 标注选择态 ✗ 返回：退出选择态，底行还原为查看态按钮条
  void _onCardTagPickCancel(int id) {
    setState(() => _tagPickingIds.remove(id));
  }

  /// 标注写入（标注行 tag 按钮点击）：tag='urgent'/'star'/'idea' 或
  /// null（点已选中的 tag = 取消标注）。写库成功后按 id 局部更新内存列表
  /// + 退出标注选择态（照 _toggleArchive 的局部更新模式，不整表 reload）。
  /// ⚠️ sqflite 查询返回的行是只读 QueryRow，必须拷贝新 Map 整体替换
  Future<void> _setDiaryTag(int id, String? tag) async {
    try {
      await DbHelper().updateDiaryTag(id, tag);
      // 主 App 感知本次标注写入（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      if (!mounted) return;
      final idx = _diaries.indexWhere((d) => d['id'] == id);
      setState(() {
        if (idx >= 0) {
          _diaries[idx] = {..._diaries[idx], 'tag': tag};
        }
        // 标注完成即退出选择态（底行还原，卡片原地换色）
        _tagPickingIds.remove(id);
      });
      // 轻震动确认（20ms/amplitude 50，对齐归档反馈）
      _vibrate();
      print('🏷️ [OverlayHome] 日记标注已更新 id=$id tag=$tag');
    } catch (e) {
      print('❌ [OverlayHome] 标注写入失败 id=$id: $e');
      // 失败回库恢复真相
      await _loadDiaries(showLoading: false);
    }
  }

  /// 卡片复制按钮：原生写剪贴板 + tick 震动（原生侧完成，对齐日记页反馈），
  /// 成功后自动收起面板回把手（用户复制完即走，与分享后收起同语义）。
  /// 入口日志区分"tap 未触发"与"通道/写入失败"两类问题
  Future<void> _onCardCopy(String content) async {
    print('📋 [OverlayHome] 复制按钮点击 (len=${content.length})');
    try {
      final ok = await AccessibilityOverlay.copyText(content);
      if (!mounted) return;
      if (ok) {
        print('✅ [OverlayHome] 已复制到剪贴板，收起面板');
        // 复制完成即收起回把手（与分享后收起同路径；_collapse 幂等守卫兜底）
        _collapse();
      } else {
        print('❌ [OverlayHome] 原生写剪贴板返回失败');
      }
    } catch (e) {
      print('❌ [OverlayHome] 复制失败: $e');
    }
  }

  /// 卡片 AI 对话按钮（对齐主 App 日记页卡片同款按钮，_shareToAI）：
  /// 1. reload prefs 读设置页写入的 `selected_ai_app`（跨 engine 缓存隔离）
  /// 2. 原生写剪贴板（复用复制按钮通道，tick 震动反馈在原生侧完成）
  /// 3. 原生拉起 AI 应用（Service 无 Activity，NEW_TASK 在 Kotlin 侧加，
  ///    见 AccessibilityOverlay.launchApp）
  /// 剪贴板写入失败即中止跳转——留在原地让用户改走复制按钮，避免跳过去
  /// 粘出剪贴板里的旧内容；拉起成功后收起面板回把手（用户已跳去 AI 应用，
  /// 与原分享后收起同语义；_collapse 幂等守卫兜底）
  Future<void> _onCardShareToAI(String content) async {
    try {
      // 跨 engine 读主 App 设置页写入的选择（各 engine prefs 内存缓存隔离，
      // 必须 reload，项目惯例见 overlay_voice_memo/_maybeRefreshDiaries）
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final appId = prefs.getString('selected_ai_app') ?? 'chatgpt';
      final app = AIApp.findById(appId) ?? AIApp.defaultApp;
      // 1. 原生复制到剪贴板（原生侧完成震动反馈，与复制按钮同路径）
      final copied = await AccessibilityOverlay.copyText(content);
      if (!mounted) return;
      if (!copied) {
        print('❌ [OverlayHome] AI 对话中止：剪贴板写入失败 (len=${content.length})，不跳转');
        return;
      }
      // 2. 原生拉起 AI 应用（微信偏好 scheme，传空包名跳过包名步骤，
      //    对齐日记页 _shareToAI 的微信特殊处理）
      final launched = await AccessibilityOverlay.launchApp(
        name: app.name,
        packageName: app.id == 'wechat' ? '' : app.packageName,
        scheme: app.scheme,
        url: app.url,
      );
      if (!mounted) return;
      // ignore: avoid_print
      print(
        launched
            ? '📤 [OverlayHome] 已复制并跳转 ${app.name}，收起面板 (len=${content.length})'
            : '❌ [OverlayHome] AI 应用拉起失败（原生已 Toast 提示）: ${app.name}',
      );
      // 收起回把手（与复制/分享后收起同路径；_collapse 幂等守卫兜底）。
      // 拉起失败面板保持展开，用户可改走复制按钮
      if (launched) _collapse();
    } catch (e) {
      print('❌ [OverlayHome] AI 对话失败: $e');
    }
  }

  /// 卡片闹钟按钮：识别卡片文字里的时间 → 转轮预填确认 sheet → 写系统日历。
  ///
  /// 识别结果只决定转轮初始位置，绝不直接定死（用户预填可改的设计原则）；
  /// 识别不到（或空文案卡）预填 CalendarHelper.defaultPrefillTime。
  /// 权限策略（与日记页共用本弹层，差异均因悬浮窗无 Activity）：
  /// - 日历权限缺失 → 先收起面板回把手（系统授权框弹在主 App、窗口层级低于
  ///   悬浮窗，展开的面板会盖住授权框用户点不到）+ 原生 Toast + 拉起主 App
  ///   自动弹系统授权框，中止本流程（sheet 里选完时间再失败太挫败，故前置拦截）
  /// - 通知权限缺失 → 不拦截，响铃开关禁用置关降级「仅日历事件」
  /// 写日历与响铃由原生 CalendarEventHelper 完成（成功/失败 Toast 也在原生侧）
  Future<void> _onCardAlarm(Map<String, dynamic> diary) async {
    final content = (diary['content'] as String?) ?? '';
    print('⏰ [OverlayHome] 闹钟按钮点击 (len=${content.length})');
    try {
      // 1. 权限预检（原生 checkSelfPermission，通道异常返回 null 按最严处理）
      final perms = await AccessibilityOverlay.checkAlarmPermissions();
      if (!mounted) return;
      if (perms == null || !perms.calendar) {
        print('⏰ [OverlayHome] 日历权限缺失，收起面板后拉起主 App 授权');
        // 系统授权框弹在主 App，窗口层级低于悬浮窗——面板不收起会盖住授权框
        // 用户点不到。先收起回把手并等缩窗链路走完（_collapseSettled 在缩窗
        // resize 发出时完成，触摸区已缩回把手）再拉起；超时兜底放行，同
        // _waitForBlankFramePresented 的保守哲学：帧管线极端卡顿优先保功能。
        // 上限 ≈ 动画 240ms + 空白帧等待上限 300ms + resize 往返余量
        _collapse();
        final collapseDone = _collapseSettled?.future;
        if (collapseDone != null) {
          await collapseDone.timeout(
            const Duration(milliseconds: 1200),
            onTimeout: () {},
          );
        }
        if (!mounted) return;
        await AccessibilityOverlay.requestCalendarPermission();
        return;
      }
      // 2. 识别时间（纯 Dart 正则，毫秒级；悬浮窗 engine 内直接可用）
      final parsed = await CalendarHelper.extractBestTime(content);
      if (!mounted) return;
      final initial = parsed?.time ?? CalendarHelper.defaultPrefillTime();
      final title = CalendarHelper.buildEventTitle(content, parsed?.entity);
      // 3. 转轮确认 sheet（预填可改；未授通知权限时响铃开关禁用置关）
      final result = await showCalendarConfirmSheet(
        context,
        eventTitle: title,
        initialTime: initial,
        recognizedPhrase: parsed?.entity.text,
        alarmAvailable: perms.notification,
      );
      if (!mounted || result == null) return;
      // 4. 写系统日历 + 按需响铃（原生 Toast 反馈）
      final ok = await AccessibilityOverlay.addCalendarEvent(
        time: result.time,
        title: title,
        enableAlarm: result.enableAlarm,
      );
      if (!mounted) return;
      if (ok) {
        print('⏰ [OverlayHome] 日历事件已写入 @ ${result.time}，标题「$title」');
        // 成功 tick 震动（对齐复制按钮反馈；失败反馈在原生 Toast）
        AccessibilityOverlay.vibrateTick();
        // 添加完成即收起面板回把手（与复制/AI 跳转后收起同语义；
        // _collapse 幂等守卫兜底）
        _collapse();
      } else {
        print('❌ [OverlayHome] 写日历失败（原生已 Toast 提示）');
      }
    } catch (e) {
      print('❌ [OverlayHome] 闹钟流程失败: $e');
    }
  }

  /// 进入正文编辑态（展开卡正文点击，charOffset = 点击位置换算的字符偏移）。
  /// 流程：清删除确认态（编辑与删除确认互斥）→ 置编辑真值 + 建 controller
  ///（光标夹取到 [0, length]）→ 窗口切 focuspointer（去 NOT_FOCUSABLE，
  /// 不可聚焦窗口系统不给弹软键盘；await 的回执语义 = 原生已等窗口拿到
  /// window focus——updateViewLayout 异步生效，提前回执会让 requestFocus →
  /// showSoftInput 被 IMM 静默拒绝，有光标无键盘）→ setState → 帧后
  /// requestFocus 弹键盘。
  /// [allowEmpty]：新增笔记占位行（content=''）放行编辑——原空内容守卫是
  /// 防转写占位行被编辑，只有 _startNewNote 路径传 true
  Future<void> _enterEdit(
    Map<String, dynamic> diary,
    int charOffset, {
    bool allowEmpty = false,
  }) async {
    final id = diary['id'] as int;
    final content = (diary['content'] as String?) ?? '';
    // 点击落在勾选框占位区（卡片 -1 哨兵）：点勾选框走归档回调，不进编辑
    if (charOffset < 0) return;
    // 占位行（content 为空）不可编辑（构建处不传 onTextTap，此处双保险）；
    // 新增笔记路径（allowEmpty=true）例外放行
    if (content.isEmpty && !allowEmpty) return;
    // 已在编辑本卡时不重建（编辑态正文是 TextField，点击挪光标是原生行为，
    // 走不到这里；此分支仅为防御）
    if (_editingDiaryId == id) return;
    // 从其他卡的编辑态切换过来：旧编辑直接丢弃（不写库）
    if (_editingDiaryId != null) {
      print('✏️ [OverlayHome] 切换编辑卡，丢弃旧编辑 id=$_editingDiaryId');
    }
    // 编辑态与删除确认态互斥：进入编辑前清掉所有卡的删除确认态
    _deleteConfirmIds.clear();
    // 编辑态与标注选择态同样互斥（编辑中底条是「✗取消 / ✓保存」）
    _tagPickingIds.clear();
    // 光标偏移夹取到合法范围（TextPainter 换算失败时卡片已兜底落文末，再夹一道）
    final offset = charOffset.clamp(0, content.length);
    _editController?.dispose();
    // TextEditingController 无 selection 构造参数，构造后单独赋值光标位置
    _editController = TextEditingController(text: content)
      ..selection = TextSelection.collapsed(offset: offset);
    _editFocusNode ??= FocusNode();
    _editingDiaryId = id;
    // 注册硬件返回键 = 取消编辑（overlay engine 独立 isolate，返回键事件先到
    // 本 engine；HardwareKeyboard.addHandler 内部是 Set，重复注册幂等）
    HardwareKeyboard.instance.addHandler(_editKeyHandler);
    // 窗口当前带 FLAG_NOT_FOCUSABLE，不可聚焦窗口系统不给弹软键盘——切
    // focuspointer（原生侧同时设 SOFT_INPUT_ADJUST_RESIZE 防键盘盖住卡片）。
    // ⚠️ await 等的不只是 flag 落地：原生回执延迟到窗口真正拿到 window
    // focus（updateViewLayout 异步生效，WMS 重算焦点窗口要 1~2 帧）——提前
    // 回执时 postFrameCallback 的 requestFocus → showSoftInput 打在
    // windowFocus=false 的窗口上被 IMM 静默拒绝，症状=有光标无键盘。
    // 失败不阻塞编辑流程（最多键盘弹不出，用户可再点一次正文重试）
    try {
      await AccessibilityOverlay.updateFlag('focuspointer');
    } catch (e) {
      print('⚠️ [OverlayHome] 切 focuspointer flag 失败 id=$id: $e');
    }
    // await 期间编辑可能已被取消/浮窗已复位：直接放弃后续建帧要焦点
    if (!mounted || _editingDiaryId != id) return;
    print('✏️ [OverlayHome] 进入编辑 id=$id 光标偏移=$offset/${content.length}');
    setState(() {});
    // 等编辑态 TextField 挂载后再要焦点（弹软键盘）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingDiaryId != id) return;
      _editFocusNode?.requestFocus();
    });
  }

  /// 编辑态硬件返回键 handler：编辑中收到返回键 → 取消编辑（等同 ✗）并吞掉
  /// 事件（不冒泡给系统后退）；非编辑态不拦截
  bool _editKeyHandler(KeyEvent event) {
    if (_editingDiaryId == null) return false;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _cancelEdit();
      return true;
    }
    return false;
  }

  /// 保存编辑（✓）：trim 后为空视同取消；否则写库 + 原地更新列表 + 退出编辑
  /// + tick 震动。新增笔记占位行（id == _pendingNewNoteId）特判：trim 为空
  /// → 删占位行（视同取消）；保存成功 → 清占位标记
  Future<void> _saveEdit() async {
    final id = _editingDiaryId;
    final controller = _editController;
    if (id == null || controller == null) return;
    final newContent = controller.text.trim();
    if (newContent.isEmpty) {
      if (id == _pendingNewNoteId) {
        // 新增笔记占位行 trim 后为空 → 视同取消：删占位行（对齐主 App 空白
        // 新笔记取消删行先例）。deleteDiary fire-and-forget：占位行无录音
        // 文件，删库失败也只留一条空行，主 App 侧可编辑/删除，无害
        print('✏️ [OverlayHome] 新增笔记保存为空，删占位行 id=$id');
        _pendingNewNoteId = null;
        _dataClient.deleteDiary(id, null);
        // 主 App 感知占位行删除（跨 engine 计数桥，见 DiarySyncBridge）
        DiarySyncBridge.bump();
        _diaries.removeWhere((d) => d['id'] == id);
        _exitEdit();
        AccessibilityOverlay.vibrateTick();
        return;
      }
      // trim 后为空视同取消（不写库，防误清空日记内容）
      print('✏️ [OverlayHome] 保存内容为空，视同取消编辑 id=$id');
      _cancelEdit();
      return;
    }
    try {
      await DbHelper().updateDiary(id, newContent);
      // 主 App 感知本次编辑写入（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      // ⚠️ sqflite 查询返回的行是只读 QueryRow，原地改字段会抛
      // "Unsupported operation: read-only"——拷贝新 Map 整体替换列表元素
      //（同 _toggleArchive 的乐观 UI 模式）
      final idx = _diaries.indexWhere((d) => d['id'] == id);
      if (idx >= 0) {
        _diaries[idx] = {..._diaries[idx], 'content': newContent};
      }
      // 保存成功：若是新增笔记占位行，清占位标记（行已落库为正式内容）
      if (id == _pendingNewNoteId) {
        _pendingNewNoteId = null;
      }
      print('✅ [OverlayHome] 日记编辑已保存 id=$id (len=${newContent.length})');
      _exitEdit();
      // 保存成功的 tick 震动（对齐删除/复制按钮的原生 EFFECT_TICK 反馈）
      AccessibilityOverlay.vibrateTick();
    } catch (e) {
      // 写库失败留在编辑态，用户可再试或取消（悬浮窗无 SnackBar 上下文）
      print('❌ [OverlayHome] 保存编辑失败 id=$id: $e');
    }
  }

  /// 取消编辑（✗ / 卡片 chevron / 硬件返回键 / 语音速记触发丢弃）：不写库直接退出。
  /// 新增笔记占位行（id == _pendingNewNoteId）且内容仍为空 → 顺带删占位行
  ///（对齐主 App 空白新笔记取消删行先例）
  void _cancelEdit() {
    final id = _editingDiaryId;
    if (id == null) return;
    print('✏️ [OverlayHome] 取消编辑 id=$id');
    // 占位行取消且未输入任何内容：删占位行 + 列表移除 + 清标记。
    // deleteDiary fire-and-forget（占位行无录音文件，失败残留一条空行无害）
    if (id == _pendingNewNoteId &&
        (_editController?.text ?? '').trim().isEmpty) {
      _pendingNewNoteId = null;
      _dataClient.deleteDiary(id, null);
      // 主 App 感知占位行删除（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      _diaries.removeWhere((d) => d['id'] == id);
    }
    _exitEdit();
  }

  /// 退出编辑公共收尾：摘返回键 handler → 收键盘 → 窗口回 default flag
  ///（恢复 NOT_FOCUSABLE）→ dispose controller 置 null → 清编辑真值 → setState
  void _exitEdit() {
    HardwareKeyboard.instance.removeHandler(_editKeyHandler);
    _editFocusNode?.unfocus();
    AccessibilityOverlay.updateFlag('default');
    _editController?.dispose();
    _editController = null;
    _editingDiaryId = null;
    if (mounted) {
      setState(() {});
    }
  }

  /// 编辑态手势降级公共判断（空白区点击/滑动、面板右滑收起共用）：
  /// 编辑中 → 仅收起键盘并返回 true（调用方据此跳过原有收起面板动作，
  /// 不标记 _willCollapse、不调 _collapse、不退出编辑）
  bool _dismissKeyboardIfEditing() {
    if (_editingDiaryId == null) return false;
    _editFocusNode?.unfocus();
    return true;
  }

  /// 新增笔记（header「+」按钮 / _onNewNote 手势消息共用入口）：
  /// 插占位行（content=''）→ 静默刷新列表 → 找到新行进编辑态（光标在 0）。
  /// 空内容保存/取消时删占位行（见 _saveEdit / _cancelEdit 的
  /// _pendingNewNoteId 特判，对齐主 App 空白新笔记取消删行先例）
  Future<void> _startNewNote() async {
    // 编辑中（含未保存的新笔记）不重复插入空行（防连点插入多条空占位行）；
    // 语音速记非 idle 期间面板不可达，直接忽略
    if (_editingDiaryId != null) return;
    if (_voiceMemo.state != OverlayVoiceMemoState.idle) return;
    try {
      final newId = await _dataClient.insertDiary('');
      // 主 App 感知占位行插入（跨 engine 计数桥，见 DiarySyncBridge）
      DiarySyncBridge.bump();
      if (!mounted) return;
      _pendingNewNoteId = newId;
      // 静默刷新（不闪 loading 圈）：getDiaries 排序 is_archived ASC +
      // created_at DESC，新占位行必在首位
      await _loadDiaries(showLoading: false);
      // await 期间面板可能已收起/浮窗已被原生隐藏：占位行保留，不弹键盘
      //（不打扰；空行残留由下次编辑取消/复位路径清理，主 App 侧也可编辑）
      if (!mounted || _controller.isCollapsed) return;
      final idx = _diaries.indexWhere((d) => d['id'] == newId);
      if (idx < 0) return;
      // 先把新卡标为展开态再进编辑：收起态卡片的 _buildExpandedContent
      //（编辑态 TextField 所在）不参与构建，postFrameCallback 的 requestFocus
      // 会打在未挂载的 FocusNode 上落空（键盘不弹的根因，945be75 确诊）。
      // 收起/复位的互斥清理点（_resetFromNative 等）已有
      // _expandedIds.clear()，占位行取消删除时 id 已不在列表，残留成员无害，
      // 无需额外挂点
      _expandedIds.add(newId);
      print('📝 [OverlayHome] 新增笔记占位行 id=$newId，进入编辑态');
      _enterEdit(_diaries[idx], 0, allowEmpty: true);
    } catch (e) {
      print('❌ [OverlayHome] 新增笔记失败: $e');
    }
  }

  /// 原生 newNote 消息（overlay_new_note 手势动作）：展开面板并新增一条笔记。
  /// 悬浮窗已显示且面板展开时重复触发 = 再新增一条（产品已定此语义）
  Future<void> _onNewNote() async {
    if (!mounted) return;
    // 录音/转写中忽略（语音胶囊在屏，面板交互不可达）
    if (_voiceMemo.state != OverlayVoiceMemoState.idle) return;
    // 面板已稳定展开时跳过 _expand：否则会走"稳定展开态防御重播"分支
    //（空白帧 + resize + 重播滑入动画），已展开时重复触发新增会视觉回闪。
    // 把手态/动画中/隐藏重建后仍走原 await 扩窗路径
    final alreadyExpanded =
        _controller.isExpanded && _panelAnimPhase == _PanelAnimPhase.idle;
    if (!alreadyExpanded) {
      // await 展开完成（controller 置 expanded）再进新增流程——不 await 的话
      // _startNewNote 的"面板已收起"守卫可能与扩窗 await 链赛跑，误判不收起
      await _expand(); // 幂等：把手态自动展开带动画
      if (!mounted) return;
    }
    _startNewNote();
  }

  /// 停止播放并归零状态（幂等：空闲时直接返回）。
  /// 调用方：开录音前（onStartVoiceMemo，防扬声器回采污染识别）、
  /// 卡片删除（_onCardDelete，录音文件即将删除）、
  /// 收起面板（_collapse，收起后只剩把手无暂停 UI——用户已确认收起即停）、
  /// 浮窗彻底隐藏复位（_resetFromNative，无窗口不放声）
  Future<void> _stopAudioPlayback() async {
    if (_playingDiaryId == null) return;
    print('🔊 [OverlayHome] 停止播放 id=$_playingDiaryId');
    if (mounted) {
      setState(() {
        _playingDiaryId = null;
        _isPlaying = false;
      });
    }
    try {
      await _audioPlayer.stop();
    } catch (e) {
      print('❌ [OverlayHome] 停止播放失败: $e');
    }
  }

  /// 轻震动反馈（照 list_tab._haptic 模式：vibration 插件 + hasVibrator 检查。
  /// 不能用主 App diary_tab 的 _haptic——那走主 App MethodChannel，
  /// overlay engine 没注册该 channel）
  Future<void> _vibrate() async {
    try {
      // vibration 3.1.8 的 hasVibrator 返回非空 Future<bool>
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: 20, amplitude: 50);
      }
    } catch (e) {
      print('OverlayHome 震动失败: $e');
    }
  }

  /// 全部展开/收起（header 按钮；allIds 现算——列表随时可能被归档刷新重建）
  void _toggleExpandAll() {
    final allIds = _diaries.map((d) => d['id'] as int).toSet();
    setState(() {
      if (allIds.isNotEmpty && _expandedIds.containsAll(allIds)) {
        _expandedIds.clear();
      } else {
        _expandedIds
          ..clear()
          ..addAll(allIds);
      }
    });
  }

  /// 等待当前空白帧真正呈现后再放行 resize：TextureView 在窗口尺寸变化、
  /// 新尺寸帧尚未生成时会把旧纹理重投影到新窗口（拉伸成巨型把手/锚定左上角），
  /// resize 前必须确保已呈现的最后一帧是纯透明的。两层 postFrameCallback
  ///（第一层末尾显式 scheduleFrame 保证第二帧必然发生——postFrameCallback
  /// 自身不会触发新帧）+ 300ms 超时兜底（帧管线极端延迟时优先保功能不卡死）
  Future<void> _waitForBlankFramePresented() async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    });
    try {
      await completer.future.timeout(const Duration(milliseconds: 300));
    } catch (_) {
      // 超时兜底：继续走 resize（极端卡顿时闪烁风险换功能可用）
    }
  }

  /// build 顶层调用：检测原生 resize 是否已落地（窗口约束变化）。
  /// awaitingResize 期间渲染纯空白；约束一变说明新尺寸帧已可生成，解除守卫。
  /// 展开等待中同时在此启动滑入动画（forward 只同步通知 status listener，
  /// 本类只处理 completed/dismissed，build 期调用安全）。
  ///（揭示门的摘/挂不在此：隐藏窗口直建胶囊尺寸，摘门条件 = build 挂门
  /// 短路处的"录音态首帧"，见 _revealGatePending 注释）
  void _maybeAdvanceMetricsStage(BoxConstraints constraints) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final last = _lastWindowConstraints;
    _lastWindowConstraints = size;
    if (_metricsStage != _MetricsStage.awaitingResize) return;
    if (last == null || last == size) return; // resize 尚未落地
    _metricsStage = _MetricsStage.idle;
    print(
      '📐 [OverlayHome] resize 已落地: '
      '${last.width.toStringAsFixed(1)}x${last.height.toStringAsFixed(1)} → '
      '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}，恢复渲染',
    );
    // 缩窗方向（宽高均变小）：窗口原点从 (0,0) 跳到右缘居中，frame 过渡完成前
    // 恢复渲染的首帧会被锚在旧原点=屏幕左上角——fade-in 起步让错位帧近乎
    // 透明；扩窗方向旧原点与新帧把手位置重合，直接满显（fade 置 1）
    final shrinking = size.width < last.width && size.height < last.height;
    if (shrinking) {
      _postResizeFade.forward(from: 0);
    } else {
      _postResizeFade
        ..stop()
        ..value = 1;
    }
    if (_panelAnimPhase == _PanelAnimPhase.expanding) {
      _panelAnim.forward(); // 展开滑入：从 t=0 初始位姿起步
    }
  }

  /// 面板滑动动画边界回调（窗口尺寸切换被编排到这里的时机）
  ///
  /// completed（滑入就位）→ expanding：setState 回 idle 稳定态（把手叠加层
  /// 退出渲染树）；dismissed（滑出完成）→ collapsing：面板已整块滑出窗口
  /// 右边界不可见，此刻走空白帧收尾——phase 先直接赋值 idle（非 setState），
  /// 紧随的 setState 置空白守卫（渲染纯透明帧），_finishCollapse 等空白帧
  /// 真正呈现后才缩窗 + 排定 _scheduleAutoHide（其 isCollapsed 检查在
  /// collapse 之后才通过）。顺序不可换。
  /// phase 守卫：value setter / stop 可能补发的同向 status 回调被吞掉，不重放链
  void _onPanelAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        _panelAnimPhase == _PanelAnimPhase.expanding) {
      setState(() {
        _panelAnimPhase = _PanelAnimPhase.idle;
      });
      print('🎬 [OverlayHome] 面板滑入完成 → 稳定展开');
    } else if (status == AnimationStatus.dismissed &&
        _panelAnimPhase == _PanelAnimPhase.collapsing) {
      _panelAnimPhase = _PanelAnimPhase.idle;
      // 收起末帧理论上是纯空白（收起动画期间不渲染把手），但最后呈现的纹理
      // 可能停在 value≈0.001 的残影帧——等一帧真正的空白呈现后再缩窗
      setState(() {
        _metricsStage = _MetricsStage.awaitingResize;
      });
      _finishCollapse();
    }
  }

  /// 收起动画 dismissed 边界的收尾：等空白帧呈现后再缩窗 + 排定自动隐藏。
  /// stage 保持 awaitingResize 直到小 metrics 落地由 _maybeAdvanceMetricsStage
  /// 清除（期间把手分支也渲染空白，落地后把手出现于右缘垂直居中）
  Future<void> _finishCollapse() async {
    await _waitForBlankFramePresented();
    if (!mounted || _metricsStage != _MetricsStage.awaitingResize) {
      // 期间被 reset/语音打断（两者都会清守卫）：窗口已被接管，等待方直接
      // 放行（reset 路径窗口已移除必然不挡；语音路径胶囊是小窗口不挡授权框）
      _collapseSettled?.complete();
      _collapseSettled = null;
      return;
    }
    // 面板已滑出不可见：清展开态/删除确认态/标注选择态——收起 = 本轮编辑结束，
    // 下次从把手再展开应全部收起（不能在 _collapse 入口清：滑出动画会原地缩卡
    // 跳变；中断收起路径走不到这里，状态天然保留）。_resetFromNative 有同样清空，
    // 覆盖"彻底隐藏"路径，两者互补
    _expandedIds.clear();
    _deleteConfirmIds.clear();
    _tagPickingIds.clear();
    _controller.collapse(); // → resize(28,88)；此刻旧纹理已是空白 → 无重投影闪烁
    _scheduleAutoHide(); // 收起态排定自动隐藏（必须在 collapse 之后）
    print('🎬 [OverlayHome] 面板滑出完成 → 缩窗回把手 + 排定自动隐藏');
    // 缩窗 resize 已发出，放行等待方（_onCardAlarm 权限路径此刻拉起主 App，
    // 系统授权框弹出时悬浮窗已只剩把手不挡触摸）
    _collapseSettled?.complete();
    _collapseSettled = null;
  }

  /// 展开面板（推屏滑入：先扩窗全屏，首帧渲染"面板全隐+把手渐显位"初始位姿，
  /// 再从右缘滑入渐显——resize 前后两帧像素位置连续，无整帧闪现。
  /// 扩窗前走空白帧协议：先渲染纯透明帧并等其真正呈现再 resize，防止旧纹理
  /// 被 TextureView 重投影到新窗口——巨型把手/左上角飞闪的根因修复）
  Future<void> _expand() async {
    // 展开即取消"收起后自动隐藏"计时（时限内再展开不会中途消失）
    _hideScheduleGeneration++;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    if (_panelAnimPhase == _PanelAnimPhase.expanding) {
      // 展开动画中重复触发（onExpand 防御 resize 与把手点击竞态）→ 幂等 no-op
    } else if (_panelAnimPhase == _PanelAnimPhase.collapsing) {
      // 收起动画中点渐显把手/长按自动展开 → 从当前进度反向滑回（窗口不动零 resize）
      setState(() {
        _panelAnimPhase = _PanelAnimPhase.expanding;
        // 中断收起场景把手连续渐显（无空白期），不抑制叠加把手
        _handleOverlaySuppressed = false;
      });
      _panelAnim.forward();
    } else if (_controller.isCollapsed) {
      // 主路径：稳定收起态。先渲染空白帧并等其真正呈现（旧把手纹理不能被
      // 重投影到新窗口），再 controller.expand() 触发 resize(-1,-1)；
      // 滑入动画等大 metrics 落地后由 _maybeAdvanceMetricsStage 启动
      _panelAnim.value = 0;
      setState(() {
        _panelAnimPhase = _PanelAnimPhase.expanding;
        _metricsStage = _MetricsStage.awaitingResize;
        // 真展开路径（有空白期）：恢复渲染后不再满显重现把手（三段闪烁），面板直接滑入
        _handleOverlaySuppressed = true;
      });
      await _waitForBlankFramePresented();
      if (!mounted || _metricsStage != _MetricsStage.awaitingResize) {
        return; // 等待期间被 reset/语音打断（两者都会清守卫，stage 变化即中断信号）
      }
      _controller.expand(); // → resize(-1,-1)；此刻旧纹理已是空白 → 无重投影闪烁
    } else {
      // 稳定展开态再触发（语音转写完成路径）：controller.expand() 幂等不
      // notifyListeners → 不会 resize，而此刻窗口刚被语音胶囊 resize 成非全屏，
      // 防御性手动扩窗 + 重置位姿重播滑入。扩窗同样需空白帧先行——语音胶囊
      // 纹理不能被重投影
      _panelAnim.value = 0;
      setState(() {
        _panelAnimPhase = _PanelAnimPhase.expanding;
        _metricsStage = _MetricsStage.awaitingResize;
        // 真展开路径（有空白期）：恢复渲染后不再满显重现把手（三段闪烁），面板直接滑入
        _handleOverlaySuppressed = true;
      });
      await _waitForBlankFramePresented();
      if (!mounted || _metricsStage != _MetricsStage.awaitingResize) {
        return; // 等待期间被 reset/语音打断（两者都会清守卫，stage 变化即中断信号）
      }
      AccessibilityOverlay.resizeOverlay(-1, -1);
    }
    // 跨 engine 无数据推送，展开时靠 DiarySyncBridge 计数脏检查：
    // 主 App 侧有新写入才重查，无变更零开销（首次 -1 必刷新）
    _syncDiariesIfChanged();
  }

  /// 收起为把手（推屏滑出：先在保持全屏的窗口里向右滑出渐隐——全程无 resize
  /// 窗口不动；缩窗延迟到 dismissed 边界的空白帧收尾，见 _finishCollapse）。
  /// 自动隐藏计时同样在收尾中排定（收起到位才算"收起态"）。
  /// 收起动画期间不渲染把手，保证 dismissed 末帧纯空白
  void _collapse() {
    if (_panelAnimPhase == _PanelAnimPhase.collapsing) {
      // 收起动画中重复触发 → 忽略（面板已 IgnorePointer，此处兜底）
      return;
    }
    if (_controller.isCollapsed) {
      // 稳定收起态重复收起 → 幂等
      return;
    }
    // 收起即停播放：收起后窗口只剩把手，没有任何暂停按钮，继续响会失控
    //（用户已确认此行为；_stopAudioPlayback 幂等，未播放时零成本）
    _stopAudioPlayback();
    // 信号器随本轮收起创建；上一轮残留的未消费信号先放行（防串轮：新一轮
    // 收起开始，旧等待方关心的"窗口不挡触摸"已无意义或即将由本轮重现）
    _collapseSettled?.complete();
    _collapseSettled = Completer<void>();
    // idle+expanded 主路径 与 expanding 中断反向 共用：显式 setState 置
    // collapsing（收起动画期间不渲染把手，保证 dismissed 末帧纯空白），
    // controller 保持 expanded（resize 链延迟到 dismissed 边界）
    setState(() {
      _panelAnimPhase = _PanelAnimPhase.collapsing;
    });
    _panelAnim.reverse();
  }

  /// 原生 hideOverlay 后的复位（收到 "reset" 消息）：
  /// 取消自动隐藏计时 + 回到收起态，避免下次 showOverlay 首帧残留展开态
  /// （controller.expand() 幂等不触发 notifyListeners → resize 永远不被调 → 卡把手尺寸）
  void _resetFromNative() {
    // 浮窗已彻底隐藏（窗口被原生移除）：停止回放，无窗口不放声。
    // fire-and-forget 即可，方法本身同步语义不变
    _stopAudioPlayback();
    // 动画跳终态（收起）：stop → phase 先归 idle → value=0，顺序不可换——
    // value setter 若补发 dismissed 回调，此刻 phase 已是 idle，被
    // _onPanelAnimStatus 守卫吞掉，不会误触缩窗+自动隐藏链（窗口已被原生
    // 移除，resize 会被 Kotlin overlayView 空守卫吞掉，但计时不该排定）
    _panelAnim.stop();
    _panelAnimPhase = _PanelAnimPhase.idle;
    _panelAnim.value = 0;
    // 清揭示门：窗口已被原生移除，残留挂门会影响下个会话（挂门期渲染纯空白，
    // 若带到下次 showOverlay 会导致把手永不渲染）
    _revealGatePending = false;
    // 清空白守卫：复位后渲染把手（并作废 _expand/_finishCollapse 的 await 续段）
    _metricsStage = _MetricsStage.idle;
    // 收起中断于窗口移除：放行等待方（窗口已被原生移除必然不挡授权框，
    // 不用等超时兜底）
    _collapseSettled?.complete();
    _collapseSettled = null;
    // 抑制标志复位：窗口已移除，下次 showOverlay 从把手起步（叠加把手
    // 不该带残留抑制态）
    _handleOverlaySuppressed = false;
    // fade 防御性置满显：复位路径不走 _maybeAdvanceMetricsStage，若 fade 停在
    // 中途（收起渐显中被 reset），下次 showOverlay 首帧会半透明
    _postResizeFade
      ..stop()
      ..value = 1;
    _hideScheduleGeneration++;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    // 展开态/删除确认态/标注选择态随窗口移除一并清空：下次打开从全收起开始
    //（overlay engine 常驻、State 跨会话存活，不清会带着上次的展开卡）
    _expandedIds.clear();
    _deleteConfirmIds.clear();
    _tagPickingIds.clear();
    _expandFirstDiaryAfterLoad = false;
    // 防御性清编辑态（窗口被原生移除路径）：残留编辑态会把键盘焦点 /
    // focuspointer flag 带到下个会话。走 _cancelEdit 而非 _exitEdit：
    // 新增笔记占位行（内容为空）在此统一删行，不留空行残留
    if (_editingDiaryId != null) {
      _cancelEdit();
    }
    // 语音速记转写中收到 reset（浮窗被彻底隐藏，如 toggle 长按隐藏）：只复位面板视觉
    // （collapse），**转写 Future 不打断**——overlay engine 常驻后台会继续跑完写库，
    // 转写中隐藏浮窗数据不丢。转写完成后 _onVoiceMemoChanged 的 _expand 触发的
    // resize 会被 Kotlin 侧 overlayView 空守卫安全吞掉（窗口已移除）
    _controller.collapse();
    if (mounted) {
      setState(() {});
    }
  }

  /// 排定收起态的自动彻底隐藏（默认 10 秒，可用设置页 overlay_auto_hide_seconds
  /// 配置 5/10/30 秒或「永久」——永久为哨兵值 autoHideNeverSeconds，不起计时）
  Future<void> _scheduleAutoHide() async {
    // 录音/转写期间不自动隐藏（胶囊/转写 UI 常驻，中途消失会丢 UI 反馈）；
    // 转写完成切面板后，收起时才恢复计时。generation 竞态机制不受影响
    if (_voiceMemo.state != OverlayVoiceMemoState.idle) return;
    final generation = ++_hideScheduleGeneration;
    var seconds = OverlayConstants.autoHideDefaultSeconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      // 跨 engine 读主 App 新写的值（各 engine 的 prefs 内存缓存隔离，必须 reload）
      await prefs.reload();
      seconds = prefs.getInt('overlay_auto_hide_seconds') ??
          OverlayConstants.autoHideDefaultSeconds;
    } catch (_) {
      // 读配置失败按默认 10 秒兜底，不阻塞隐藏流程
    }
    if (generation != _hideScheduleGeneration) return; // await 期间用户又展开了
    if (!_controller.isCollapsed) return; // 双保险：非收起态不隐藏
    // 「永久」：收起态把手常驻，不彻底隐藏（展开/收起链路无需感知，本方法
    // 每次收起都会被重新调用，改回限时档自然恢复计时）
    if (seconds == OverlayConstants.autoHideNeverSeconds) return;
    _autoHideTimer = Timer(Duration(seconds: seconds), () {
      _autoHideTimer = null;
      // → 原生 hideOverlay → 发 reset 复位 Dart 状态（见 _resetFromNative）
      AccessibilityOverlay.closeOverlay();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);

    return Material(
      color: Colors.transparent,
      // LayoutBuilder 顶层检测窗口约束变化（resize 落地）以解除空白守卫
      child: LayoutBuilder(
        builder: (context, constraints) {
          _maybeAdvanceMetricsStage(constraints);
          // 揭示门短路：挂门期间渲染纯透明空白（把手/胶囊像素不进帧）。
          // 摘门条件 = "录音/转写态的首帧"：窗口从创建起就是胶囊尺寸（312×64），
          // 本帧渲染的就是正确尺寸的胶囊，构建完发揭示信号——确定性事件，
          // 不依赖"约束变化检测"（旧机制的时序缺陷见 64b1c09 /
          // docs/architecture/悬浮窗录音闪烁.md）。
          // 必须放在 _maybeAdvanceMetricsStage 之后，保证空白守卫链路照常执行
          if (_revealGatePending) {
            if (_voiceMemo.state != OverlayVoiceMemoState.idle) {
              _revealGatePending = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                AccessibilityOverlay.voiceMemoUiReady();
              });
              // 不 return——本帧直接落到下方语音速记分支渲染胶囊
            } else {
              return const SizedBox.shrink();
            }
          }
          // 硬不变量：把手（88dp 高）永远不可能合法出现在胶囊高度（64dp）的
          // 窗口里。语音速记冷启动窗口从创建起就是 312×64，engine attach 瞬间
          // / startVoiceMemo 到达前的 pre-gate 帧（state 仍 idle）在此渲染空白，
          // 把手像素物理上不存在于该路径的任何一帧
          if (_voiceMemo.state == OverlayVoiceMemoState.idle &&
              constraints.maxHeight < OverlayConstants.handleHeight) {
            return const SizedBox.shrink();
          }
          // 语音速记（录音/转写）优先于把手/面板分支——此时窗口已被 resize 成胶囊尺寸，
          // 把手（28×88）和全屏面板都不该渲染（语音进入时 _onVoiceMemoChanged 会清
          // 空白守卫，此分支不会被守卫误吞）
          if (_voiceMemo.state != OverlayVoiceMemoState.idle) {
            return OverlayVoiceMemoBar(controller: _voiceMemo);
          }
          // 空白守卫：resize 落地前的所有帧渲染纯透明（见 _MetricsStage 注释），
          // 旧纹理重投影到新窗口时不可见——这是消除巨型把手/左上角飞闪的关键
          if (_metricsStage == _MetricsStage.awaitingResize) {
            return const SizedBox.expand();
          }
          final content = _controller.isCollapsed
              // Align 把把手钉在右缘垂直居中：窗口=把手尺寸时恒等；resize 未落地
              // 的一两帧防裸把手画在全屏帧左上角（既有保险，保留）
              ? Align(
                  alignment: Alignment.centerRight,
                  child: _buildHandle(ext),
                )
              : _buildPanel(ext);
          // 缩窗方向恢复渲染的把手回位动效（见 postResizeFadeDuration 注释）：
          // value=0 → opacity 0 + 平移 (1,0)（把手整块在小窗右侧外，被 surface 裁剪
          // =屏幕外不可见），窗口 frame 移动期用户什么都看不到；value 0→1（后 180ms）
          // 从屏幕右缘滑入+渐显就位——与面板推屏滑出同一语义/同一裁剪机制。
          // 稳定态 value 恒 1：平移 (0,0)+opacity 1，恒等无感。AnimatedBuilder 的
          // child 缓存 content 子树，tick 只重建平移/透明层（同 _buildPanel 动画层模式）
          return AnimatedBuilder(
            animation: _postResizeFadeCurve,
            child: content,
            builder: (context, child) => FractionalTranslation(
              translation: Offset(1 - _postResizeFadeCurve.value, 0),
              child: Opacity(opacity: _postResizeFadeCurve.value, child: child),
            ),
          );
        },
      ),
    );
  }

  /// 收起态：边缘胶囊把手
  Widget _buildHandle(AppThemeExtension ext) {
    return GestureDetector(
      onTap: _expand,
      onHorizontalDragUpdate: (details) {
        // 向屏幕内侧（左）滑动超过阈值，标记为待展开
        if (details.primaryDelta != null &&
            details.primaryDelta! < -OverlayConstants.edgeSwipeThreshold) {
          _willExpand = true;
        }
      },
      onHorizontalDragEnd: (_) {
        if (_willExpand) {
          _willExpand = false;
          _expand();
        }
      },
      child: Container(
        width: OverlayConstants.handleWidth.toDouble(),
        height: OverlayConstants.handleHeight.toDouble(),
        decoration: BoxDecoration(
          color: ext.primary.withValues(alpha: 0.92),
          // 全圆角胶囊：半径 = 宽度一半（28dp → 14dp），随宽度自动适配
          borderRadius: BorderRadius.circular(OverlayConstants.handleWidth / 2),
          // 无 boxShadow：窗口尺寸=把手尺寸（28×88），阴影向胶囊外扩散会被窗口
          // 边缘硬裁剪，四周形成灰色矩形色块（同面板"透明背景不留 boxShadow"
          // 的既有决策）；层次感由实色胶囊自身承担
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt,
              size: OverlayConstants.handleIconSize,
              color: ext.textOnPrimary.withValues(alpha: 0.9),
            ),
            const SizedBox(height: 6),
            Text(
              // 中文逐字竖排：字符间插入换行，每个汉字独占一行
              OverlayConstants.handleLabel.characters.join('\n'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: OverlayConstants.handleFontSize,
                height: 1.2,
                fontWeight: FontWeight.w500,
                color: ext.textOnPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态：全屏窗口 + 贴右上的自适应面板
  ///
  /// 展开窗口由原生侧铺满全屏（resizeOverlay 哨兵值 -1 → MATCH_PARENT，
  /// 左侧空白区手势依赖全屏窗口，不可改成非全屏）。本方法在窗口内 Stack
  /// 布局：[Positioned.fill] 透明空白区垫满整个窗口（点击/左滑关闭悬浮窗，
  /// 见 [_buildBlankArea]，面板渲染在其上层）+ [Alignment.topRight] 面板
  /// （header + 日记列表，宽度比例唯一真值在
  /// [OverlayConstants.expandedWidthRatio]）。面板高度随日记条数自适应：
  /// Column 收缩到内容高度（mainAxisSize.min），列表用 Flexible + shrinkWrap
  /// + ConstrainedBox 限高——条目少时面板只包住卡片；条目多时列表区域限高约
  /// maxVisibleDiaryCards 张卡高度（panelListMaxHeight），超出内部滚动；
  /// 矮屏再被窗口高度约束。
  /// 面板背景透明（无背景色与阴影——透明背景上留 boxShadow 会画出奇怪的
  /// 阴影框），层次感由卡片自身阴影提供。
  Widget _buildPanel(AppThemeExtension ext) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 面板宽度 = 展开窗口宽 × 比例；有卡展开时加宽到 0.92（展开卡对齐闪念
        // 原型明显更宽；收起卡右对齐内容自适应，面板变宽视觉零影响）
        final panelWidth =
            constraints.maxWidth *
            (_expandedIds.isEmpty
                ? OverlayConstants.expandedWidthRatio
                : OverlayConstants.expandedPanelWidthRatio);
        // 卡片宽度上限按展开态分离（不再统一跟随 panelWidth——面板加宽动画
        // 会把所有顶到 maxWidth 的长卡临时拉宽）：
        // 收起卡恒用默认比例（内容自适应右对齐，maxWidth 不变 = 渲染宽度零变化，
        // 长文本省略号截断位置也不变）；只有展开卡用加宽比例，配合自身
        // AnimatedContainer 的 constraints.maxWidth 补间平滑变宽。面板加宽
        // 保留：为展开卡提供布局/命中空间
        final collapsedCardMaxWidth =
            constraints.maxWidth * OverlayConstants.expandedWidthRatio - 28;
        final expandedCardMaxWidth =
            constraints.maxWidth * OverlayConstants.expandedPanelWidthRatio -
            28;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 空白区垫底铺满整个窗口（面板以外全部区域）：点击/左滑关闭
            //（动画中空白区仍可点 = 中断收起的入口，故不包进动画层）
            Positioned.fill(child: _buildBlankArea(ext)),
            // 面板贴右上，高度随内容自适应。动画层：FractionalTranslation 按
            // child 自身宽比例平移（(1-t)×child宽，t=0 整块推出窗口右边界、被
            // surface 裁剪=滑出屏幕；panelWidth 变化自动适配）+ Opacity 渐隐；
            // AnimatedBuilder 的 child 参数缓存面板子树（SizedBox+Column 整块），
            // tick 只重建 transform/opacity 层，不重建 ListView
            Align(
              alignment: Alignment.topRight,
              child: AnimatedBuilder(
                animation: _panelAnimCurve,
                // 动画中禁点面板（防滑出途中误触卡片/按钮）；phase 变化总伴随
                // setState → child 随整体 rebuild 重建，ignoring 即时生效
                child: IgnorePointer(
                  ignoring: _panelAnimPhase != _PanelAnimPhase.idle,
                  // 面板区域右滑收起：朝把手停靠边缘（右缘，+x）滑动即收起面板。
                  // 与空白区的"任意方向"语义不同是有意的——面板内左滑无含义，
                  // 放开易误触。水平 drag 与 ListView 垂直滚动方向不同，
                  // 手势竞技场天然并存互不干扰
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent, // 卡片间隙也能命中
                    onHorizontalDragUpdate: (details) {
                      // 编辑态手势降级：滑动只收起键盘，不标记待收起
                      if (_dismissKeyboardIfEditing()) return;
                      if (details.primaryDelta != null &&
                          details.primaryDelta! >
                              OverlayConstants.edgeSwipeThreshold) {
                        _willCollapse = true;
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      // 编辑态手势降级：松手只收起键盘，不收起面板
                      if (_dismissKeyboardIfEditing()) return;
                      if (_willCollapse) {
                        _willCollapse = false;
                        _collapse();
                      }
                    },
                    onHorizontalDragCancel: () => _willCollapse = false,
                    // AnimatedContainer 补间面板宽度（有卡展开 0.72→0.92 平滑加宽）
                    child: AnimatedContainer(
                      duration: OverlayConstants.animationDuration,
                      width: panelWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 顶部标题栏 + 收起按钮
                          _buildHeader(ext),
                          // 日记列表：条目少时收缩到内容高度，条目多时占满剩余空间内部滚动
                          Flexible(
                            child: _loading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : _error
                                ? _buildErrorView(ext)
                                : _diaries.isEmpty
                                ? _buildEmptyView(ext)
                                // 区域限高约 maxVisibleDiaryCards 张卡高度，超出内部滚动
                                : ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight:
                                          OverlayConstants.panelListMaxHeight,
                                    ),
                                    child: ListView.builder(
                                      // 高度收缩到内容（配合外层 ConstrainedBox+Flexible
                                      // 实现：条目少收缩自适应，条目多限高内滚动）
                                      shrinkWrap: true,
                                      // 底部避让导航栏区域
                                      padding: const EdgeInsets.only(
                                        top: 8,
                                        bottom: 48,
                                      ),
                                      itemCount: _diaries.length,
                                      itemBuilder: (context, index) {
                                        final diary = _diaries[index];
                                        final id = diary['id'] as int;
                                        final isArchived =
                                            (diary['is_archived'] as int? ??
                                                0) ==
                                            1;
                                        // 已归档分隔线：当前条目已归档且上一条未归档
                                        //（依赖 getDiaries 排序 is_archived ASC,
                                        //  created_at DESC，复刻主 App diary_tab 分隔线模式）
                                        Widget? archivedSeparator;
                                        if (isArchived &&
                                            index > 0 &&
                                            (_diaries[index - 1]['is_archived']
                                                        as int? ??
                                                    0) !=
                                                1) {
                                          // 透明面板上用白色半透明（主 App 的 ext.textHint
                                          // 在壁纸背景上不可读）
                                          archivedSeparator = Padding(
                                            // 上下间距：分隔线在上、卡片 margin bottom 10 已有
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                              bottom: 4,
                                            ),
                                            child: Padding(
                                              // horizontal 14 对齐卡片左右 margin
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Divider(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.45,
                                                          ),
                                                    ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                        ),
                                                    child: Text(
                                                      '已归档',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.7,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Divider(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.45,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        }
                                        // ValueKey(id)：归档移位后 Element 不复用，
                                        // AnimatedContainer 不跨条目做颜色/圆角插值
                                        return Column(
                                          key: ValueKey(id),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // null-aware element：分隔线为 null（非
                                            // 首条归档）时跳过不渲染
                                            ?archivedSeparator,
                                            OverlayDiaryCard(
                                              diary: diary,
                                              // 卡片宽度上限：仅本卡展开时用加宽值，
                                              // 收起卡恒用默认值（面板加宽不影响其他卡）
                                              maxWidth:
                                                  _expandedIds.contains(id)
                                                  ? expandedCardMaxWidth
                                                  : collapsedCardMaxWidth,
                                              // 展开态真值按 id 查（归档移位不错位）
                                              expanded: _expandedIds.contains(
                                                id,
                                              ),
                                              // 单击卡片 = 展开全文；展开态整卡 onTap
                                              // 置空不再收起（防与底部按钮区误触），
                                              // 展开态唯一收起入口 = 卡片右上角 chevron
                                              //（onCollapse，见下）
                                              onTap: _expandedIds.contains(id)
                                                  ? null
                                                  : () => _toggleExpand(id),
                                              // 复选框 = 归档/恢复 toggle（点复选框不冒泡展开）
                                              onCheckChanged: (target) =>
                                                  _toggleArchive(diary, target),
                                              // 播放按钮：本卡播放中图标切 pause。
                                              // 渲染与否由卡片按 audio_path + 归档态自判
                                              isPlayingAudio:
                                                  _playingDiaryId == id &&
                                                  _isPlaying,
                                              // 点按钮 → 播放/暂停/切卡（_toggleAudioPlay 三分支）
                                              onPlayToggle: () =>
                                                  _toggleAudioPlay(diary),
                                              // 展开态右上角收起 chevron：编辑态
                                              // 点击 = 取消编辑（等同 ✗），非编辑态
                                              // = 收起卡片
                                              onCollapse: _editingDiaryId == id
                                                  ? _cancelEdit
                                                  : () => _toggleExpand(id),
                                              // 正文编辑态：本卡为编辑卡时正文换
                                              // TextField、底条变「✗取消 / ✓保存」
                                              editing: _editingDiaryId == id,
                                              editController:
                                                  _editingDiaryId == id
                                                  ? _editController
                                                  : null,
                                              editFocusNode:
                                                  _editingDiaryId == id
                                                  ? _editFocusNode
                                                  : null,
                                              // 查看态正文点击进入编辑（参数 = 字符
                                              // 偏移）；content 为空的转写占位行不
                                              // 传 onTextTap（不可编辑）
                                              onTextTap:
                                                  ((diary['content']
                                                              as String?) ??
                                                          '')
                                                      .isEmpty
                                                  ? null
                                                  : (offset) => _enterEdit(
                                                      diary,
                                                      offset,
                                                    ),
                                              onEditSave: _saveEdit,
                                              onEditCancel: _cancelEdit,
                                              // 删除二次确认态（底行变「确认删除？✓✗」）
                                              isDeleteConfirming:
                                                  _deleteConfirmIds.contains(
                                                    id,
                                                  ),
                                              // 底部按钮条：删除（两次点击流转）/ ✗ 取消 /
                                              // 复制 / AI 对话（原生复制 + 拉起设置页
                                              // 选择的 AI 应用，见 _onCardShareToAI；
                                              // 原系统分享面板入口已被 AI 对话替换）
                                              onDelete: () =>
                                                  _onCardDelete(diary),
                                              onDeleteCancel: () =>
                                                  _onCardDeleteCancel(id),
                                              onCopy: () => _onCardCopy(
                                                (diary['content'] as String?) ??
                                                    '',
                                              ),
                                              // 闹钟：识别时间预填转轮确认 sheet →
                                              // 写系统日历（见 _onCardAlarm）
                                              onAlarm: () => _onCardAlarm(diary),
                                              onAiChat: () => _onCardShareToAI(
                                                (diary['content'] as String?) ??
                                                    '',
                                              ),
                                              // 标注选择态（底行变「❗ ⭐ 💡 ✗返回」）：
                                              // 入口按钮进选择态；点 tag 写库换色
                                              //（点已选中的 tag = 取消标注，传 null）；
                                              // ✗ 退出还原。归档卡同样允许标注
                                              //（视觉仍灰，恢复后显示标注色）
                                              isTagPicking: _tagPickingIds
                                                  .contains(id),
                                              onTagEntry: () =>
                                                  _onCardTagEntry(id),
                                              onTagToggle: (tag) =>
                                                  _setDiaryTag(id, tag),
                                              onTagPickCancel: () =>
                                                  _onCardTagPickCancel(id),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                builder: (context, panelChild) => FractionalTranslation(
                  // (1-t)×child宽：t=0 整块推出窗口右边界，被 surface 裁剪=滑出屏幕
                  translation: Offset(1 - _panelAnimCurve.value, 0),
                  child: Opacity(
                    opacity: _panelAnimCurve.value,
                    child: panelChild,
                  ),
                ),
              ),
            ),
            // 展开期间叠加把手：钉在全屏帧右缘垂直居中（=收起窗口最终落点，
            // resize 后位置连续）随 1-t 渐显；onTap=_expand 即"中断收起"入口。
            // 收起动画期间不渲染把手（保证末帧纯空白，缩窗时旧纹理重投影不可见；
            // 240ms 内不可中断是可接受代价）；画在 Stack children 最后 = 最上层。
            // 真展开路径（空白帧协议后恢复渲染）抑制不渲染——恢复时把手满显重现
            // 是"消失→重现→渐隐"三段闪烁；仅中断收起路径（把手连续渐显）渲染
            if (_panelAnimPhase == _PanelAnimPhase.expanding &&
                !_handleOverlaySuppressed)
              AnimatedBuilder(
                animation: _panelAnimCurve,
                child: _buildHandle(ext),
                builder: (context, handleChild) => Align(
                  alignment: Alignment.centerRight,
                  child: Opacity(
                    opacity: 1 - _panelAnimCurve.value,
                    child: handleChild,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 展开态空白区（Positioned.fill 垫满整个窗口，面板以外全部区域）：
  /// 透明渲染（const SizedBox.expand 无颜色），
  /// 点击或继续左滑（模式与把手 _willExpand 对称）关闭悬浮窗
  Widget _buildBlankArea(AppThemeExtension ext) {
    return GestureDetector(
      // 透明区域必须声明 opaque 才能命中 hit-test（默认 deferToChild 对透明
      // child 永远不命中，空白区收起手势会失灵）
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 编辑态手势降级：空白区点击只收起键盘，不收起面板、不退出编辑
        if (_dismissKeyboardIfEditing()) return;
        _collapse();
      },
      onHorizontalDragUpdate: (details) {
        // 编辑态手势降级：滑动只收起键盘，不标记待收起
        if (_dismissKeyboardIfEditing()) return;
        // 任意方向水平滑动超过阈值（左滑/右滑均可），标记为待收起
        if (details.primaryDelta != null &&
            details.primaryDelta!.abs() > OverlayConstants.edgeSwipeThreshold) {
          _willCollapse = true;
        }
      },
      onHorizontalDragEnd: (_) {
        // 编辑态手势降级：松手只收起键盘，不收起面板
        if (_dismissKeyboardIfEditing()) return;
        if (_willCollapse) {
          _willCollapse = false;
          _collapse();
        }
      },
      // drag 被取消时清掉残留标记（堵既有边角：标记残留会污染下一次手势）
      onHorizontalDragCancel: () => _willCollapse = false,
      child: const SizedBox.expand(),
    );
  }

  /// 顶部标题栏
  Widget _buildHeader(AppThemeExtension ext) {
    return Padding(
      // 全屏窗口（FLAG_LAYOUT_NO_LIMITS）延伸到状态栏下，overlay 窗口拿不到
      // 系统 insets，用固定 padding 避让状态栏
      padding: const EdgeInsets.fromLTRB(16, 40, 8, 4),
      child: Row(
        // 已移除"随手记"标题：剩余按钮右对齐
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 新增笔记按钮（"全展开"按钮左侧）：插占位行并进编辑态
          IconButton(
            onPressed: _startNewNote,
            icon: Icon(Icons.add, color: ext.textHint),
            tooltip: '新增笔记',
            visualDensity: VisualDensity.compact,
          ),
          // 全部展开/收起按钮（收起按钮左侧；空列表不渲染）
          if (_diaries.isNotEmpty) _buildExpandAllButton(ext),
          IconButton(
            onPressed: _collapse,
            icon: Icon(Icons.chevron_right, color: ext.textHint),
            tooltip: '收起',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 全部展开/收起按钮（锤子式全局开关；显示与否由 _buildHeader 的
  /// `if (_diaries.isNotEmpty)` 控制）
  Widget _buildExpandAllButton(AppThemeExtension ext) {
    final allIds = _diaries.map((d) => d['id'] as int).toSet();
    // allIds 含已归档条目，简单一致
    final allExpanded = allIds.isNotEmpty && _expandedIds.containsAll(allIds);
    return IconButton(
      onPressed: _toggleExpandAll,
      icon: Icon(
        allExpanded ? Icons.unfold_less : Icons.unfold_more,
        color: ext.textHint,
      ),
      tooltip: allExpanded ? '全部收起' : '全部展开',
      visualDensity: VisualDensity.compact,
    );
  }

  /// 空列表提示
  Widget _buildEmptyView(AppThemeExtension ext) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '暂无随手记',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: ext.textHint),
        ),
      ),
    );
  }

  /// 查询失败提示（点击重试）
  Widget _buildErrorView(AppThemeExtension ext) {
    return GestureDetector(
      onTap: _loadDiaries,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '⚠️ 加载失败 · 点击重试',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: ext.textHint),
          ),
        ),
      ),
    );
  }
}
