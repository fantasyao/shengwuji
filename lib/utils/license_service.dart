import 'package:flutter/services.dart';
import '../app_logger.dart';

/// Pro 授权码服务：安卓 ID 获取 + 授权码校验的 channel 封装。
///
/// 授权码体系见 docs/architecture/pro-license.md：
/// 用户发邮件（付款截图 + 本机安卓 ID）→ 开发者用 tools/license/gen_license.py
/// 生成 16 字符短码 → 用户在 App 输入 → Kotlin 侧哈希比对（本文件只做格式预校验，
/// 密码学比对在 MainActivity.verifyLicenseCode，防 Flutter 层字符串提取门槛更低）。
class LicenseService {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  /// 开发者收款/收件邮箱（用户把付款截图 + 安卓 ID 发到这里，回邮件拿授权码）
  static const kSupportEmail = 'fantasyao@foxmail.com';

  /// 本机安卓 ID（Settings.Secure.ANDROID_ID）。
  /// 极少数设备可能返回 null（系统异常），调用方需兜底提示。
  static Future<String?> getAndroidId() async {
    try {
      return await _channel.invokeMethod<String>('getAndroidId');
    } on PlatformException catch (e) {
      log('✗ 获取安卓 ID 失败：${e.code} ${e.message}');
      return null;
    }
  }

  /// 校验授权码（Kotlin 侧最终哈希比对；调用前先 [looksLikeLicenseCode] 预校验给即时反馈）
  static Future<bool> verifyLicense(String code) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('verifyLicense', {'code': code});
      return ok ?? false;
    } on PlatformException catch (e) {
      log('✗ 授权码校验 channel 异常：${e.code} ${e.message}');
      return false;
    }
  }
}

/// 归一化授权码：大写、去横线与空格（Kotlin 侧 verifyLicenseCode 同规则，双侧冗余）
String normalizeLicenseCode(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[-\s]'), '');

/// 格式预校验：16 位 base32（RFC4648 A-Z2-7）。只判格式不判真伪。
bool looksLikeLicenseCode(String raw) {
  final normalized = normalizeLicenseCode(raw);
  if (normalized.length != 16) return false;
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  for (final c in normalized.runes) {
    if (!alphabet.contains(String.fromCharCode(c))) return false;
  }
  return true;
}
