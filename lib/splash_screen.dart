import 'app_logger.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'recognizer_singleton.dart';
import 'startup_logger.dart';
import 'theme/app_theme_extension.dart';

/// 启动页：在显示主界面前完成模型预加载和权限请求
class SplashScreen extends StatefulWidget {
  final Widget child;

  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _isInitializing = true;
  String _statusMessage = '正在准备...';
  double _progress = 0.0;

  /// 是否正在等待用户点击授权按钮
  /// true = 显示权限说明 + 按钮，等待用户操作
  /// false = 正在执行后台初始化或已完成
  bool _waitingForPermission = false;

  /// 用户拒绝权限后显示引导提示
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _doInit();
  }

  /// 第一阶段：模型预加载，然后检查权限状态决定是否显示授权按钮
  Future<void> _doInit() async {
    StartupLogger.markAppStart();
    try {
      setState(() {
        _statusMessage = '正在准备语音模型...';
        _progress = 0.0;
      });
      final sw1 = Stopwatch()..start();
      await RecognizerSingleton.preloadModelPath();
      sw1.stop();
      log("⏱️ [Splash] preloadModelPath 耗时: ${sw1.elapsedMilliseconds}ms");
      StartupLogger.log("preloadModelPath", sw1.elapsedMilliseconds);

      // 检查当前权限状态：已授权则直接跳过按钮，继续初始化
      final status = await Permission.microphone.status;
      log("🎤 [Splash] 麦克风权限状态: $status");
      if (status.isGranted) {
        // 已授权，直接完成初始化
        await _finishInit();
      } else {
        // 未授权，显示说明文本和授权按钮，等待用户操作
        if (mounted) {
          setState(() {
            _waitingForPermission = true;
            _progress = 0.5;
          });
        }
      }
    } catch (e) {
      debugPrint('启动页初始化出错: $e');
      StartupLogger.logRaw("初始化出错: $e");
      // 即使出错也显示权限按钮，让用户有机会继续
      if (mounted) {
        setState(() {
          _waitingForPermission = true;
        });
      }
    }
  }

  /// 用户点击授权按钮后调用
  Future<void> _onGrantPermission() async {
    setState(() {
      _waitingForPermission = false;
      _statusMessage = '请求麦克风权限...';
    });

    final sw2 = Stopwatch()..start();
    final status = await Permission.microphone.request();
    sw2.stop();
    log("⏱️ [Splash] 请求权限 耗时: ${sw2.elapsedMilliseconds}ms");
    StartupLogger.log("请求权限", sw2.elapsedMilliseconds);
    log("🎤 [Splash] 权限请求结果: $status");

    if (status.isGranted) {
      await _finishInit();
    } else {
      // 用户拒绝或永久拒绝，显示引导提示
      if (mounted) {
        setState(() {
          _permissionDenied = true;
          _waitingForPermission = true;
        });
      }
    }
  }

  /// 完成初始化流程（权限已获得后调用）
  Future<void> _finishInit() async {
    // 🆕 不再在启动时加载模型，恢复延迟加载模式
    // 模型将在用户第一次录音时由 diary_tab/record_tab 的 stopListening 加载

    if (mounted) {
      setState(() {
        _progress = 1.0;
        _isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    if (!_isInitializing) {
      return widget.child;
    }

    // 等待用户点击授权按钮
    if (_waitingForPermission) {
      return Scaffold(
        backgroundColor: ext.splashBackground,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // App 图标（圆角）—— Center 包裹防止 stretch 拉伸图标
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/icon/icon2.png',
                      width: 120,
                      height: 120,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // App 名称
                const Text(
                  '声物记',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                // 副标题
                // 所有主题共用白文字透明度，不参与主题切换
                const Text(
                  '一款完全离线的快捷语音日记',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
                ),
                const SizedBox(height: 6),
                // Slogan
                const Text(
                  '一键记存，快捷好用。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                ),
                const Text(
                  '离线识别，隐私放心。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                ),
                const SizedBox(height: 48),
                // 权限说明文字
                const Text(
                  '使用离线语音模型在本地完成识别，不上传任何数据',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 15,
                    height: 1.8,
                  ),
                ),
                const Text(
                  '需要麦克风权限才能开始使用',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 15,
                    height: 1.8,
                  ),
                ),
                const SizedBox(height: 32),
                // 授权按钮
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _onGrantPermission,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white, // 所有主题共用白底按钮
                      foregroundColor: ext.splashBackground,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      '授权并开始',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                // 拒绝权限后的引导提示
                if (_permissionDenied) ...[
                  const SizedBox(height: 24),
                  const Text(
                    '麦克风权限被拒绝，语音功能将无法使用',
                    style: TextStyle(color: Color(0xFFFF8A80), fontSize: 13), // 所有主题共用错误提示色，不参与主题切换
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      // 引导用户去系统设置页手动授权
                      await openAppSettings();
                    },
                    child: const Text(
                      '前往设置开启权限',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      // 跳过权限，直接进入应用（无语音功能）
                      _finishInit();
                    },
                    child: const Text(
                      '暂时跳过',
                      style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // 后台初始化中（模型预加载阶段）
    return Scaffold(
      backgroundColor: ext.splashBackground,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // App 图标（圆角）—— Center 包裹防止 stretch 拉伸图标
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/icon/icon2.png',
                  width: 120,
                  height: 120,
                ),
              ),
            ),
            const SizedBox(height: 24),
            // App 名称
            const Text(
              '声物记',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            // 副标题
            // 所有主题共用白文字透明度，不参与主题切换
            const Text(
              '一款完全离线的快捷语音日记',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
            ),
            const SizedBox(height: 6),
            // Slogan
            const Text(
              '一键记存，快捷好用。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
            ),
            const Text(
              '离线识别，隐私放心。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
            ),
            const SizedBox(height: 40),
            // 进度条 —— Center 包裹限制宽度（stretch 模式下 SizedBox 会撑满）
            Center(
              child: SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 状态文字
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
