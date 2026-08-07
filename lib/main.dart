import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'app_logger.dart';
import 'db_helper.dart';
import 'text_processor.dart';
import 'record_tab.dart';
import 'list_tab.dart';
import 'settings_tab.dart';
import 'diary_tab.dart'; // [新增] 引入日记页
import 'widgets/blur_loading_overlay.dart';
import 'shortcut_manager.dart' as sm;
import 'recognizer_singleton.dart';
import 'splash_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_extension.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sherpa_onnx.initBindings();

  // 预读模型路径，使 hasModel 在模型未加载时也能正确判断
  await RecognizerSingleton.preloadModelPath();

  // 预读用户选择的主题（默认青兜底，找不到 ID 也回退到默认青）
  final prefs = await SharedPreferences.getInstance();
  final themeId = prefs.getString('selected_theme');
  final initialTheme = AppThemes.findById(themeId) ?? AppThemes.defaultTheme;
  // 初始化全局主题 notifier，AppRoot 内的 ValueListenableBuilder 会订阅它
  AppRoot.themeNotifier.value = initialTheme;

  // 全局拦截 print，自动收集日志到 AppLogger
  runZonedGuarded(
    () {
      runApp(AppRoot());
    },
    (error, stack) {
      // 捕获未处理的异步异常
      AppLogger.appLog('未捕获异常: $error\n$stack');
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line); // 保留控制台输出
        AppLogger.appLog(line); // 同时写入缓冲区
      },
    ),
  );
}

