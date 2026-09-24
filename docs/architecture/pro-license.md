# Pro 授权体系（授权码 + 7 天试用）

## 概述

2026-09-19 落地（feature/neumorphism-theme 分支）。Pro 解锁从「自觉点按钮」的君子协定升级为授权码体系：

```
用户：设置页点 Pro 入口 → 扫码支付 ¥5
    → 发邮件到 fantasyao@foxmail.com（附付款截图 + 本机安卓 ID，App 内一键复制）
开发者：tools/license/gen_license.py issue <安卓ID> 生成 16 字符授权码，邮件回复
用户：App 内「输入授权码」→ Kotlin 哈希比对 → 永久解锁（is_pro_unlocked=true）
```

不便付款可点「先试用 7 天」一次性全量试用。Pro 功能范围：悬浮窗（含语音速记/悬浮窗笔记）、晴空蓝主题、新拟物主题、节日红/极简白图标包、音量键悬浮窗系手势。

## 授权码算法（藏盐哈希短码）

```
payload = salt(2B 随机) + SHA256("{secret}:{androidId}:{salt_hex}")[0:8]   # 共 10 字节
授权码   = base32(payload) 16 字符，显示为 XXXX-XXXX-XXXX-XXXX             # RFC4648 A-Z2-7
验证     = 取码内 salt 重算哈希，MessageDigest.isEqual 恒时比较
```

- salt 每次随机 ⇒ 同一设备每次生成的码都不同（随机授权码）。
- 算法三处实现严格一致，改动必须三处同步：`tools/license/gen_license.py`（生成/交叉验证）、`MainActivity.verifyLicenseCode`（App 内校验）、`lib/utils/license_service.dart`（格式预校验 normalize 规则）。
- **⚠️ 防伪边界（如实声明）**：secret 以异或掩码两段 base64 存于 Kotlin 常量，随 APK 分发且仓库开源——防伪强度为逆向门槛（挡普通用户乱输码/改布尔），**不挡认真逆向**。经用户拍板接受（¥5 应用）。secret 明文仅存 `tools/license/secret.txt`（已 gitignore）；泄露 = 体系作废，补救需换 secret 并给所有已付费用户重发码。

### 生成工具（开发者本机）

三套入口，算法单点在 `gen_license.py`，另两处只是调用/移植：

1. **桌面 GUI**：双击 `tools/license/授权码工具.vbs`（或其桌面快捷方式）→ 输入安卓 ID → 生成 → 自动复制，带历史记录（存 `tools/license/history.json`，gitignore）。等价命令：`uv run tools/license/license_gui.py`。GUI 直接 import `gen_license`，启动失败查 `%TEMP%\shengwuji_license_gui.log`。
2. **安卓 APP**：`tools/license-keygen-android/`（整目录 gitignore——含掩码 secret 常量，不入公开仓库）。单 Activity 经典 View 实现，手机离线发码；`LicenseGen.kt` 移植生成/校验算法，掩码常量与主工程相同。构建：`cd tools/license-keygen-android && cmd /c gradlew.bat testDebugUnitTest assembleDebug`，产物 debug APK 传手机安装。
3. **命令行**（GUI 的底层，也是交叉验证工具）：

```bash
uv run tools/license/gen_license.py keygen                    # 首次：生成 secret（已执行过勿重复）
uv run tools/license/gen_license.py issue <androidId>         # 给用户发码
uv run tools/license/gen_license.py verify <androidId> <code> # 与 App 内实现交叉验证
uv run tools/license/gen_license.py kotlinc                   # 输出 secret 掩码常量（换 secret 时重贴）
```

⚠️ **换 secret 同步点（2026-09-21 起）**：secret.txt（明文唯一）、主工程 `MainActivity.kt` 掩码常量、发码 APP `LicenseGen.kt` 掩码常量——后两者都由 `gen_license.py kotlinc` 输出重贴；随后**所有已付费用户重发码**（旧 secret 下发的码全部失效）。

## 安卓 ID

- `MainActivity.getAndroidId`：`Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)`，channel `com.shengwuji.app/app`。
- 授权码仅在输入瞬间与本机安卓 ID 比对；解锁后持久化 `is_pro_unlocked` 不再依赖它。恢复出厂/部分换机场景安卓 ID 会变 ⇒ 旧码不匹配，需重新申请（预期行为，防一码多用）。

## 7 天试用

| 项 | 值 |
|---|---|
| prefs key | `pro_trial_deadline_ms`（long，epoch 毫秒；0/缺失 = 从未开过） |
| 时长 | 7 天（`ProGate.trialDuration`） |
| 一次性 | `startTrial()` 仅 deadline==0 时写入；过期后不可重开 |
| 判定 | `isProActive = is_pro_unlocked ‖ now < deadline`（`ProGate.isProActiveWithPrefs` 纯函数，注入时钟可测） |

试用到期后的行为（双侧判定同一组 key）：

- **悬浮窗按键（Kotlin，即时）**：`VolumeKeyAccessibilityService.isProUnlocked()` 同判两 key，过期立刻拦截。
- **Pro 主题（Dart，下次启动回退）**：`main.dart` 启动恢复时 Pro 主题且不可用 → 回退 `default_teal` 并写回 prefs，`MainScaffold.showProExpireNotice` 首帧 SnackBar 提示一次（用户拍板"下次启动回退"，当次会话不强行中断）。

