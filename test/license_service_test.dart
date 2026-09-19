import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/license_service.dart';

/// 授权码格式函数回归（与 Kotlin verifyLicenseCode / tools/license/gen_license.py
/// 的 normalize 规则双侧冗余，规则改动必须三处同步）：
/// 归一化 = 大写 + 去横线/空格；预校验 = 16 位 RFC4648 base32（A-Z2-7）。
/// 哈希比对本体在 Kotlin 侧，真伪交叉验证走 `uv run tools/license/gen_license.py verify`。
void main() {
  group('normalizeLicenseCode', () {
    test('小写 + 横线 + 空格混合输入归一为 16 位大写', () {
      expect(
        normalizeLicenseCode('sxqb-xpe5-ilkv-xu6u'),
        'SXQBXPE5ILKVXU6U',
      );
      expect(
        normalizeLicenseCode(' SXQB XPE5  ilkv-xu6u '),
        'SXQBXPE5ILKVXU6U',
      );
    });

    test('无横线直接输入原样大写', () {
      expect(normalizeLicenseCode('sxqbxpe5ilkvxu6u'), 'SXQBXPE5ILKVXU6U');
    });
  });

  group('looksLikeLicenseCode（只判格式不判真伪）', () {
    test('合法 16 位分组码', () {
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU6U'), isTrue);
    });

    test('合法小写无分组码（归一化后通过）', () {
      expect(looksLikeLicenseCode('sxqbxpe5ilkvxu6u'), isTrue);
    });

    test('长度不对：拒绝', () {
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU'), isFalse);
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU6UX'), isFalse);
      expect(looksLikeLicenseCode(''), isFalse);
    });

    test('base32 字母表外字符（0/1/8/9 不在 A-Z2-7）：拒绝', () {
      // 0、1、8 均非 RFC4648 base32 字符
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU60'), isFalse);
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU61'), isFalse);
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU68'), isFalse);
    });

    test('任意非字母数字注入：拒绝', () {
      expect(looksLikeLicenseCode('SXQB-XPE5-ILKV-XU6@'), isFalse);
    });
  });
}