/// 应用根 widget——订阅 [AppRoot.themeNotifier] 实现主题热切换
///
/// 切换主题时只需：
/// ```dart
/// final prefs = await SharedPreferences.getInstance();
/// await prefs.setString('selected_theme', theme.id);
/// AppRoot.themeNotifier.value = theme; // 立即触发整树重建
/// ```
class AppRoot extends StatelessWidget {
  /// 全局主题状态——任何位置都能读写
  /// main() 启动时初始化为持久化的用户选择，默认青兜底
  static final ValueNotifier<AppThemeDefinition> themeNotifier =
      ValueNotifier<AppThemeDefinition>(AppThemes.defaultTheme);

  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeDefinition>(
      valueListenable: themeNotifier,
      builder: (context, themeDef, _) {
        return MaterialApp(
          title: '声物记',
          theme: themeDef.toThemeData(),
          home: const SplashScreen(child: MainScaffold()),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final TextProcessor _processor = TextProcessor();
  final DbHelper _dbHelper = DbHelper();

  // 全局loading状态
  bool _showGlobalLoading = false;
  String? _loadingMessage;

  // 退出相关状态
  DateTime? _firstBackPressedTime;
  int _backButtonCount = 0;
  static const Duration _exitPromptTimeout = Duration(seconds: 2);

  // 移动到后台的MethodChannel
  static const _platform = MethodChannel('com.shengwuji.app/app');

  // 防止快捷方式重复触发
  bool _hasHandledShortcutLaunch = false;

  // 闹钟响铃状态（原生层通过 SharedPreferences 传递）
  bool _isAlarmRinging = false;
  Timer? _alarmCheckTimer;

  // 【关键】给列表页创建一个"遥控器" (Key)
  final GlobalKey<ListTabState> _listTabKey = GlobalKey<ListTabState>();
  // 1. 定义 RecordTab 的遥控器
  final GlobalKey<RecordTabState> _recordTabKey = GlobalKey<RecordTabState>();
  // [新增] 日记页的 Key
  final GlobalKey<DiaryTabState> _diaryTabKey = GlobalKey<DiaryTabState>();
  @override
  void initState() {
    super.initState();
    _processor.loadConfigs();

    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);

    // 初始化快捷方式管理器（用于动态快捷方式）
    sm.ShortcutManager().initialize(_handleQuickRecord);

    // 定期检查闹钟响铃状态（原生层通过 SharedPreferences 传递）
    _alarmCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 原生层写入，必须 reload
      final ringing = prefs.getBool('is_alarm_ringing') ?? false;
      if (ringing != _isAlarmRinging && mounted) {
        setState(() => _isAlarmRinging = ringing);
      }
    });

    // 监听原生层的快捷方式启动事件（用于静态快捷方式和冷启动）
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'onShortcutLaunch') {
        final shortcutType = call.arguments as String;
        if (shortcutType == 'quick_record') {
          // 🔥 不在这里设置标志，让 _handleQuickRecord() 自己处理
          _handleQuickRecord();
        } else if (shortcutType == 'quick_text_note') {
          _handleQuickTextNote();
        }
      }
    });
  }

  @override
  void dispose() {
    _alarmCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当 App 进入后台或隐藏时，重置快捷方式防重复标志
    // 这样下次通过快捷方式启动时可以正常工作
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      if (_hasHandledShortcutLaunch) {
        log('App进入后台，重置快捷方式防重复标志');
        _hasHandledShortcutLaunch = false;
      }
    }
  }

  /// 处理快速录音快捷方式
  Future<void> _handleQuickRecord() async {
    // 🔥 防止重复触发：立即设置标志（在方法开始时）
    if (_hasHandledShortcutLaunch) {
      log('快捷方式已处理，忽略重复调用');
      return;
    }
    _hasHandledShortcutLaunch = true;

    final diaryState = _diaryTabKey.currentState;

    // 如果正在录音，停止录音（长按音量键切换逻辑）
    if (diaryState != null && diaryState.isListening) {
      log('🔑 快捷录音：检测到正在录音，执行停止');
      diaryState.stopListening();
      return;
    }

    // 切换到日记页（索引2）
    _currentIndex = 2;

    // 刷新UI以切换页面
    setState(() {});

    // 确保引擎状态已同步（快捷方式进入时 DiaryTab 的 isReady 可能未同步）
    if (diaryState != null) {
      await diaryState.refreshEngine();
      await diaryState.startListening(lockedMode: true);
    }
  }

  /// 处理双击音量键新建文本笔记
  Future<void> _handleQuickTextNote() async {
    if (_hasHandledShortcutLaunch) {
      log('快捷方式已处理，忽略重复调用');
      return;
    }
    _hasHandledShortcutLaunch = true;

    // 切换到日记页（索引2）
    _currentIndex = 2;
    setState(() {});

    final diaryState = _diaryTabKey.currentState;
    if (diaryState != null) {
      await diaryState.startNewTextNote();
    }
  }

  // 显示全局loading
  void showGlobalLoading({String? message}) {
    setState(() {
      _showGlobalLoading = true;
      _loadingMessage = message;
    });
  }

  // 隐藏全局loading
  void hideGlobalLoading() {
    setState(() {
      _showGlobalLoading = false;
      _loadingMessage = null;
    });
  }

  /// 检查冷启动时是否通过快捷方式启动
  Future<void> _checkColdStartShortcut() async {
    final launched = await sm.ShortcutManager().checkAndClearShortcutLaunch();
    if (launched) {
      // 🔥 不在这里设置标志，让 _handleQuickRecord() 自己处理
      // 延迟执行，确保 UI 已初始化
      await Future.delayed(const Duration(milliseconds: 300));
      await _handleQuickRecord();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // 📊 字体诊断（已关闭，减少日志噪音）
    // final theme = Theme.of(context);

    // 【重点优化】：将 Stack 移到 Scaffold 外层
    // 这样语音按钮相对于物理屏幕定位，不受 Scaffold 内部缩放影响，彻底解决按钮飞起问题
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _handleBackButtonPressed();
        if (shouldPop) {
          // 调用Android的moveTaskToBack方法，移动应用到后台而不是退出
          try {
            await _platform.invokeMethod('moveTaskToBack');
          } catch (e) {
            // 如果调用失败（比如在iOS上），回退到SystemNavigator.pop()
            SystemNavigator.pop();
          }
        }
      },
      child: Stack(
        children: [
          Scaffold(
            // 【核心修复】：恢复为 true。让系统正常缩放页面，从而解决录入页键盘上方的白色区域问题
            resizeToAvoidBottomInset: true,
            body: IndexedStack(
              index: _currentIndex,
              children: [
                RecordTab(
                  key: _recordTabKey,
                  processor: _processor,
                  dbHelper: _dbHelper,
                  onLoadingChanged: (show, {message}) {
                    if (show) {
                      showGlobalLoading(message: message);
                    } else {
                      hideGlobalLoading();
                    }
                  },
                  // 按钮栏在 main.dart 外层 Stack，RecordTab 状态变化（录音/处理/搬家）需通知此处重建
                  onStateChanged: () => setState(() {}),
                ),
                // [修改] 传入回调，让列表页状态变化时，外层也跟着刷新按钮 UI
                ListTab(
                  key: _listTabKey,
                  dbHelper: _dbHelper,
                  onStateChanged: () => setState(() {}),
                ),
                // [修改] 传入回调，让日记页状态变化时，外层也跟着刷新
                DiaryTab(
                  key: _diaryTabKey,
                  dbHelper: _dbHelper,
                  processor: _processor,
                  onStateChanged: () => setState(() {}),
                  onLoadingChanged: (show, {message}) {
                    if (show) {
                      showGlobalLoading(message: message);
                    } else {
                      hideGlobalLoading();
                    }
                  },
                  // 日记页答案区"+N"点击 → 跳转 ListTab 并预填搜索词
                  onJumpToSearch: (keyword) {
                    setState(() => _currentIndex = 1); // 切换到 ListTab
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _listTabKey.currentState?.setSearchQuery(keyword);
                    });
                  },
                ),
                SettingsTab(processor: _processor, dbHelper: _dbHelper),
              ],
            ),
            bottomNavigationBar: Theme(
              data: Theme.of(context).copyWith(
                // 关闭点击水波纹效果，提升性能
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: BottomNavigationBar(
                currentIndex: _currentIndex,
                // 显式指定背景色：黑金主题下默认白色会与深色 scaffold 断裂
                // 4 套主题中 3 套浅色 cardBackground≈白，视觉无变化；黑金修复白底问题
                backgroundColor: ext.cardBackground,
                type: BottomNavigationBarType
                    .fixed, // [注意] 超过3个tab建议加上这个属性，防止图标乱动
                onTap: (index) {
                  // 先立即更新 UI，让底部导航栏响应更快
                  setState(() {
                    _currentIndex = index;
                  });

                  // 延迟执行各个 tab 的刷新方法，避免阻塞 UI
                  Future.microtask(() {
                    // 当切回录音页 (索引 0) 时，触发延迟初始化
                    if (index == 0) {
                      // 🆕 RecordTab: 不触发自动初始化
                      // 模型将在用户停止录音后加载
                      _recordTabKey.currentState
                          ?.initializeIfNeeded(); // 改为新的方法名
                    }
                    // 如果用户点击了"查询列表" (索引为 1)
                    if (index == 1) {
                      // 通过遥控器命令列表页：立刻刷新！
                      _listTabKey.currentState?.refreshItems();
                    }
                    if (index == 2) {
                      // 🆕 DiaryTab: 不触发自动初始化
                      // 模型将在用户停止录音后加载
                      _diaryTabKey.currentState?.refreshEngine(); // 已修改为支持按需加载
                      _diaryTabKey.currentState?.refreshList();
                    }
                  });
                },
                selectedItemColor: ext.primary, // 原 Colors.blueAccent
                unselectedItemColor: ext.textHint, // 原 Colors.grey 未选中颜色
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.mic), label: "存物品"),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.search),
                    label: "查物品",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.book),
                    label: "随手记",
                  ), // [新增]

                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: "设置",
                  ),
                ],
              ),
            ),
          ),
          // 【悬浮语音按钮】：因为在外层 Stack 中，它会钉在物理底部，键盘弹起时会被覆盖而不会飞起
          if (_currentIndex == 2) _buildFloatingDiaryButton(),
          // 【物品列表页浮动按钮】：与日记页同款外层 Stack 模式，键盘弹起不上浮
          if (_currentIndex == 1) _buildFloatingListButton(),
          // 【录入页钉底按钮栏】：在外层 Stack 才不受键盘挤压
          if (_currentIndex == 0) _buildRecordBottomBar(),
          // 闹钟响铃横幅
          if (_isAlarmRinging) _buildAlarmRingingBanner(),
          // 全局模糊loading遮罩
          if (_showGlobalLoading) BlurLoadingOverlay(message: _loadingMessage),
        ],
      ),
    );
  }

  /// 闹钟响铃时顶部显示的红色停止横幅
  Widget _buildAlarmRingingBanner() {
    // ⚠️ 本横幅颜色未迁移到 AppThemeExtension：
    // Colors.redAccent / Colors.red.shade700 是警示红，语义与 fabRecording（浮动按钮录音态）不同，
    // 当前 AppThemeExtension 无专门 dangerBackground 槽，强行复用会导致录音按钮联动变红。
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Material(
          color: Colors.redAccent,
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.alarm, color: Colors.white),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '闹钟响铃中...',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await _platform.invokeMethod('stopAlarmRingtone');
                    } catch (e) {
                      log('⚠️ 停止闹钟失败: $e');
                    }
                    if (mounted) {
                      setState(() => _isAlarmRinging = false);
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.red.shade700,
                  ),
                  child: const Text('停止'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ⚠️ 【日记页浮动按钮的唯一控制点】
  // 按钮颜色/启用状态在此控制，diary_tab.dart 中的 btnColor/onBtnPressed 是 unused 变量
  // 上下游：state.isReady 由 diary_tab.initEngine() 设置
  //         RecognizerSingleton.hasModel 由 recognizer_singleton 静态管理
  //         切换 tab 时 diary_tab.refreshEngine() 会刷新状态并触发此处重建
  Widget _buildFloatingDiaryButton() {
    final state = _diaryTabKey.currentState;
    if (state == null) return const SizedBox.shrink();

    final ext = AppThemeExtension.of(context);

    // 颜色和图标逻辑
    Color btnColor = ext.fabReady; // 原 Colors.teal
    Widget btnChild = Icon(
      Icons.mic,
      color: Colors.white,
      size: 46,
    ); // 原 Colors.white

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮
      btnColor = ext.fabDisabled; // 原 Colors.grey
    } else if (state.isListening) {
      btnColor = ext.fabRecording; // 原 Colors.redAccent
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: Colors.white,
        size: 46,
      ); // 原 Colors.white
    } else if (state.isProcessing) {
      btnColor = ext.fabProcessing; // 原 Colors.orangeAccent
      btnChild = SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 3,
        ), // 原 Colors.white
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              // 锁定录音模式下，点击停止录音
              if (state.isLockedRecording) {
                state.stopListening();
              }
            },
            onLongPressStart: (_) {
              // 普通模式下，长按开始录音
              if (!state.isLockedRecording) {
                state.startListening();
              }
            },
            onLongPressEnd: (_) {
              // 普通模式下，松开停止录音
              if (!state.isLockedRecording) {
                state.stopListening();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: btnColor,
                // 🎨 黏土拟态阴影：顶部高光 + 底部深色阴影
                boxShadow: [
                  // 顶部高光阴影（模拟光源从上方）
                  BoxShadow(
                    color: ext.textOnPrimary.withValues(
                      alpha: 0.4,
                    ), // 原 Colors.white
                    offset: const Offset(-4, -4),
                    blurRadius: 8,
                  ),
                  // 底部深色阴影（模拟凹陷感）
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    offset: const Offset(4, 4),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Center(child: btnChild),
            ),
          ),
          const SizedBox(height: 14),
          // 用固定高度容器包裹文字：文字出现/消失都不改变 Column 总高度
          // 按钮位置完全稳定，不再抖动（修复"录音时按钮被撑高"问题）
          SizedBox(
            height: 22, // 中文字体 fontSize 16 行高约 22，预留固定空间
            child: Center(
              child: Text(
                state.isLockedRecording ? '点击停止' : state.statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  // 显式指定霞鹜文楷字体，避免在部分 widget 链路中 Roboto 回退
                  fontFamily: 'LXGWWenKaiMonoGBScreen',
                  fontSize: 16,
                  color: ext.textHint, // 原 Colors.black45
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ⚠️ 【物品列表页浮动按钮】完全仿 _buildFloatingDiaryButton 模式
  // 跟日记页的差异：
  //   1. 长按开始/松开停止（无锁定模式）
  //   2. 状态文本：录音中"松开停止"、处理中"识别中..."
  //   3. ListTab 只读 hasModel/isReady 判断按钮启用
  // 上下游：state.isReady/isListening/isProcessing 由 list_tab.dart 的 setState 流转
  //         ListTab.onStateChanged 回调触发本方法重建
  Widget _buildFloatingListButton() {
    final state = _listTabKey.currentState;
    if (state == null) return const SizedBox.shrink();

    final ext = AppThemeExtension.of(context);

    // 颜色和图标逻辑（仿日记页 main.dart:449-465）
    Color btnColor = ext.fabReady; // 默认青色
    Widget btnChild = Icon(Icons.mic, color: ext.textOnPrimary, size: 46);

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮
      btnColor = ext.fabDisabled;
    } else if (state.isListening) {
      // 录音中 → 红色
      btnColor = ext.fabRecording;
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: ext.textOnPrimary,
        size: 46,
      );
    } else if (state.isProcessing) {
      // 处理中 → 橙色 + 转圈
      btnColor = ext.fabProcessing;
      btnChild = SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(
          color: ext.textOnPrimary,
          strokeWidth: 3,
        ),
      );
    }

    // 状态文本（固定高度 22 容器避免抖动，仿日记页 main.dart:522-537）
    String statusText = '';
    if (state.isListening) {
      statusText = '松开停止';
    } else if (state.isProcessing) {
      statusText = '识别中...';
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            // 长按录音交互（无锁定模式，仿日记页简化版）
            onLongPressStart: (_) {
              if (state.isProcessing) return;
              state.startVoiceSearch();
            },
            onLongPressEnd: (_) {
              if (state.isProcessing) return;
              state.stopVoiceSearch();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: btnColor,
                // 🎨 黏土拟态阴影（仿日记页 main.dart:500-514）
                boxShadow: [
                  // 顶部高光阴影（模拟光源从上方）
                  BoxShadow(
                    color: ext.textOnPrimary.withValues(alpha: 0.4),
                    offset: const Offset(-4, -4),
                    blurRadius: 8,
                  ),
                  // 底部深色阴影（模拟凹陷感）
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    offset: const Offset(4, 4),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Center(child: btnChild),
            ),
          ),
          const SizedBox(height: 14),
          // 用固定高度容器包裹文字：文字出现/消失都不改变 Column 总高度（仿日记页）
          SizedBox(
            height: 22,
            child: Center(
              child: Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'LXGWWenKaiMonoGBScreen',
                  fontSize: 16,
                  color: ext.textHint,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ⚠️ 【录入页钉底按钮栏（录音 + 确认保存）】
  // 必须放在 main.dart 外层 Stack（Scaffold 之外），才不受 resizeToAvoidBottomInset 影响。
  // RecordTab 自己的 Stack 嵌在 IndexedStack(main.dart:281) 里会被键盘挤压，
  // 按钮放这里才能"键盘弹起原地不动、被覆盖不上浮"（用户已确认接受此行为）。
  // 仿 _buildFloatingListButton 模式。颜色状态机复现自 record_tab.dart 原非搬家逻辑。
  Widget _buildRecordBottomBar() {
    final state = _recordTabKey.currentState;
    if (state == null) return const SizedBox.shrink();
    // 搬家模式有自己的钉底「撤销最近」按钮，不渲染这组录音/保存按钮（否则两者重叠）
    if (state.isMoveMode) return const SizedBox.shrink();

    final ext = AppThemeExtension.of(context);

    // 颜色/图标状态机（复现 record_tab.dart 原非搬家模式染色）
    Color btnColor = ext.fabReady; // 原 Colors.teal
    Widget btnChild = Icon(
      Icons.mic,
      color: ext.textOnPrimary, // 原 Colors.white
      size: 55,
    );

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮（灰色）
      btnColor = ext.fabDisabled; // 原 Colors.grey
    } else if (state.isListening) {
      btnColor = ext.fabRecording; // 原 Colors.redAccent
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: ext.textOnPrimary,
        size: 55,
      );
    } else if (state.isProcessing) {
      btnColor = ext.fabProcessing; // 原 Colors.orangeAccent
      btnChild = SizedBox(
        width: 45,
        height: 45,
        child: CircularProgressIndicator(
          color: ext.textOnPrimary,
          strokeWidth: 3,
        ),
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      // ⚠️ 坐标系：按钮在 main.dart 外层 Stack，bottom 是距【屏幕物理底部】的距离，
      // 不是距 BottomNav 顶部。搬到外层 Stack（修键盘挤压）后，同样数值视觉低了约一个
      // BottomNav 高度（~80px）。155 ≈ 旧 record_tab 时代 bottom:75 的视觉（BottomNav 上方约 99px）。微调改这里。
      bottom: 155,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 状态文字（固定高度 22 容器防抖动，仿 main.dart 浮动按钮）
              SizedBox(
                height: 22,
                child: Center(
                  child: Text(
                    state.statusText,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: ext.textSecondary, // 原 Colors.black45
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 语音按钮（长按开始录音 / 松开停止）
                  GestureDetector(
                    onLongPressStart: (_) => state.startListening(),
                    onLongPressEnd: (_) => state.stopListening(),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: btnColor.withValues(alpha: 0.3),
                            blurRadius: 25,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 50,
                        backgroundColor: btnColor,
                        child: btnChild,
                      ),
                    ),
                  ),
                  // 确认保存按钮
                  SizedBox(
                    width: 140,
                    height: 100,
                    child: ElevatedButton(
                      onPressed: state.saveData,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ext.primary, // 原 Colors.teal
                        foregroundColor: ext.textOnPrimary, // 原 Colors.white
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        "确认保存",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 处理返回按钮事件
  Future<bool> _handleBackButtonPressed() async {
    final now = DateTime.now();

    if (_backButtonCount == 0) {
      // 第一次按返回键
      _backButtonCount = 1;
      _firstBackPressedTime = now;

      // 显示退出提示
      _showExitPrompt();

      // 等待2秒，如果在这期间没有再次按返回键，重置状态
      await Future.delayed(_exitPromptTimeout);
      if (_backButtonCount == 1) {
        _resetExitState();
      }
    } else {
      // 第二次按返回键，检查时间间隔
      if (_firstBackPressedTime != null &&
          now.difference(_firstBackPressedTime!) < _exitPromptTimeout) {
        // 时间间隔在2秒内，真正退出
        return true;
      } else {
        // 超过时间间隔，重新计时
        _resetExitState();
        return await _handleBackButtonPressed(); // 重新触发第一次提示
      }
    }

    return false; // 阻止默认的退出行为
  }

  // 重置退出状态
  void _resetExitState() {
    if (!mounted) return;
    setState(() {
      _backButtonCount = 0;
      _firstBackPressedTime = null;
    });
  }

  // 显示退出提示
  void _showExitPrompt() {
    final ext = AppThemeExtension.of(context);
    // 显示Snackbar提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: ext.textOnPrimary,
              size: 16,
            ), // 原 Colors.white
            const SizedBox(width: 8),
            const Text('再按一次退出应用', style: TextStyle(fontSize: 12)),
          ],
        ),
        duration: _exitPromptTimeout,
        backgroundColor: ext.textPrimary, // 原 Colors.black87
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(
          90,
          90,
          90,
          MediaQuery.of(context).padding.bottom + 180,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
