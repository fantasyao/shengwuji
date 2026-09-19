import '../app_logger.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show rootBundle, Clipboard, ClipboardData;
import 'package:gal/gal.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/license_service.dart';
import '../utils/pro_gate.dart';

// 暖金色主题：边框、徽章背景、按钮主色都用这三个常量（弹窗与授权码输入弹层共用）
const Color _kGoldColor = Color(0xFFD4A437);
const Color _kGoldLight = Color(0xFFFFF8E7);
const Color _kGoldBorder = Color(0xFFE6C158);

/// 弹窗系轻提示：挂 rootOverlay（全局最上层，Dialog/BottomSheet 都盖不住）。
///
/// 为什么不用 ScaffoldMessenger SnackBar：SnackBar 挂在底层页面的 Scaffold 上，
/// 会被本弹窗的遮罩层盖住（真机反馈：点复制后"已复制"提示看不到）。弹窗 pop 后
/// 浮层仍留在 rootOverlay 上继续显示到超时，信息不丢。
void _showFloatingTip(BuildContext context, String text) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 24,
      right: 24,
      bottom: 120,
      // 纯展示：不挡弹窗/页面的点击
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 1400), () {
    if (entry.mounted) entry.remove();
  });
}

/// Pro 功能解锁弹窗（授权码体系版）。
///
/// 解锁链路：扫码支付 → 发邮件（付款截图 + 本机安卓 ID）到开发者邮箱 →
/// 收到回复的授权码 → 在本弹窗输入 → Kotlin 侧哈希比对通过后永久解锁。
/// 不便付款可点「先试用 7 天」一次性全量试用（到期后各门禁点拦截）。
///
/// 展示内容：付款码（微信/支付宝，可放大/存相册）+ 安卓 ID 与收款邮箱（一键复制，
/// 用户发邮件直接粘贴）+ 三按钮（扫码支付 / 先试用 7 天 / 输入授权码）。
/// 旧的「自觉点按钮解锁」君子协定出口已随授权码体系移除。
/// 关闭返回值 = Pro 是否已可用（试用激活或授权码验证成功时 pop(true)）。
class ProUnlockDialog extends StatefulWidget {
  const ProUnlockDialog({super.key});

  @override
  State<ProUnlockDialog> createState() => _ProUnlockDialogState();

  /// 显示弹窗。
  ///
  /// 返回值 = 关闭时 Pro 是否已可用：试用激活或授权码验证成功时 pop(true)
  /// （调用方可继续原操作，如应用刚点击的 Pro 主题）；普通关闭均为 false。
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const ProUnlockDialog(),
    );
    return result ?? false;
  }
}

class _ProUnlockDialogState extends State<ProUnlockDialog> {
  // 永久解锁状态（is_pro_unlocked，授权码验证通过后写入）
  bool _unlocked = false;

  // 试用截止（null=加载中；0=从未开过试用；>0=试用中或已过期，按与当前时间差判断）
  int? _trialDeadlineMs;

  // 本机安卓 ID（发邮件要附上；channel 获取失败保持 null 显示占位）
  String? _androidId;

