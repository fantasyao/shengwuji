"""声物记 Pro 授权码生成工具（藏盐哈希短码）。

用法（本机 UV，无 python 直调）：
  uv run tools/license/gen_license.py keygen                   # 首次：生成 secret 到 tools/license/secret.txt
  uv run tools/license/gen_license.py issue <androidId>        # 给用户发码
  uv run tools/license/gen_license.py verify <androidId> <code> # 与 App 内 Kotlin 实现交叉验证
  uv run tools/license/gen_license.py kotlinc                  # 输出 secret 的 Kotlin 掩码常量代码（贴进 MainActivity）

授权码格式（与 MainActivity.verifyLicenseCode 严格一致，改动必须双侧同步）：
  payload = salt(2B 随机) + SHA256("{secret}:{androidId}:{salt_hex}")[0:8]  共 10 字节
  授权码  = base32(payload) 16 字符，显示为 XXXX-XXXX-XXXX-XXXX（RFC4648 大写 A-Z2-7）
  salt 每次随机 => 同一设备每次生成的码都不同（随机授权码）；验证端重算哈希恒时比较。

⚠️ 防伪边界（如实声明）：secret 以掩码形式随 APK 分发，开源仓库 + 静态分析可还原——
   防伪强度为逆向门槛（挡普通用户乱输码/改布尔），不挡认真逆向。经用户拍板接受（¥5 应用）。
   secret 明文只存 tools/license/secret.txt（已 gitignore），严禁提交/外传。
"""

import base64
import hashlib
import hmac
import secrets
import sys
from pathlib import Path

SECRET_PATH = Path(__file__).parent / "secret.txt"
# base32 RFC4648：24 个 '=' 之类不存在，字母表就是 A-Z2-7
B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def load_secret() -> str:
    if not SECRET_PATH.exists():
        sys.exit(f"✗ 未找到 {SECRET_PATH}，先运行: uv run tools/license/gen_license.py keygen")
    secret = SECRET_PATH.read_text(encoding="utf-8").strip()
    if len(secret) != 64 or any(c not in "0123456789abcdef" for c in secret):
        sys.exit("✗ secret.txt 格式不对（应为 64 位 hex），删除后重新 keygen")
    return secret


def make_payload(secret: str, android_id: str, salt: bytes) -> bytes:
    digest = hashlib.sha256(f"{secret}:{android_id}:{salt.hex()}".encode("utf-8")).digest()
    return salt + digest[:8]


def payload_to_code(payload: bytes) -> str:
    # 10 字节 = 80 bits = 16 个 base32 字符（整除，无填充）
    encoded = base64.b32encode(payload).decode("ascii")
    assert len(encoded) == 16
    return "-".join(encoded[i : i + 4] for i in range(0, 16, 4))


def normalize_code(raw: str) -> str:
    return raw.upper().replace("-", "").replace(" ", "")


def verify_payload(payload: bytes, secret: str, android_id: str) -> bool:
    salt, expect = payload[:2], payload[2:]
    actual = make_payload(secret, android_id, salt)[2:]
    return hmac.compare_digest(expect, actual)


def cmd_keygen(force: bool) -> None:
    if SECRET_PATH.exists() and not force:
        sys.exit(f"✗ {SECRET_PATH} 已存在（防误覆盖丢码），确认作废请加 --force")
    SECRET_PATH.write_text(secrets.token_hex(32) + "\n", encoding="utf-8")
    print(f"✓ secret 已生成：{SECRET_PATH}（已 gitignore，勿提交/勿外传）")
    print("  下一步：uv run tools/license/gen_license.py kotlinc  # 把掩码常量贴进 MainActivity.kt")


def cmd_issue(android_id: str) -> None:
    secret = load_secret()
    code = payload_to_code(make_payload(secret, android_id, secrets.token_bytes(2)))
    print(f"安卓ID: {android_id}\n授权码: {code}")


def cmd_verify(android_id: str, raw_code: str) -> None:
    secret = load_secret()
    normalized = normalize_code(raw_code)
    if len(normalized) != 16 or any(c not in B32_ALPHABET for c in normalized):
        sys.exit("✗ 授权码格式不对（应 16 位 A-Z2-7）")
    payload = base64.b32decode(normalized)
    ok = verify_payload(payload, secret, android_id)
    print("✓ 授权码与设备匹配" if ok else "✗ 授权码与设备不匹配")
    sys.exit(0 if ok else 1)


def cmd_kotlinc() -> None:
    secret = load_secret()
    mask = 0x5A
    masked = base64.b64encode(bytes(b ^ mask for b in secret.encode("utf-8"))).decode("ascii")
    half = len(masked) // 2
    print(
        f"""// 由 tools/license/gen_license.py kotlinc 生成（勿手改）；secret 明文仅存本地 secret.txt（gitignore）
private const val LICENSE_SECRET_MASK = 0x{mask:02X}
private const val LICENSE_SECRET_PART_A = "{masked[:half]}"
private const val LICENSE_SECRET_PART_B = "{masked[half:]}"

private fun decodeLicenseSecret(): String {{
    // XOR 自反：编码侧每字节 ^MASK，解码同 ^MASK 还原
    val maskedBytes = android.util.Base64.decode(LICENSE_SECRET_PART_A, android.util.Base64.DEFAULT) +
        android.util.Base64.decode(LICENSE_SECRET_PART_B, android.util.Base64.DEFAULT)
    return String(maskedBytes) {{ (it.toInt() xor LICENSE_SECRET_MASK) and 0xFF }}
}}"""
    )


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] == "keygen":
        cmd_keygen("--force" in args)
    elif len(args) == 2 and args[0] == "issue":
        cmd_issue(args[1])
    elif len(args) == 3 and args[0] == "verify":
        cmd_verify(args[1], args[2])
    elif len(args) == 1 and args[0] == "kotlinc":
        cmd_kotlinc()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
