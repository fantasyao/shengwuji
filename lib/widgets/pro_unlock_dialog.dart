import '../app_logger.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gal/gal.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pro 功能解锁弹窗
///
/// 展示作者寄语 + 微信/支付宝付款码 + 底部三按钮：
/// 金色主按钮引导扫码付费（点击弹出付款方式选择），
/// 金色描边的「已扫码」按钮给付完款回来的用户一键解锁
/// （服务端无法验证付款，靠用户自觉点击），
/// 灰色描边次按钮为君子协定出口（不付费直接解锁）。
/// 解锁状态持久化到 SharedPreferences 的 `is_pro_unlocked` 字段，
/// Pro 门禁（黑金主题、节日红/极简白图标包等）读该字段。
class ProUnlockDialog extends StatefulWidget {
  /// 进入弹窗前是否已经解锁（控制解锁按钮是可点还是已点亮灰）
  final bool isAlreadyUnlocked;

  const ProUnlockDialog({super.key, required this.isAlreadyUnlocked});

  @override
  State<ProUnlockDialog> createState() => _ProUnlockDialogState();

  /// 显示弹窗
  static Future<void> show(
    BuildContext context, {
    required bool isAlreadyUnlocked,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          ProUnlockDialog(isAlreadyUnlocked: isAlreadyUnlocked),
    );
  }
}

class _ProUnlockDialogState extends State<ProUnlockDialog> {
  // 暖金色主题：边框、徽章背景、按钮主色都用这三个常量
  static const Color _kGoldColor = Color(0xFFD4A437);
  static const Color _kGoldLight = Color(0xFFFFF8E7);
  static const Color _kGoldBorder = Color(0xFFE6C158);

  // 是否本次已解锁：点击解锁按钮后立即置 true，按钮文案随之切换
  bool _unlocked = false;

  // 作者寄语文案，按句换行排版（用户原文，未删改）
  static const String _kUnlockText =
      '本app完全离线，已开源。\n'
      '没有做强制付费验证\n'
      '（主要是做起来真的很麻烦\n'
      '本次新增悬浮窗功能-花了很多心血（token）\n'
      '如果要用悬浮窗功能，5元解锁；\n'
      '不用该功能就无需付费，君子协定';

  @override
  void initState() {
    super.initState();
    _unlocked = widget.isAlreadyUnlocked;
  }

