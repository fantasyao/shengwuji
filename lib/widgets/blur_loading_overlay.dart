import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 全局高斯模糊Loading遮罩组件
///
/// 使用BackdropFilter实现优雅的"毛玻璃"效果，覆盖整个屏幕（包括bottomNavigationBar）
class BlurLoadingOverlay extends StatelessWidget {
  final String? message;

  const BlurLoadingOverlay({super.key, this.message});

  /// 预定义的随机文案列表
  static const List<String> _loadingMessages = [
    "初始化识别引擎...",
    "日记引擎准备中...",
    "正在唤醒 SenseVoice...",
    "初始化语音识别...",
    "加载离线语音模型（约 2 秒）",
    "加载AI模型中...",
    "优化识别参数...",
  ];

  /// 获取随机文案
  static String getRandomMessage() {
    final random = Random();
    return _loadingMessages[random.nextInt(_loadingMessages.length)];
  }

  @override
  Widget build(BuildContext context) {
    final displayMessage = message ?? getRandomMessage();

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      bottom: 0,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // 1. 背景模糊层
            BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(
                color: Colors.white.withValues(alpha: 0.3), // 轻微白色遮罩，提升性能和视觉效果
              ),
            ),

            // 2. 前景内容层
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 半透明App图标
                  Opacity(
                    opacity: 0.6,
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      width: 120,
                      height: 120,
                      errorBuilder: (context, error, stackTrace) {
                        // 图标加载失败时的fallback
                        return const Icon(
                          Icons.apps,
                          size: 120,
                          color: Colors.blueGrey,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 随机文案
                  Text(
                    displayMessage,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 静态沙漏图标（替代转圈动画，避免CPU抢占卡顿）
                  Icon(
                    Icons.hourglass_empty,
                    size: 32,
                    color: Colors.blueGrey.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
