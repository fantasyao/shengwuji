package com.shengwuji.app

import android.content.Context
import android.os.Build
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 原生侧运行日志（无障碍服务等 Kotlin 代码的落盘通道）。
 *
 * 背景：println 只进 logcat，应用内「导出运行日志」拿不到原生侧内容——
 * 音量键手势状态机整条跑在无障碍服务里（App 未打开也在跑），没有落盘日志
 * 就无法事后排查（2026-10-17 vivo 单击音量键失效反馈：Dart 日志里完全没有
 * 按键事件，无从判定是事件没到、分支走错还是系统拦截）。
 *
 * 写到 cacheDir/runtime_log_native.txt（与 Dart AppLogger 的 runtime_log.txt
 * 同目录，path_provider 的 getTemporaryDirectory 即 cacheDir），导出时由
 * AppLogger.exportAndShare 合进单个导出文件。刻意与 Dart 文件分开：两侧都持有
 * append 句柄，写同一文件会交错/压缩互踩。
 *
 * 日志按行数压缩：超过高水位 COMPACT_THRESHOLD 行时重写为「压缩标记 + 最新
 * 原生会话头 + 最近 KEEP_LINES 行」。会话头含品牌/型号/DISPLAY/SDK，固定置顶
 * ——压缩不能把它滚掉。无障碍服务可能长期不重启，只在 init 轮转会让文件无限
 * 变长，所以运行期也要压缩。临时文件 + rename 保证导出读方看到完整文件。
 *
 * 铁律：任何失败只吞掉，绝不能抛——跑在无障碍服务里，崩溃会连带杀进程。
 */
object NativeRuntimeLog {

    private const val FILE_NAME = "runtime_log_native.txt"

    // 压缩后保留的最近行数；行数高水位避免每写一行都重写整个文件
    private const val KEEP_LINES = 1000
    private const val COMPACT_THRESHOLD = 2000

    private val lock = Any()
    private var logFile: File? = null
    private var lineCount = 0
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    /** 初始化并写会话头。幂等（重复调用只补一行会话头，便于按服务重建分段）。 */
    fun init(context: Context) {
        try {
            val dir = context.cacheDir
            val file = File(dir, FILE_NAME)
            synchronized(lock) {
                if (logFile == null) {
                    lineCount = loadOrCompact(file)
                    logFile = file
                }
                writeLine(
                    "=== 原生会话开始 ${isoNow()} | ${Build.MANUFACTURER} ${Build.MODEL} " +
                        "| ${Build.DISPLAY} | SDK ${Build.VERSION.SDK_INT} ==="
                )
            }
        } catch (_: Exception) {
        }
    }

    /** 追加一条日志：同时进 logcat（println）与落盘文件。未 init 时只 println。 */
    fun log(message: String) {
        println(message)
        try {
            val file = logFile ?: return
            synchronized(lock) {
                writeLine(message, file)
            }
        } catch (_: Exception) {
        }
    }

    private fun writeLine(message: String, file: File? = logFile) {
        val f = file ?: return
        val ts = timeFormat.format(Date())
        f.appendText("[$ts] $message\n")
        lineCount++
        if (lineCount > COMPACT_THRESHOLD) compact(f)
    }

    /** 读现有文件行数；超过高水位先压缩。读失败按 0 处理，后续追加照常。 */
    private fun loadOrCompact(file: File): Int {
        if (!file.exists()) return 0
        return try {
            val lines = file.readLines()
            if (lines.size <= COMPACT_THRESHOLD) lines.size
            else compactLines(file, lines) ?: lines.size
        } catch (_: Exception) {
            0
        }
    }

    private fun compact(file: File) {
        try {
            val lines = file.readLines()
            val count = compactLines(file, lines)
            if (count != null) lineCount = count
        } catch (_: Exception) {
        }
    }

    /** 重写为「压缩标记 + 最新会话头 + 最近 KEEP_LINES 行」。 */
    private fun compactLines(file: File, lines: List<String>): Int? {
        if (lines.isEmpty()) return 0
        val headerIndex = lines.indexOfLast { it.startsWith("=== 原生会话开始") }
        val header = if (headerIndex >= 0) lines[headerIndex] else null
        val tail = ArrayList<String>(KEEP_LINES)
        for (i in lines.indices.reversed()) {
            if (i == headerIndex) continue
            if (tail.size >= KEEP_LINES) break
            tail.add(lines[i])
        }
        tail.reverse()

        val out = StringBuilder()
        out.append("=== 日志压缩：设备信息固定置顶，保留最近 $KEEP_LINES 行 ===\n")
        if (header != null) out.append(header).append('\n')
        for (line in tail) out.append(line).append('\n')

        val tmp = File(file.parentFile, file.name + ".tmp")
        return try {
            tmp.writeText(out.toString())
            if (!tmp.renameTo(file)) {
                if (file.exists()) file.delete()
                if (!tmp.renameTo(file)) {
                    tmp.delete()
                    return null
                }
            }
            1 + (if (header != null) 1 else 0) + tail.size
        } catch (_: Exception) {
            try {
                tmp.delete()
            } catch (_: Exception) {
            }
            null
        }
    }

    private fun isoNow(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
}