  Future<void> _handleUnlock() async {
    // 写入持久化解锁标志，后续功能门禁直接读这个 key
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_pro_unlocked', true);
    log('✓ Pro 功能已解锁（is_pro_unlocked=true）');
    if (!mounted) return;
    setState(() => _unlocked = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已解锁全部功能，感谢你的喜欢 ❤️'),
        duration: Duration(seconds: 2),
      ),
    );
    // 短暂延迟让用户看到 SnackBar，再关闭弹窗
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// 底部弹层选择付款方式（微信/支付宝），选中后关弹层并推入全屏付款码。
  /// 给主按钮一个真实动作：不是死路牌，点进去就能看到可保存的大图。
  void _showPayMethodSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '选择付款方式（¥5）',
                style: TextStyle(fontSize: 14, color: Colors.blueGrey),
              ),
            ),
            _payMethodTile(
              sheetContext,
              label: '微信支付',
              icon: Icons.chat_bubble,
              iconColor: const Color(0xFF07C160),
              assetPath: 'assets/weixinpay.png',
              viewerLabel: '微信',
            ),
            _payMethodTile(
              sheetContext,
              label: '支付宝',
              icon: Icons.account_balance_wallet,
              iconColor: const Color(0xFF1677FF),
              assetPath: 'assets/alipay.png',
              viewerLabel: '支付宝',
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 付款方式弹层里的一行入口：品牌色圆图标 + 文案，点击进全屏付款码
  Widget _payMethodTile(
    BuildContext sheetContext, {
    required String label,
    required IconData icon,
    required Color iconColor,
    required String assetPath,
    required String viewerLabel,
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: iconColor,
        child: Icon(icon, color: Colors.white, size: 20),
      ),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      trailing: const Icon(Icons.chevron_right, color: Colors.black26),
      onTap: () {
        Navigator.of(sheetContext).pop();
        _showFullScreenImage(assetPath, viewerLabel);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      // Dialog 自带 shape 与 child Container 的 border 叠加，营造"金边"效果
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 8,
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kGoldBorder, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部金色徽章
            Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                color: _kGoldLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.workspace_premium,
                color: _kGoldColor,
                size: 32,
              ),
            ),
            const SizedBox(height: 12),
            // 标题
            const Text(
              '解锁 Pro',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 12),
            // 正文寄语
            const Text(
              _kUnlockText,
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // 两张付款码缩略图：微信 + 支付宝（点击放大，长按保存到相册）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildPaymentThumbnail(
                  assetPath: 'assets/weixinpay.png',
                  label: '微信',
                ),
                const SizedBox(width: 12),
                _buildPaymentThumbnail(
                  assetPath: 'assets/alipay.png',
                  label: '支付宝',
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 主按钮：引导扫码付费（点击 → 底部弹层选微信/支付宝 → 全屏付款码）
            // 已解锁后变灰禁用，此时下方两个解锁出口整体隐藏
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _unlocked ? null : _showPayMethodSheet,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGoldColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade600,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  _unlocked ? '✓ 已解锁，感谢支持' : '扫码支付 ¥5 解锁',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            // 已扫码按钮：付完款回来的用户专用出口——没有服务端验证，
            // 靠这个按钮让已付费用户有明确的落点（而不是被迫点「暂不付费」）。
            // 金色描边 + 浅金底：比君子协定按钮显著，又不抢实心主按钮的层级
            if (!_unlocked) ...[
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _handleUnlock,
                style: OutlinedButton.styleFrom(
                  backgroundColor: _kGoldLight,
                  foregroundColor: _kGoldColor,
                  side: const BorderSide(color: _kGoldBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  '已扫码，点击解锁',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ],
            // 次按钮：君子协定出口。同为正经按钮但更矮、描边弱化，
            // 与上面两个金色系按钮拉开层级（不做灰色小字链接，保持大方）
            if (!_unlocked) ...[
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _handleUnlock,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blueGrey,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  '先使用，后续再付费解锁',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
            // 关闭按钮
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                '关闭',
                style: TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 付款码：缩略图 + 全屏查看 ============

  /// 构建单张付款码缩略图（90×90 金边圆角 + 下方"微信/支付宝"标签）。
  /// 点击 → 全屏放大；长按 → 直接保存到相册（不弹中间菜单）。
  Widget _buildPaymentThumbnail({
    required String assetPath,
    required String label,
  }) {
    return InkWell(
      onTap: () => _showFullScreenImage(assetPath, label),
      onLongPress: () => _savePaymentToGallery(assetPath, context),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldBorder, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset(
                assetPath,
                fit: BoxFit.cover,
                // 占位：加载中灰色底，避免白图闪烁
                errorBuilder: (context, error, stack) => Container(
                  color: _kGoldLight,
                  child: const Icon(
                    Icons.broken_image,
                    color: _kGoldColor,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  /// 推入全屏图片查看 Route（黑底沉浸式 + 双指缩放 + 单击关闭 + 长按保存）
  void _showFullScreenImage(String assetPath, String label) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (context, animation, secondaryAnimation) =>
            _FullScreenImageViewer(assetPath: assetPath, label: label),
        transitionsBuilder: (context, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}

/// 保存付款码图片到系统相册（dialog 缩略图长按 + 全屏图长按共用）。
///
/// 流程：检查/请求权限 → asset 字节写入临时文件 → [Gal.putImage] → 清理 → SnackBar。
/// Android 11+ scoped storage 自动处理，无需显式权限；Android 10 及以下需 WRITE_EXTERNAL_STORAGE。
Future<void> _savePaymentToGallery(
  String assetPath,
  BuildContext context,
) async {
  try {
    // 1. 权限检查/请求（gal 自身处理 API 30+ 的 scoped storage）
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未授权存储权限，无法保存')));
        return;
      }
    }
    // 2. asset 字节 → 临时文件
    final bytes = await rootBundle.load(assetPath);
    final tempDir = await getTemporaryDirectory();
    final fileName = path.basename(assetPath);
    final tempFile = File('${tempDir.path}/$fileName');
    await tempFile.writeAsBytes(bytes.buffer.asUint8List());
    // 3. 交给 Gal 保存到相册
    await Gal.putImage(tempFile.path);
    // 4. 清理临时文件
    await tempFile.delete();
    log('✓ 付款码已保存到相册：$assetPath');
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已保存到相册，可用微信/支付宝扫一扫识别')));
  } on GalException catch (e) {
    log('✗ Gal 保存失败：${e.type.message}');
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('保存失败：${e.type.message}')));
  }
}

/// 付款码全屏查看器。
///
/// 黑底沉浸式：双指缩放（[InteractiveViewer]），单击关闭，长按调
/// [_savePaymentToGallery] 保存。右上角关闭按钮作兜底（避免单击在缩放态下未触发）。
class _FullScreenImageViewer extends StatelessWidget {
  final String assetPath;
  final String label;

  const _FullScreenImageViewer({required this.assetPath, required this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.9),
      body: Stack(
        children: [
          // 主体：InteractiveViewer 内缩放，child GestureDetector 仅响应 tap/longPress
          // （GestureDetector 只注册 tap/longPress，scale 类手势不会被它认领，
          // 自动透传给 InteractiveViewer 处理）
          Center(
            child: InteractiveViewer(
              maxScale: 4.0,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                onLongPress: () => _savePaymentToGallery(assetPath, context),
                child: Image.asset(
                  assetPath,
                  width: MediaQuery.of(context).size.width * 0.85,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          // 顶部提示
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 0,
            right: 0,
            child: Text(
              '$label · 点击关闭 · 长按保存',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          // 右上关闭按钮（兜底）
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
