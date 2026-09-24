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
import 'widgets/neu_widgets.dart';
import 'shortcut_manager.dart' as sm;
import 'recognizer_singleton.dart';
import 'splash_screen.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_extension.dart';
import 'theme/custom_theme.dart';
import 'overlay/overlay_constants.dart';
import 'utils/alarm_ringing_notifier.dart';
import 'utils/pro_gate.dart';
import 'utils/tab_visibility.dart';
import 'web_server/diary_server_controller.dart';
import 'web_server/diary_web_server.dart';
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

  // 预读用户选择的主题（预设 findById；'custom' 按保存的配置现建自定义主题，
  // 坏配置/找不到 ID 都回退默认青）
  final prefs = await SharedPreferences.getInstance();
  final themeId = prefs.getString('selected_theme');
  var initialTheme = await loadThemeById(themeId) ?? AppThemes.defaultTheme;
  // Pro 主题门禁（试用过期/未解锁）：启动回退默认青并写回 prefs（用户拍板
  // "下次启动回退"——当次会话不强行中断，悬浮窗等按键门禁则即时判断），
  // 回退后 MainScaffold 首帧 SnackBar 提示一次
  if (initialTheme.isPro && !ProGate.isProActiveWithPrefs(prefs)) {
    log('Pro 主题「${initialTheme.name}」已失效（试用过期/未解锁），启动回退默认青');
    await prefs.setString('selected_theme', AppThemes.defaultTheme.id);
    initialTheme = AppThemes.defaultTheme;
    MainScaffold.showProExpireNotice = true;
  }
  // 初始化全局主题 notifier，AppRoot 内的 ValueListenableBuilder 会订阅它
  AppRoot.themeNotifier.value = initialTheme;

  // 预读用户选择的字号缩放（默认 1.0 中档；旧版本无此 key 回退 1.0）
  AppRoot.fontScaleNotifier.value = prefs.getDouble('font_size_scale') ?? 1.0;

  // 预读主界面 Tab 可见性（设置页「功能页面」两个隐藏开关，重启生效——
  // MainScaffold 按 visibleTabStack 装配 IndexedStack/底部导航，进程内不变）
  AppRoot.recordTabHidden = prefs.getBool(prefKeyRecordTabHidden) ?? false;
  AppRoot.listTabHidden = prefs.getBool(prefKeyListTabHidden) ?? false;

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
  static final ValueNotifier<double> fontScaleNotifier = ValueNotifier<double>(
    1.0,
  );

  /// 主界面 Tab 可见性（设置页「功能页面」两个隐藏开关；main() 启动时预读，
  /// 默认 false=显示。同 themeNotifier 的「启动一次预读」模式，重启生效）
  static bool recordTabHidden = false;
  static bool listTabHidden = false;

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
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(fontScale)),
                  child: child!,
                );
              },
              home: SplashScreen(
                child: MainScaffold(
                  recordTabHidden: recordTabHidden,
                  listTabHidden: listTabHidden,
                ),
              ),
              debugShowCheckedModeBanner: false,
            );
          },
        );
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  /// Pro 试用过期启动回退提示（main() 检测到 Pro 主题失效回退默认青时置位，
  /// 本 Scaffold initState 首帧 SnackBar 提示一次后清零）
  static bool showProExpireNotice = false;

  /// 存物品页隐藏开关（设置页「功能页面」，main() 预读后传入；默认 false=显示。
  /// 重启生效：进程内恒定，Tab 装配在构造时一次定型）
  final bool recordTabHidden;

  /// 查物品页隐藏开关（同上）
  final bool listTabHidden;

  /// 可见 Tab 语义索引栈（IndexedStack children 与底部导航 items 按此装配；
  /// 语义索引定义见 utils/tab_visibility.dart）
  final List<int> _tabStack;

  // 非 const 构造：初始化列表要调用 visibleTabStack() 推导可见栈（普通函数
  // 不满足 const 构造的常量表达式要求）
  MainScaffold({
    super.key,
    this.recordTabHidden = false,
    this.listTabHidden = false,
  }) : _tabStack = visibleTabStack(
         recordTabHidden: recordTabHidden,
         listTabHidden: listTabHidden,
       );

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  // 当前 Tab 用【语义索引】（tab_visibility.dart 的 tabIndex* 常量），不是
  // IndexedStack 显示下标——隐藏页不挂载后两者不等，显示下标一律经
  // _tabStack.indexOf 换算；快捷方式/分享/悬浮窗等入口写的 2（随手记）
  // 不受隐藏影响，该页不可隐藏
  int _currentIndex = tabIndexRecord;
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

  /// 设置页：切回该 tab 时刷新云端同步入口行摘要（数据可能在其他 tab 变更，
  /// 待同步态需重算，见 SettingsTabState.refreshCloudSyncSummary）
  final GlobalKey<SettingsTabState> _settingsTabKey =
      GlobalKey<SettingsTabState>();

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
    // 初始落点=第一个可见 Tab（两页物品页都隐藏时落在随手记）
    _currentIndex = widget._tabStack.first;
    _processor.loadConfigs();

    // Pro 试用过期启动回退提示：main() 置位，首帧后提示一次（只提示不阻断）
    if (MainScaffold.showProExpireNotice) {
      MainScaffold.showProExpireNotice = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pro 试用已结束，已切回默认主题'),
            duration: Duration(seconds: 3),
          ),
        );
      });
    }

    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);

    // 初始化快捷方式管理器（用于动态快捷方式）
    sm.ShortcutManager().initialize(_handleQuickRecord);

    // 闹钟响铃：冷启动一次性恢复（进程被杀期间闹钟触发过、用户未点通知
    // 直接打开 APP 的场景，无引擎可推事件，只能读原生写入的 prefs 标志）
    unawaited(_alarmRinging.restoreOnce());

    // 电脑访问服务：上次开启过则自动恢复（内部延迟 1.5s 避开启动热路径，
    // 前台保活服务 + HTTP 固定端口 9527 都由 controller 编排）
    unawaited(DiaryServerController.instance.autoStartIfEnabled());
    // 电脑端（浏览器）增删改日记 → 主 App 日记页列表重查：
    // 服务层写库发生在本 isolate（main.dart 可直达 GlobalKey），手机侧 UI
    // 即时反映电脑的改动；悬浮窗 engine 侧感知走 DiarySyncBridge 计数桥
    DiaryWebServer.instance.remoteMutationTick.addListener(
      _onRemoteDiaryMutation,
    );

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
        } else if (shortcutType == 'open_diary') {
          _handleOpenDiaryPage();
        }
      } else if (call.method == 'onReceiveSharedText') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final text = args['text'] as String;
        final source = args['source'] as String?;
        await _handleReceiveSharedText(text, source: source);
      } else if (call.method == 'showOverlay') {
        // 原生层（如音量键长按）请求显示悬浮窗，显示后把主 App 退到后台
        await _showFloatingOverlay(moveToBack: true);
      } else if (call.method == 'noteUnlockResult') {
        // 笔记解锁认证结果（原生 NoteUnlockCoordinator → flutterChannel）：
        // 成功续期解锁会话并刷新打码；失败静默（用户取消）或原生已 Toast
        // （无锁屏凭据场景）
        final args = call.arguments;
        final success = args is Map && args['success'] == true;
        final reason = args is Map ? (args['reason'] as String? ?? '') : '';
        await _diaryTabKey.currentState?.onNoteUnlockResult(success, reason);
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
    DiaryWebServer.instance.remoteMutationTick.removeListener(
      _onRemoteDiaryMutation,
    );
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

  /// 弹掉盖在 MainScaffold 上的推入路由（设置二级页、对话框）。
  ///
  /// 外部入口（音量键快捷方式/系统分享/悬浮窗按钮）强切 IndexedStack 的 tab
  /// 对 Navigator 路由栈不可见：二级页是 Navigator.push 的 MaterialPageRoute，
  /// 盖在整棵 MainScaffold 之上，底下切 tab 用户看不到。真机确诊 2026-09-16：
  /// 设置二级页上触发快速录音，录音正常启动但 UI 停在二级页，左滑返回才露出
  /// 已切好的日记页。无推入路由时 popUntil(isFirst) 为 no-op，无副作用
  void _popOverlaysToRoot() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// 处理快速录音快捷方式
  Future<void> _handleQuickRecord() async {
    // 🔥 防止重复触发：立即设置标志（在方法开始时）
    if (_hasHandledShortcutLaunch) {
      log('🔑 [QuickRecord] 防重复标志未重置，忽略重复调用');
      return;
    }
    _hasHandledShortcutLaunch = true;

    final diaryState = _diaryTabKey.currentState;
    log(
      '🔑 [QuickRecord] 触发: 当前tab=$_currentIndex, diaryState=${diaryState != null}, isListening=${diaryState?.isListening}',
    );

    // 如果正在录音，停止录音（长按音量键切换逻辑）
    if (diaryState != null && diaryState.isListening) {
      log('🔑 快捷录音：检测到正在录音，执行停止');
      diaryState.stopListening();
      return;
    }

    // 切换到日记页（索引2），弹掉盖在上的二级页/对话框（IndexedStack 切 tab
    // 对路由栈不可见，不弹的话用户看到的还是二级页）
    _currentIndex = tabIndexDiary;
    _popOverlaysToRoot();

    // 刷新UI以切换页面
    setState(() {});

    // 🔍 真机诊断（用户反馈快速录音后未跳日记页）：链路日志证明 setState
    // 必然执行但用户看不到切换。首帧回包验证显示下标——-1 = 语义索引不在
    // 可见栈（切页失效）；正常值 = Dart 侧已切，问题在显示层（锁屏遮挡/
    // MIUI 后台弹出权限等），下次复测日志可直接区分两种情况
    WidgetsBinding.instance.addPostFrameCallback((_) {
      log(
        '🔑 [QuickRecord] 切页后首帧: 显示下标=${widget._tabStack.indexOf(_currentIndex)}, 可见栈=${widget._tabStack}',
      );
    });

    // 确保引擎状态已同步（快捷方式进入时 DiaryTab 的 isReady 可能未同步）
    if (diaryState != null) {
      await diaryState.refreshEngine();
      await diaryState.startListening(lockedMode: true);
    } else {
      log('🔑 [QuickRecord] ⚠️ diaryState 为 null：只切页未开录音');
    }
  }

  /// 处理双击音量键新建文本笔记
  Future<void> _handleQuickTextNote() async {
    if (_hasHandledShortcutLaunch) {
      log('快捷方式已处理，忽略重复调用');
      return;
    }
    _hasHandledShortcutLaunch = true;

    // 切换到日记页（索引2），弹掉盖在上的二级页/对话框
    _currentIndex = tabIndexDiary;
    _popOverlaysToRoot();
    setState(() {});

    final diaryState = _diaryTabKey.currentState;
    if (diaryState != null) {
      await diaryState.startNewTextNote();
    }
  }

  /// 处理悬浮窗「打开随手记」按钮（悬浮窗 header → 原生 launcher intent
  /// 带 type=open_diary extra → MainActivity extractShortcutType 路由到此）：
  /// 切到日记页（索引 2，与底部导航「随手记」同页）。不加防重复标志：
  /// 切 tab 幂等，重复 intent 无副作用（与 quick_record 的"只准触发一次"
  /// 语义不同）
  void _handleOpenDiaryPage() {
    log('📖 [Shortcut] 悬浮窗跳转随手记（日记页）');
    // 先弹二级页再切 tab：与快速录音同因（真机确诊 2026-09-16）
    _popOverlaysToRoot();
    // 先切 tab 再延迟刷新：底部导航 onTap 切到索引 2 的同款节奏——
    // 悬浮窗侧的增删改经 DiarySyncBridge 计数桥写库，列表须重查才可见
    setState(() => _currentIndex = tabIndexDiary);
    Future.microtask(() {
      _diaryTabKey.currentState?.refreshEngine();
      _diaryTabKey.currentState?.refreshList();
    });
  }

  /// 电脑端（浏览器）增删改了日记：日记页列表重查（IndexedStack 常驻，
  /// 不在当前 tab 也能安全刷新）。与 _handleOpenDiaryPage 的微任务节奏不同：
  /// 这里已是响应异步写库完成后的回调，直接刷即可
  void _onRemoteDiaryMutation() {
    log('💻 [WebServer] 电脑端修改了日记，刷新日记页列表');
    _diaryTabKey.currentState?.refreshList();
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
          granted ? '日历权限已授予，可在悬浮窗中添加日历提醒了' : '日历权限被拒绝，悬浮窗闹钟将无法添加日程',
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
    // 切换到日记页（索引2），弹掉盖在上的二级页/对话框
    _currentIndex = tabIndexDiary;
    _popOverlaysToRoot();
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
              // 显示下标=语义索引在可见栈中的位置（隐藏页不挂载后两者不等）
              index: widget._tabStack.indexOf(_currentIndex),
              children: [
                for (final semantic in widget._tabStack) _buildTabPage(
                  semantic,
                ),
              ],
            ),
            bottomNavigationBar: AppThemeExtension.of(context).isNeumorphic
                ? _buildNeuBottomNav()
                : Theme(
              data: Theme.of(context).copyWith(
                // 关闭点击水波纹效果，提升性能
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: BottomNavigationBar(
                currentIndex: widget._tabStack.indexOf(_currentIndex),
                // 显式指定背景色：黑金主题下默认白色会与深色 scaffold 断裂
                // 4 套主题中 3 套浅色 cardBackground≈白，视觉无变化；黑金修复白底问题
                backgroundColor: ext.cardBackground,
                type: BottomNavigationBarType
                    .fixed, // [注意] 超过3个tab建议加上这个属性，防止图标乱动
                onTap: _onNavTap,
                selectedItemColor: ext.primary,
                unselectedItemColor: ext.textHint,
                // 按可见栈装配（隐藏页不出现在导航上，与 IndexedStack 顺序一致）
                items: [
                  for (final semantic in widget._tabStack) _navItem(semantic),
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
                  isSilenceCountdown: state.isSilenceCountdown,
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

  /// 底部导航点击（显示下标 → 语义索引；隐藏页不挂载后两者不等）
  ///
  /// 从 BottomNavigationBar onTap 内联逻辑抽出：拟物主题的自绘导航
  /// （_buildNeuBottomNav）与旧主题的 BottomNavigationBar 共用同一套切换行为。
  void _onNavTap(int displayIndex) {
    final semantic = widget._tabStack[displayIndex];
    // 先立即更新 UI，让底部导航栏响应更快
    setState(() {
      _currentIndex = semantic;
    });

    // 延迟执行各个 tab 的刷新方法，避免阻塞 UI
    Future.microtask(() {
      // 当切回录音页（语义 0）时，触发延迟初始化
      if (semantic == tabIndexRecord) {
        // 🆕 RecordTab: 不触发自动初始化
        // 模型将在用户停止录音后加载
        _recordTabKey.currentState?.initializeIfNeeded(); // 改为新的方法名
      }
      // 如果用户点击了"查询列表"（语义 1）
      if (semantic == tabIndexList) {
        // 通过遥控器命令列表页：立刻刷新！
        _listTabKey.currentState?.refreshItems();
      }
      if (semantic == tabIndexDiary) {
        // 🆕 DiaryTab: 不触发自动初始化
        // 模型将在用户停止录音后加载
        _diaryTabKey.currentState?.refreshEngine(); // 已修改为支持按需加载
        _diaryTabKey.currentState?.refreshList();
      }
      if (semantic == tabIndexSettings) {
        // 数据可能在其他 tab 变更（记日记/存物品/悬浮窗速记），
        // 切回设置页重算云端同步入口行的待同步态
        _settingsTabKey.currentState?.refreshCloudSyncSummary();
      }
    });
  }

  /// 拟物底部导航：与页面同色，选中项为凹陷坑 + 品牌青（预览拍板样式）
  ///
  /// 仅新拟物主题走此分支；切换行为与 BottomNavigationBar 完全一致（_onNavTap），
  /// 可见栈装配（隐藏页不出现在导航上）也共用 _tabStack，逻辑零分叉。
  Widget _buildNeuBottomNav() {
    final ext = AppThemeExtension.of(context);
    final displayIndex = widget._tabStack.indexOf(_currentIndex);
    return Container(
      color: ext.cardBackground,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < widget._tabStack.length; i++)
                Expanded(
                  child: _buildNeuNavItem(
                    widget._tabStack[i],
                    selected: i == displayIndex,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 拟物导航单项：icon 装在 44×28 容器里（选中时凹陷），下方 label
  Widget _buildNeuNavItem(int semantic, {required bool selected}) {
    final ext = AppThemeExtension.of(context);
    final item = _navItem(semantic);
    final color = selected ? ext.primaryDark : ext.textHint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onNavTap(widget._tabStack.indexOf(semantic)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 44,
            height: 28,
          // 选中=NeuInset 凹陷（双轴渐变晕影，与开关/输入框同款，
          // 2026-09-19 统一，替代对角渐变 neuInsetDecoration——顶/底边
          // 整条没阴影的旧观感）
          child: selected
              ? NeuInset(
                  radius: 14,
                  child: Center(
                    child: Icon(_navIconData(semantic), color: color, size: 20),
                  ),
                )
              : Center(
                  child: Icon(_navIconData(semantic), color: color, size: 20),
                ),
          ),
          const SizedBox(height: 3),
          Text(
            item.label!,
            style: TextStyle(
              fontSize: 10.5,
              color: color,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  /// 拟物导航图标数据（_navItem 返回 Icon 对象不便取 IconData，此处平行映射；
  /// 与 _navItem 的 switch 保持同序，新增 tab 时两处都要改）
  IconData _navIconData(int semantic) => switch (semantic) {
    tabIndexRecord => Icons.mic,
    tabIndexList => Icons.search,
    tabIndexDiary => Icons.book,
    tabIndexSettings => Icons.settings,
    _ => throw ArgumentError('未知的 Tab 语义索引: $semantic'),
  };

  /// 底部导航项文案/图标（语义索引 → 项；随可见栈装配顺序渲染）
  BottomNavigationBarItem _navItem(int semantic) => switch (semantic) {
    tabIndexRecord => const BottomNavigationBarItem(
      icon: Icon(Icons.mic),
      label: "存物品",
    ),
    tabIndexList => const BottomNavigationBarItem(
      icon: Icon(Icons.search),
      label: "查物品",
    ),
    tabIndexDiary => const BottomNavigationBarItem(
      icon: Icon(Icons.book),
      label: "随手记",
    ),
    tabIndexSettings => const BottomNavigationBarItem(
      icon: Icon(Icons.settings),
      label: "设置",
    ),
    _ => throw ArgumentError('未知的 Tab 语义索引: $semantic'),
  };

  /// 按语义索引构建 Tab 页（可见栈装配用；隐藏页不进栈，对应 GlobalKey
  /// 无 state——所有 _recordTabKey/_listTabKey 读取点已 null 安全，
  /// 或按可见栈分发后本就不可达）
  Widget _buildTabPage(int semantic) {
    switch (semantic) {
      case tabIndexRecord:
        return RecordTab(
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
        );
      case tabIndexList:
        // 传入回调，让列表页状态变化时，外层也跟着刷新按钮 UI
        return ListTab(
          key: _listTabKey,
          dbHelper: _dbHelper,
          onStateChanged: () => _listButtonTick.value++,
        );
      case tabIndexDiary:
        // 传入回调，让日记页状态变化时，外层浮动按钮跟着刷新
        return DiaryTab(
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
          // 日记页答案区"+N"点击 → 跳转 ListTab 并预填搜索词；
          // 查物品页隐藏时不跳转，SnackBar 引导去设置开启（页面本身保留：
          // 动 diary_tab/location_answer_widget 的代价大于收益）
          onJumpToSearch: (keyword) {
            if (widget.listTabHidden) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('查物品页已隐藏，可在「设置 → 功能页面」中开启'),
                  duration: Duration(seconds: 2),
                ),
              );
              return;
            }
            setState(() => _currentIndex = tabIndexList); // 切换到 ListTab
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _listTabKey.currentState?.setSearchQuery(keyword);
            });
          },
        );
      case tabIndexSettings:
        return SettingsTab(
          key: _settingsTabKey,
          processor: _processor,
          dbHelper: _dbHelper,
        );
      default:
        throw ArgumentError('未知的 Tab 语义索引: $semantic');
    }
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
    // 拟物主题：底色恒为同色凸起，状态色（青/红/橙/灰）落在中心图标；
    // 旧主题：按钮底色随状态变化，图标恒白（2026-09-23 从 ext.textOnPrimary
    // 改回恒白：自定义主题主色偏浅时该槽按 WCAG 自动落深色，麦克风变黑，
    // 与日记页 Colors.white 不一致）
    final bool isNeu = ext.isNeumorphic;
    Color btnColor = ext.fabReady; // 默认青色（旧主题=按钮底色；拟物=中心图标色）
    Widget btnChild = Icon(Icons.mic, color: isNeu ? ext.primary : Colors.white, size: 46);

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮
      btnColor = ext.fabDisabled;
      btnChild = Icon(Icons.mic, color: isNeu ? ext.textHint : Colors.white, size: 46);
    } else if (state.isListening) {
      // 录音中 → 红色
      btnColor = ext.fabRecording;
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: isNeu ? ext.fabRecording : Colors.white,
        size: 46,
      );
    } else if (state.isProcessing) {
      // 处理中 → 橙色 + 转圈
      btnColor = ext.fabProcessing;
      btnChild = SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(
          color: isNeu ? ext.fabProcessing : Colors.white,
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
            // 拟物主题：同色凸起底 + 凹陷圆环（NeuVoiceFab，2026-09-18 真机
            // 反馈三处语音圆钮拟物化）；旧主题保持彩色圆底+黏土阴影
            child: isNeu
                ? NeuVoiceFab(size: 94, child: btnChild)
                : AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: btnColor,
                // 🎨 黏土拟态阴影（仿日记页，2026-09-23 用户反馈统一减淡：
                // 高光固定白（自定义主题 textOnPrimary 是深色会把高光染成黑晕）、
                // 暗影 alpha 0.2→0.12；与 diary_floating_button.dart 同款需同步）
                boxShadow: [
                  // 顶部高光阴影（模拟光源从上方）
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.4),
                    offset: const Offset(-4, -4),
                    blurRadius: 8,
                  ),
                  // 底部深色阴影（模拟凹陷感）
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
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
                  // ⚠️ 查物品浮钮也在外层 Stack（无 Material 祖先），decoration
                  // 不置 none 会出黄色双下划线警示（同 diary_floating_button 防护）
                  decoration: TextDecoration.none,
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
    // 拟物主题：底色恒为同色凸起，状态色（青/红/橙/灰）落在中心图标；
    // 旧主题：按钮底色随状态变化，图标恒白（2026-09-23 从 ext.textOnPrimary
    // 改回恒白：自定义主题主色偏浅时该槽按 WCAG 自动落深色，麦克风变黑，
    // 与日记页 Colors.white 不一致）
    final bool isNeu = ext.isNeumorphic;
    Color btnColor = ext.fabReady;
    Widget btnChild = Icon(Icons.mic, color: isNeu ? ext.primary : Colors.white, size: 55);

    if (!state.isReady && !RecognizerSingleton.hasModel) {
      // 模型文件不存在 → 禁用按钮（灰色）
      btnColor = ext.fabDisabled;
      btnChild = Icon(Icons.mic, color: isNeu ? ext.textHint : Colors.white, size: 55);
    } else if (state.isListening) {
      btnColor = ext.fabRecording;
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: isNeu ? ext.fabRecording : Colors.white,
        size: 55,
      );
    } else if (state.isProcessing) {
      btnColor = ext.fabProcessing;
      btnChild = SizedBox(
        width: 45,
        height: 45,
        child: CircularProgressIndicator(
          color: isNeu ? ext.fabProcessing : Colors.white,
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
                      // ⚠️ 钉底栏在 main.dart 外层 Stack（无 Material 祖先），
                      // Text 不给 decoration 会 fallback 到黄色双下划线警示
                      // 样式（同 diary_floating_button 状态文字的防护）
                      decoration: TextDecoration.none,
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
                    // 拟物主题：同色凸起底、图标直接落在凸面上（无凹环，
                    // 2026-09-18 与随手记页统一为无环定稿）；旧主题改用与
                    // 日记/查物品页同款黏土浅阴影（2026-09-23 用户反馈三页
                    // 阴影不一致：原彩色光晕无方向性，读不出「阴影」）
                    child: ext.isNeumorphic
                        ? NeuVoiceFab(size: 100, child: btnChild)
                        : AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // 🎨 黏土拟态阴影（diary_floating_button.dart 同款，
                        // 高光固定白 + 暗影 0.12，改动需三处同步）
                        boxShadow: [
                          // 顶部高光阴影（模拟光源从上方）
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.4),
                            offset: const Offset(-4, -4),
                            blurRadius: 8,
                          ),
                          // 底部深色阴影（模拟凹陷感）
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            offset: const Offset(4, 4),
                            blurRadius: 10,
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
                  // 确认保存按钮（拟物主题：纯同色凸起 + 品牌青文字，按住凹陷；
                  // 2026-09-17 预览拍板不用彩色渐变底）
                  SizedBox(
                    width: 140,
                    height: 100,
                    child: AppThemeExtension.of(context).isNeumorphic
                        ? NeuPressable(
                            onTap: state.saveData,
                            radius: 18,
                            child: Center(
                              child: Text(
                                "确认保存",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color:
                                      AppThemeExtension.of(context).primary,
                                  // ⚠️ NeuPressable 无 Material 祖先（钉底栏在
                                  // 外层 Stack，ElevatedButton 自带的 Material
                                  // 被换掉），decoration 不置 none 会出黄色
                                  // 双下划线警示（同 diary_floating_button 防护）
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          )
                        : ElevatedButton(
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
            Icon(Icons.info_outline, color: ext.textOnPrimary, size: 16),
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