  // 流程说明文案（2026-09-19 真机反馈精简：原 8 行在窄屏折行把试用按钮顶出
  // 屏幕外，砍掉与底部按钮重复的"可先试用"句和冗余措辞，配合弹窗加宽收进一屏）
  static const String _kFlowText =
      '¥5 永久解锁 Pro（悬浮窗、新拟物主题等）\n'
      '① 扫码支付 ¥5\n'
      '② 发邮件附付款截图 + 安卓 ID（下方可复制）\n'
      '③ 收到授权码后点「输入授权码」';

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final androidId = await LicenseService.getAndroidId();
    if (!mounted) return;
    setState(() {
      // 永久解锁 = 解锁布尔 + 授权码记录同时成立（ProGate 组合判定）——
      // 旧版君子协定遗留的裸布尔不算，避免存量免费解锁用户看到"已解锁"。
      // 注意 ?? 优先级低于 &&，两侧 ?? 都必须带括号
      _unlocked = (prefs.getBool(ProGate.kKeyIsProUnlocked) ?? false) &&
          (prefs.getString(ProGate.kKeyLicenseCode)?.isNotEmpty ?? false);
      _trialDeadlineMs = prefs.getInt(ProGate.kKeyTrialDeadlineMs) ?? 0;
      _androidId = androidId;
    });
  }

  /// 开启 7 天试用：成功即 pop(true)（调用方继续原操作，如应用刚点的主题）
  Future<void> _startTrial() async {
    final ok = await ProGate.startTrial();
    if (!mounted) return;
    if (!ok) {
      _showFloatingTip(context, '试用已开启过，无法重复试用');
      return;
    }
    _showFloatingTip(context, '已开启 7 天试用，Pro 功能全部解锁 ✨');
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 弹授权码输入弹层；验证成功返回 true（弹层内部写 is_pro_unlocked）
  Future<void> _showLicenseInputSheet() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => const _LicenseInputSheet(),
    );
    if (ok == true && mounted) {
      setState(() => _unlocked = true);
      Navigator.of(context).pop(true);
    }
  }

  void _copyText(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    log('✓ 已复制$label到剪贴板');
    _showFloatingTip(context, '已复制$label');
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

  /// 信息行：标签 + 值 + 复制按钮（安卓 ID / 收款邮箱共用）
  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
    bool loading = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kGoldLight.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGoldBorder.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _kGoldColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 11, color: Colors.black45)),
                const SizedBox(height: 2),
                Text(
                  loading ? '获取中…' : value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: loading ? Colors.black26 : Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!loading)
            IconButton(
              icon: const Icon(Icons.copy, size: 18, color: Colors.black45),
              tooltip: '复制$label',
              onPressed: () => _copyText(label, value),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trialDeadline = _trialDeadlineMs;
    final trialRemaining = trialDeadline == null || trialDeadline == 0
        ? 0
        : ((trialDeadline - DateTime.now().millisecondsSinceEpoch) /
                Duration.millisecondsPerDay)
            .ceil();
    final trialActive = trialRemaining > 0;
    final trialUsed = trialDeadline != null && trialDeadline != 0;

    return Dialog(
      // insetPadding 左右收窄到 24（默认 40）：真机反馈弹窗文字折行过多、试用
      // 按钮被顶出屏幕外——加宽减少折行
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
        // 小屏防溢出：内容超高时内部滚动
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部金色徽章（52：2026-09-19 真机反馈压缩弹窗高度，原 60）
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: _kGoldLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.workspace_premium,
                  color: _kGoldColor,
                  size: 28,
                ),
              ),
              const SizedBox(height: 10),
              // 标题
              const Text(
                '解锁 Pro',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                ),
              ),
              const SizedBox(height: 10),
              // 解锁流程说明（行高 1.5：原 1.7 折行多时纵向开销大）
              const Text(
                _kFlowText,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // 安卓 ID + 收款邮箱（发邮件两要素，一键复制）
              _infoRow(
                icon: Icons.phone_android,
                label: '安卓 ID（发邮件附上）',
                value: _androidId ?? '',
                loading: _androidId == null,
              ),
              const SizedBox(height: 8),
              _infoRow(
                icon: Icons.mail,
                label: '开发者邮箱',
                value: LicenseService.kSupportEmail,
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              // 主按钮：引导扫码付费。已解锁后变灰禁用
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
              if (!_unlocked) ...[
                const SizedBox(height: 8),
                // 授权码入口：已付费用户的落点（浅金描边，层级居主按钮之下）
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton(
                    onPressed: _showLicenseInputSheet,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _kGoldLight,
                      foregroundColor: _kGoldColor,
                      side: const BorderSide(color: _kGoldBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      '输入授权码解锁',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                // 试用入口：未开过试用才显示；试用中显示剩余天数禁用态
                if (!trialUsed) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: OutlinedButton(
                      onPressed: _startTrial,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blueGrey,
                        side: BorderSide(color: Colors.grey.shade300),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        '先免费试用 7 天',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ] else if (trialActive) ...[
                  const SizedBox(height: 8),
                  Text(
                    '试用中 · 剩余 $trialRemaining 天',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ],
              // 关闭按钮
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text(
                  '关闭',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ),
            ],
          ),
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

/// 授权码输入弹层。
///
/// 输入/粘贴授权码 → Dart 侧格式预校验（16 位 base32）→ channel 走 Kotlin
/// 哈希比对 → 通过写 is_pro_unlocked=true 并 pop(true)。
class _LicenseInputSheet extends StatefulWidget {
  const _LicenseInputSheet();

  @override
  State<_LicenseInputSheet> createState() => _LicenseInputSheetState();
}

class _LicenseInputSheetState extends State<_LicenseInputSheet> {
  final _controller = TextEditingController();
  bool _verifying = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      _showFloatingTip(context, '剪贴板是空的');
      return;
    }
    _controller.text = text;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
    if (mounted) setState(() => _errorText = null);
  }

  Future<void> _verify() async {
    final raw = _controller.text;
    if (!looksLikeLicenseCode(raw)) {
      setState(() => _errorText = '授权码格式不对（16 位字母数字，可含 - 分隔）');
      return;
    }
    setState(() {
      _verifying = true;
      _errorText = null;
    });
    final ok = await LicenseService.verifyLicense(raw);
    log('授权码校验结果：$ok');
    if (!mounted) return;
    if (ok) {
      // 永久解锁落盘：解锁布尔 + 授权码记录（组合判定两要素都写齐；
      // 缺码记录会被视为旧版君子协定遗留而失效）；sheet pop(true) →
      // 外层弹窗随之 pop(true)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          ProGate.kKeyLicenseCode, normalizeLicenseCode(raw));
      await prefs.setBool(ProGate.kKeyIsProUnlocked, true);
      if (!mounted) return;
      // 浮层提示挂 rootOverlay：随后两层 pop（弹层+弹窗）它仍在最上层可见
      _showFloatingTip(context, '授权码验证通过，已永久解锁，感谢支持 ❤️');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _verifying = false;
        _errorText = '授权码与设备不匹配，请核对邮件里的授权码与本机安卓 ID';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // 键盘弹出时避让（isScrollControlled 底部弹层必配）
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '输入授权码',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '授权码与设备绑定，请使用回复邮件中的授权码',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 16,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  hintText: 'XXXX-XXXX-XXXX-XXXX',
                  hintStyle: TextStyle(color: Colors.grey.shade300),
                  errorText: _errorText,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _kGoldColor),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onSubmitted: (_) => _verifying ? null : _verify(),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _verifying ? null : _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('粘贴'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blueGrey,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _verifying ? null : _verify,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kGoldColor,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _verifying
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                '验证并解锁',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
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