## 存量用户处理（2026-09-19 拍板）

旧版（君子协定）用户点一下就写入 `is_pro_unlocked=true`，无法从他们处收费。处理方式是**判定升级而非物理刷字段**：

- 永久解锁 = `is_pro_unlocked=true` **且** 存在授权码记录 `pro_license_code`（输码验证通过时两 key 一起写）。裸布尔不构成解锁。
- 效果等同"升级后把旧字段刷成 false"：存量用户升级新版即失效，走试用 7 天或输码流程；且避免了物理刷写的两个坑——Flutter prefs 的 Dart 内存缓存感知不到 Kotlin 直改文件、无迁移标志会误踢真输码用户。
- 不物理删除旧布尔（留作"曾解锁过"痕迹，判定不依赖它）。
- 确有付费的存量用户找开发者用 `gen_license.py issue <安卓ID>` 补码即可。
- 双侧判定点：Dart `ProGate.isUnlocked/isProActiveWithPrefs`、Kotlin `isProUnlocked()`（三 key 同语义，必须同步改）。

## 门禁点清单

| 位置 | 文件 | 机制 |
|---|---|---|
| 主题/图标包点击 | `lib/settings_tab.dart` `_onThemeTap` / `_onIconPackTap` | `await ProGate.tryAccess(context)`，弹窗内试用/输码成功返回 true 继续应用 |
| 悬浮窗/音量键设置页 | `lib/settings/overlay_settings_page.dart` / `volume_key_settings_page.dart` | 同 `ProGate.tryAccess` |
| 悬浮窗按键触发 | `VolumeKeyAccessibilityService.blockOverlayIfProLocked`（3 个挂点） | 拦截 + 「暂未解锁」提示胶囊（见 floating-window.md），放行 toggle 隐藏/停止分支 |
| Pro 主题启动恢复 | `lib/main.dart` | 不可用 → 回退默认青 + 提示 |

## ProUnlockDialog（解锁引导弹窗）

`lib/widgets/pro_unlock_dialog.dart`，`show()` 返回 `Future<bool>`（关闭时 Pro 是否已可用，调用方据此继续原操作）。按钮层级：

1. 主实心金「扫码支付 ¥5 解锁」→ 付款方式弹层 → 全屏付款码（长按存相册）
2. 浅金描边「输入授权码解锁」→ 子弹层（TextField + 粘贴 + 格式预校验 + channel 验证，通过写 `is_pro_unlocked` 逐层 pop(true)）
3. 灰描边「先免费试用 7 天」（仅未开过试用显示；试用中显示剩余天数文案）

信息行：本机安卓 ID（一键复制）、开发者邮箱 `LicenseService.kSupportEmail`（一键复制）。旧「已扫码点击解锁 / 先使用后续付费」君子协定出口已删除。

## 测试与验证

- `test/pro_gate_test.dart`：试用窗口边界（恰好到期/过期/一次性/永久解锁）、默认路径（真实时钟）。
- `test/license_service_test.dart`：normalize 与 base32 格式预校验。
- `test/pro_unlock_dialog_test.dart`：三态按钮布局、试用写入、授权码验证通过/不匹配（channel mock）。
- Kotlin 校验逻辑无单测基建，靠 `gen_license.py verify` 交叉验证 + 真机验证。

## 关键文件

| 文件 | 说明 |
|---|---|
| `tools/license/gen_license.py` | 授权码生成/验证/密钥工具（secret.txt 已 gitignore） |
| `tools/license/license_gui.py` | 发码 GUI（tkinter，复用 gen_license 算法；history.json 已 gitignore） |
| `tools/license/授权码工具.vbs` | GUI 启动器（隐藏控制台跑 uv，日志落 %TEMP%） |
| `tools/license-keygen-android/` | 安卓发码 APP（本地 gitignore；LicenseGen.kt 算法移植 + 掩码常量） |
| `android/.../MainActivity.kt` | `getAndroidId` / `verifyLicenseCode` / base32 解码 / secret 掩码常量 |
| `lib/utils/license_service.dart` | channel 封装 + 收款邮箱常量 + 格式预校验 |
| `lib/utils/pro_gate.dart` | 门禁判定（永久解锁 + 试用窗口）+ tryAccess |
| `lib/widgets/pro_unlock_dialog.dart` | 解锁引导弹窗 + 授权码输入弹层 |

## Changelog

| 日期 | 变更 |
|---|---|
| 2026-09-19 | 授权码体系 + 7 天试用落地，替换君子协定解锁；新拟物主题 Pro 化 |
| 2026-09-19 | 存量君子协定用户失效处理：永久解锁判定升级为「解锁布尔 + 授权码记录」双要素（判定升级，非物理刷字段） |
| 2026-09-21 | 发码工具 GUI 化：license_gui.py（输入框/复制/历史记录）+ 授权码工具.vbs 启动器，算法仍单点在 gen_license.py |
| 2026-09-21 | 安卓发码 APP：tools/license-keygen-android/ 独立最小工程（整目录 gitignore），固定盐单测与 Python 端逐字符对拍；换 secret 同步点从两处变三处 |
