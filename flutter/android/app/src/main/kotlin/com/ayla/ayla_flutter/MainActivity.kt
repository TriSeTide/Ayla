package com.ayla.ayla_flutter

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Ayla Flutter 主 Activity。
 *
 * 2026-10-18 新增：应用内更新需要把下载好的 APK 交给系统安装器。
 * Flutter 侧没有公开插件能做 `content://` + 读权限授予，故用最小 MethodChannel：
 *
 *   channel = com.ayla.ayla_flutter/update
 *   method  = installApk { path: String } -> Boolean
 *
 * 安全边界：
 * - 只接受应用缓存目录（cacheDir）下的普通文件，拒绝任意路径；
 * - 用 FileProvider 生成 content://，只授予读权限；
 * - 未声明 provider 时返回 false（Flutter 侧退化为打开下载页），不崩溃。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.ayla.ayla_flutter/update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(installApk(path))
                        } catch (error: Exception) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String): Boolean {
        val file = File(path).canonicalFile
        val cacheRoot = cacheDir.canonicalFile
        if (!file.exists() || !file.isFile) return false
        if (!file.path.startsWith(cacheRoot.path + File.separator)) return false
        val authority = "$packageName.fileprovider"
        val uri: Uri = try {
            FileProvider.getUriForFile(this, authority, file)
        } catch (_: IllegalArgumentException) {
            // provider 未声明（旧工程）：明确返回 false，让 Dart 侧走下载页兜底。
            return false
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            intent.putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }
        startActivity(intent)
        return true
    }
}
