import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // LicenseRegistry / LicenseEntryWithLineBreaks（开放源代码许可页登记字体 OFL）
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'app_logger.dart';
import 'db_helper.dart';
import 'text_processor.dart';
import 'record_tab.dart';
import 'list_tab.dart';
import 'settings_tab.dart';
import 'diary_tab.dart';
import 'widgets/blur_loading_overlay.dart';
import 'widgets/diary_floating_button.dart';
import 'shortcut_manager.dart' as sm;
import 'recognizer_singleton.dart';
import 'splash_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_extension.dart';
import 'overlay/overlay_constants.dart';
import 'utils/alarm_ringing_notifier.dart';
// 保活悬浮窗入口 overlayMain：Dart 编译器只编译从 main() 可达的代码，
// 不 import 此文件 overlayMain 就不进 kernel，引擎报 "Could not resolve main entrypoint function"
import 'overlay/overlay_main.dart' as overlay_entry;

/// 悬浮窗引擎入口（根库转发）。
///
/// ⚠️ 原生层 DartEntrypoint(path, "overlayMain") 只在根库（main.dart 对应的库）里查找
/// 入口函数——定义在独立库里的 overlayMain 即使已进 kernel 也找不到，报
/// "Could not resolve main entrypoint function"（flutter_overlay_window 官方 README 同款做法）。
@pragma('vm:entry-point')
void overlayMain() => overlay_entry.overlayMain();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册霞鹜文楷字体的 OFL 协议到 LicenseRegistry，让设置→关于→「开放源代码许可」页
  // 能展示字体协议全文（showLicensePage 只自动收集 pub 依赖的 LICENSE，asset 字体需手动登记）。
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString(
      'assets/licenses/OFL-LXGWWenKai.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>[
      '霞鹜文楷 (LXGW WenKai Mono GB Screen)',
    ], ofl);
  });

  sherpa_onnx.initBindings();

  // 预读模型路径，使 hasModel 在模型未加载时也能正确判断
  await RecognizerSingleton.preloadModelPath();

  // 预读用户选择的主题（默认青兜底，找不到 ID 也回退到默认青）
  final prefs = await SharedPreferences.getInstance();
  final themeId = prefs.getString('selected_theme');
  final initialTheme = AppThemes.findById(themeId) ?? AppThemes.defaultTheme;
  // 初始化全局主题 notifier，AppRoot 内的 ValueListenableBuilder 会订阅它
  AppRoot.themeNotifier.value = initialTheme;

  // 预读用户选择的字号缩放（默认 1.0 标准；旧版本无此 key 回退 1.0）
  AppRoot.fontScaleNotifier.value = prefs.getDouble('font_size_scale') ?? 1.0;

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
///
/// 切换字号时只需：
/// ```dart
/// final prefs = await SharedPreferences.getInstance();
/// await prefs.setDouble('font_size_scale', scale);
/// AppRoot.fontScaleNotifier.value = scale; // 立即触发整树重建
/// ```
class AppRoot extends StatelessWidget {
  /// 全局主题状态——任何位置都能读写
  /// main() 启动时初始化为持久化的用户选择，默认青兜底
  static final ValueNotifier<AppThemeDefinition> themeNotifier =
      ValueNotifier<AppThemeDefinition>(AppThemes.defaultTheme);

  /// 全局字号缩放——任何位置都能读写
  /// main() 启动时初始化为持久化的用户选择，默认 1.0（标准）
  static final ValueNotifier<double> fontScaleNotifier =
      ValueNotifier<double>(1.0);

  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeDefinition>(
      valueListenable: themeNotifier,
      builder: (context, themeDef, _) {
        return ValueListenableBuilder<double>(
          valueListenable: fontScaleNotifier,
          builder: (context, fontScale, _) {
            return MaterialApp(
              title: '声物记',
              theme: themeDef.toThemeData(),
              // 强制中文本地化：UI 文案全 App 硬编码中文，日期转轮选择器
              //（悬浮窗闹钟 CalendarConfirmSheet 的 CupertinoDatePicker）等
              // 框架级文案跟随这里——不配则转轮显示英文月份/AM/PM
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              // 全局字号缩放：整树文本统一缩放（含硬编码 fontSize）。
              // 悬浮窗是独立 engine 独立 widget 树，不经过此 builder，不受影响。
              builder: (context, child) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(fontScale),
                  ),
                  child: child!,
                );
              },
              home: const SplashScreen(child: MainScaffold()),
              debugShowCheckedModeBanner: false,
            );
          },
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

