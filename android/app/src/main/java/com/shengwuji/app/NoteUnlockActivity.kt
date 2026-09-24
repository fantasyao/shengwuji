package com.shengwuji.app

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.Toast
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * 笔记解锁的透明认证 Activity（无 UI，只承载系统认证对话框）。
 *
 * 两条认证路径按锁屏状态分流（onCreate 一次性完成即 finish）：
 * - 锁屏中（isKeyguardLocked）：指纹/面部传感器由系统 Keyguard 持有，App 内
 *   BiometricPrompt 会与锁屏抢传感器（秒失败/对话框被压在锁屏后）——改走
 *   requestDismissKeyguard 弹系统解锁界面（闹钟类 App 同款），用户指纹解锁
 *   手机即视为通过。副作用：看锁定笔记 = 顺手解锁了手机，符合直觉可接受
 * - 未锁屏：androidx.biometric 标准对话框，BIOMETRIC_WEAK | DEVICE_CREDENTIAL
 *   （指纹/面部优先，锁屏密码兜底；无自设密码，不存在忘密码丢数据）
 *
 * 为什么独立 Activity 而不是挂在 MainActivity：androidx.biometric 要求宿主
 * FragmentActivity（MainActivity 是 FlutterActivity，改继承牵连面大）；且
 * 悬浮窗从锁屏发起时主 App 多半在后台，后台 Activity 弹 BP/申请 dismiss
 * keyguard 都不可靠——本 Activity setShowWhenLocked + turnScreenOn 由服务
 * 直接拉起，前台可靠。主题用 AppCompat 透明变体（androidx.biometric 的
 * API<28 兼容对话框要求 AppCompat 主题，styles.xml NoteUnlockTheme）。
 */
class NoteUnlockActivity : FragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val source = intent?.getStringExtra("source") ?: "app"

        // 锁屏之上显示（悬浮窗从锁屏页拉起本 Activity 时必要；同 MainActivity
        // applyLockScreenFlagsIfNeeded 的 API 27+ 分支写法）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        when {
            // 无锁屏凭据：认证无从谈起（insecure keyguard 下 requestDismissKeyguard
            // 会直接免验证成功，等于没认证——必须先拦）
            !km.isDeviceSecure -> {
                Toast.makeText(this, "请先在系统设置中开启锁屏密码或指纹，才能解锁笔记", Toast.LENGTH_LONG).show()
                println("🔒 [NoteUnlock] 设备无锁屏凭据，拒绝认证")
                finishWith(source, false, "no_device_credential")
            }
            km.isKeyguardLocked -> {
                println("🔒 [NoteUnlock] 锁屏中 → requestDismissKeyguard（系统解锁界面）")
                km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        println("✅ [NoteUnlock] 系统解锁成功（视为笔记认证通过）")
                        finishWith(source, true, null)
                    }
                    override fun onDismissError() {
                        println("❌ [NoteUnlock] requestDismissKeyguard 出错")
                        finishWith(source, false, "dismiss_error")
                    }
                    override fun onDismissCancelled() {
                        println("🔒 [NoteUnlock] 用户取消了系统解锁")
                        finishWith(source, false, "cancelled")
                    }
                })
            }
            else -> showBiometricPrompt(source)
        }
    }

    private fun showBiometricPrompt(source: String) {
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    println("✅ [NoteUnlock] 生物识别认证通过")
                    finishWith(source, true, null)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    // USER_CANCELED / NEGATIVE_BUTTON / TIMEOUT 等一律视为未通过
                    println("❌ [NoteUnlock] 生物识别失败 code=$errorCode: $errString")
                    finishWith(source, false, "cancelled")
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("解锁加密笔记")
            .setSubtitle("验证指纹后可查看锁定的笔记")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()
        prompt.authenticate(info)
    }

    private fun finishWith(source: String, success: Boolean, reason: String?) {
        NoteUnlockCoordinator.complete(this, source, success, reason)
        finish()
    }
}
