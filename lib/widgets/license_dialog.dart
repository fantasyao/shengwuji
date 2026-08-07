import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // rootBundle 加载 assets 协议文本

/// 开源字体许可证查看弹窗
///
/// 加载并展示 `assets/licenses/OFL-LXGWWenKai.txt`（霞鹜文楷字体的
/// SIL Open Font License 1.1 协议全文）。
///
/// 先 `rootBundle.loadString` 异步读文本，成功后再 `showDialog` —— 加载期间
/// 不展示弹窗（符合 docs/guides/async-operations.md 的加载态规范，无需单独
/// loading 态）。加载失败时 print 错误 + SnackBar 提示用户。
class LicenseDialog {
  // 工具类，禁止实例化
  LicenseDialog._();

  /// 显示许可证弹窗。
  ///
  /// 先异步加载协议文本，成功后才推入 Dialog；失败则 print 错误并用 SnackBar
  /// 告知用户「协议文件加载失败」。
  static Future<void> show(BuildContext context) async {
    String txt;
    try {
      txt = await rootBundle.loadString('assets/licenses/OFL-LXGWWenKai.txt');
    } catch (e, s) {
      // 协议文件缺失或读取失败（可能未在 pubspec.yaml 登记 / 打包遗漏）
      print('✗ 字体许可证文件加载失败：$e\n$s');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('协议文件加载失败'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 8,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          decoration: BoxDecoration(
            // 跟随明暗主题（M3 Dialog 标准表面色），避免硬编码不协调颜色
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          // 限制最大高度为屏幕 80%，超出滚动
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部标题行：标题 + 关闭按钮
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '开源字体许可证',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.titleLarge?.color,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 1),
              // 中间：可滚动 + 可选中复制的协议全文
              Expanded(
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: SelectableText(
                      txt,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
              // 底部关闭按钮
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