  // 闹钟响铃状态（性能审查 Top5）：原生响铃开始/停止经通道推事件
  // （onAlarmRinging / onAlarmStopped，见 MainActivity.flutterChannel），
  // 冷启动从 SharedPreferences 一次性恢复——不再全局 2 秒轮询 prefs
  final AlarmRingingNotifier _alarmRinging = AlarmRingingNotifier();

  // 【关键】给列表页创建一个"遥控器" (Key)
  final GlobalKey<ListTabState> _listTabKey = GlobalKey<ListTabState>();
  // 1. 定义 RecordTab 的遥控器
  final GlobalKey<RecordTabState> _recordTabKey = GlobalKey<RecordTabState>();
  // [新增] 日记页的 Key
  final GlobalKey<DiaryTabState> _diaryTabKey = GlobalKey<DiaryTabState>();

  // 日记页浮动按钮（DiaryFloatingButton，widgets/diary_floating_button.dart）
  // 上滑手势的拖拽状态已下沉到该组件自有 State——拖拽帧只重建按钮子树，
  // 不再 MainScaffold 整页 setState（性能审查 Top6）

  // 【性能审查 Top6】三个外层浮动组件各自的状态刷新信号：
  // tab 状态翻转（录音/处理/搬家等）经 onStateChanged 递增对应计数，
  // 只重建对应浮动组件（ValueListenableBuilder 包裹），不再 MainScaffold
  // 整页 setState（IndexedStack 四页 build 全部陪跑）
  final ValueNotifier<int> _recordBarTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _listButtonTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _diaryButtonTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _processor.loadConfigs();

    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);

    // 初始化快捷方式管理器（用于动态快捷方式）
    sm.ShortcutManager().initialize(_handleQuickRecord);

    // 闹钟响铃：冷启动一次性恢复（进程被杀期间闹钟触发过、用户未点通知
    // 直接打开 APP 的场景，无引擎可推事件，只能读原生写入的 prefs 标志）
    unawaited(_alarmRinging.restoreOnce());

    // 监听原生层的快捷方式启动事件（用于静态快捷方式和冷启动）
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'onShortcutLaunch') {
        final shortcutType = call.arguments as String;
        if (shortcutType == 'quick_record') {
          // 🔥 不在这里设置标志，让 _handleQuickRecord() 自己处理
          _handleQuickRecord();
        } else if (shortcutType == 'quick_text_note') {
          _handleQuickTextNote();
        } else if (shortcutType == 'grant_calendar') {
          _handleGrantCalendarPermission();
        }
      } else if (call.method == 'onReceiveSharedText') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final text = args['text'] as String;
        final source = args['source'] as String?;
        await _handleReceiveSharedText(text, source: source);
      } else if (call.method == 'showOverlay') {
        // 原生层（如音量键长按）请求显示悬浮窗，显示后把主 App 退到后台
        await _showFloatingOverlay(moveToBack: true);
      } else if (call.method == 'onAlarmRinging' ||
          call.method == 'onAlarmStopped') {
        // 闹钟响铃开始/停止事件（原生 AlarmReceiver 推送，见
        // MainActivity.flutterChannel）——替代旧 2 秒轮询，响铃即时显隐横幅
        _alarmRinging.handleNativeEvent(call.method);
      }
    });
  }

  @override
  void dispose() {
    _alarmRinging.dispose();
    _recordBarTick.dispose();
    _listButtonTick.dispose();
    _diaryButtonTick.dispose();
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

  /// 处理悬浮窗闹钟的日历权限请求（悬浮窗无 Activity 不能自己弹授权框，
  /// 由无障碍 Service 拉起主 App 并携带 type=grant_calendar extra 路由到此）。
  /// 日历 + 通知权限一次请求齐——悬浮窗闹钟两项都用得上
  Future<void> _handleGrantCalendarPermission() async {
    log('🔑 [Permission] 主 App 被悬浮窗拉起：请求日历权限');
    final calendarStatus = await Permission.calendarFullAccess.request();
    // 通知权限失败不阻塞（只影响响铃，日历事件本身已可用）
    await Permission.notification.request();
    if (!mounted) return;
    final granted = calendarStatus.isGranted;
    log('🔑 [Permission] 日历权限请求结果: $calendarStatus');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? '日历权限已授予，可在悬浮窗中添加日历提醒了'
              : '日历权限被拒绝，悬浮窗闹钟将无法添加日程',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 处理系统分享菜单传入的文本
  Future<void> _handleReceiveSharedText(String text, {String? source}) async {
    // 🔍 诊断分享来源：确认原生层经 MethodChannel 传来的 source 是否为 null
    // （若这里 source=null，问题在原生层 getShareSource；若 source 有值但日记没前缀，问题在 diary_tab 拼接）
    log(
      '📝 [Share] MainScaffold 收到分享, source="$source", source类型=${source.runtimeType}, text长度=${text.length}',
    );
    // 切换到日记页（索引2）
    _currentIndex = 2;
    setState(() {});

    final diaryState = _diaryTabKey.currentState;
    if (diaryState == null) {
      log('📝 [Share] ⚠️ diaryState 为 null，分享文本无法保存');
      return;
    }
    await diaryState.saveSharedTextNote(text, source: source);
  }

  /// 显示系统级悬浮窗（闪念胶囊）
  ///
  /// 首次调用会检查/请求 `SYSTEM_ALERT_WINDOW` 权限，然后以收起态把手显示在屏幕右侧。
  Future<void> _showFloatingOverlay({bool moveToBack = false}) async {
    try {
      // 1. 检查并请求悬浮窗权限
      if (!await FlutterOverlayWindow.isPermissionGranted()) {
        print('🔒 [Overlay] 悬浮窗权限未授予，请求权限');
        final granted = await FlutterOverlayWindow.requestPermission();
        if (granted != true) {
          print('❌ [Overlay] 用户拒绝悬浮窗权限');
          return;
        }
      }

      // 2. 如果已经激活，先关闭再重新显示（避免重复叠加）
      if (await FlutterOverlayWindow.isActive()) {
        print('🔄 [Overlay] 悬浮窗已存在，先关闭');
        await FlutterOverlayWindow.closeOverlay();
      }

      // 3. 显示收起态把手
      print('🪟 [Overlay] 显示悬浮窗把手');
      await FlutterOverlayWindow.showOverlay(
        alignment: OverlayAlignment.centerRight,
        positionGravity: PositionGravity.right,
        height: OverlayConstants.handleHeight,
        width: OverlayConstants.handleWidth,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: '声物记悬浮窗',
        overlayContent: '点击边缘把手展开随手记',
        enableDrag: false,
      );

      // 4. 触发场景（音量键）需要把主 App 退到后台，不遮挡悬浮窗
      // 🔍 方案二调试：暂时不移到后台，验证小米是否允许在 App 前台显示悬浮窗
      if (moveToBack) {
        print('🔙 [Overlay] 调试模式：跳过 moveTaskToBack，主 App 留在前台');
        // await _platform.invokeMethod('moveTaskToBack');
      }
    } catch (e, stack) {
      print('❌ [Overlay] 显示悬浮窗失败: $e');
      log('❌ [Overlay] 显示悬浮窗失败:', e, stack);
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
                  // 按钮栏在 main.dart 外层 Stack，RecordTab 状态变化（录音/处理/搬家）→
                  // tick 递增只重建外层按钮栏，不再整页重建（性能审查 Top6）
                  onStateChanged: () => _recordBarTick.value++,
                ),
                // [修改] 传入回调，让列表页状态变化时，外层也跟着刷新按钮 UI
                ListTab(
                  key: _listTabKey,
                  dbHelper: _dbHelper,
                  onStateChanged: () => _listButtonTick.value++,
                ),
                // [修改] 传入回调，让日记页状态变化时，外层浮动按钮跟着刷新
                DiaryTab(
                  key: _diaryTabKey,
                  dbHelper: _dbHelper,
                  processor: _processor,
                  onStateChanged: () => _diaryButtonTick.value++,
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
                selectedItemColor: ext.primary,
                unselectedItemColor: ext.textHint,
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
          // 【悬浮语音按钮】：因为在外层 Stack 中，它会钉在物理底部，键盘弹起时会被覆盖而不会飞起。
          // ValueListenableBuilder：DiaryTab 状态翻转（_diaryButtonTick）只重建按钮，
          // 不整页 setState；拖拽状态在 DiaryFloatingButton 自有 State（Top6）
          if (_currentIndex == 2)
            ValueListenableBuilder<int>(
              valueListenable: _diaryButtonTick,
              builder: (context, _, _) {
                // ⚠️ 【日记页浮动按钮的唯一控制点】
                // 按钮颜色/启用状态在此读取 DiaryTabState 传入（三态 + 模型存在
                // 与否），diary_tab.dart 中的 btnColor/onBtnPressed 是 unused 变量。
                // 上下游：state.isReady 由 diary_tab.initEngine() 设置；
                // RecognizerSingleton.hasModel 由 recognizer_singleton 静态管理；
                // 切换 tab 时 diary_tab.refreshEngine() 会刷新状态并经
                // onStateChanged → tick 触发此处重建
                final state = _diaryTabKey.currentState;
                if (state == null) return const SizedBox.shrink();
                return DiaryFloatingButton(
                  modelAvailable: RecognizerSingleton.hasModel,
                  isReady: state.isReady,
                  isListening: state.isListening,
                  isProcessing: state.isProcessing,
                  isLockedRecording: state.isLockedRecording,
                  statusText: state.statusText,
                  onStartListening: () => state.startListening(),
                  onStopListening: state.stopListening,
                  onNewTextNote: () => state.startNewTextNote(),
                );
              },
            ),
          // 【物品列表页浮动按钮】：与日记页同款外层 Stack 模式，键盘弹起不上浮；
          // ListTab 状态翻转（_listButtonTick）只重建按钮不整页 setState（Top6）
          if (_currentIndex == 1)
            ValueListenableBuilder<int>(
              valueListenable: _listButtonTick,
              builder: (context, _, _) => _buildFloatingListButton(),
            ),
          // 【录入页钉底按钮栏】：在外层 Stack 才不受键盘挤压；
          // RecordTab 状态翻转（_recordBarTick，含搬家模式开关）只重建按钮栏（Top6）
          if (_currentIndex == 0)
            ValueListenableBuilder<int>(
              valueListenable: _recordBarTick,
              builder: (context, _, _) => _buildRecordBottomBar(),
            ),
          // 闹钟响铃横幅：ListenableBuilder 局部订阅 _alarmRinging，
          // 响铃开始/停止只重建横幅自身，不再依赖整页 setState
          ListenableBuilder(
            listenable: _alarmRinging,
            builder: (context, _) => _alarmRinging.ringing
                ? _buildAlarmRingingBanner()
                : const SizedBox.shrink(),
          ),
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
                    // 乐观收起横幅；原生 stopAlarmCompletely 随后推送的
                    // onAlarmStopped 为同值幂等
                    _alarmRinging.markStopped();
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

  // ⚠️ 【物品列表页浮动按钮】同 widgets/diary_floating_button.dart（日记页）的外层 Stack 模式
  // 跟日记页的差异：
  //   1. 长按开始/松开停止（无锁定模式）
  //   2. 状态文本：录音中"松开停止"、处理中"识别中..."
  //   3. ListTab 只读 hasModel/isReady 判断按钮启用
  // 上下游：state.isReady/isListening/isProcessing 由 list_tab.dart 的 setState 流转
  //         ListTab.onStateChanged → _listButtonTick 递增触发本方法重建（Top6）
  Widget _buildFloatingListButton() {
    final state = _listTabKey.currentState;
    if (state == null) return const SizedBox.shrink();

    final ext = AppThemeExtension.of(context);

    // 颜色和图标逻辑（仿日记页浮动按钮）
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

    // 状态文本（固定高度 22 容器避免抖动，仿日记页）
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
                // 🎨 黏土拟态阴影（仿日记页）
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
  // 必须放在 main.dart 外层 Stack（Scaffold 之外），才不受 resizeToAvoidBottomInset 影响；
  // 按钮放这里才能"键盘弹起原地不动、被覆盖不上浮"（用户已确认接受此行为）。
  // 仿 _buildFloatingListButton 模式。颜色状态机复现自 record_tab.dart 原非搬家逻辑。
  Widget _buildRecordBottomBar() {
    final state = _recordTabKey.currentState;
    if (state == null) return const SizedBox.shrink();
    // 搬家模式有自己的钉底「撤销最近」按钮，不渲染这组录音/保存按钮（否则两者重叠）
    if (state.isMoveMode) return const SizedBox.shrink();

    final ext = AppThemeExtension.of(context);

    // 颜色/图标状态机（复现 record_tab.dart 原非搬家模式染色）
    Color btnColor = ext.fabReady;
    Widget btnChild = Icon(
      Icons.mic,
      color: ext.textOnPrimary,
      size: 55,
    );

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮（灰色）
      btnColor = ext.fabDisabled;
    } else if (state.isListening) {
      btnColor = ext.fabRecording;
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: ext.textOnPrimary,
        size: 55,
      );
    } else if (state.isProcessing) {
      btnColor = ext.fabProcessing;
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
                      color: ext.textSecondary,
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
                        backgroundColor: ext.primary,
                        foregroundColor: ext.textOnPrimary,
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
            ),
            const SizedBox(width: 8),
            const Text('再按一次退出应用', style: TextStyle(fontSize: 12)),
          ],
        ),
        duration: _exitPromptTimeout,
        backgroundColor: ext.textPrimary,
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
