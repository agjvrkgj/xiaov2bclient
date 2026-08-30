package com.example.vpn_ui_demo

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingConfigPath: String? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MIHOMO_CHANNEL,
        ).setMethodCallHandler(::handleMihomoCall)
    }

    private fun handleMihomoCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> requestVpn(call.argument<String>("config"), result)
            "stop" -> {
                startService(
                    Intent(this, MihomoVpnService::class.java).apply {
                        action = MihomoVpnService.ACTION_STOP
                    },
                )
                result.success(null)
            }
            "status" -> result.success(
                mapOf(
                    "running" to MihomoVpnService.running,
                    "starting" to MihomoVpnService.starting,
                    "error" to MihomoVpnService.lastError,
                ),
            )
            else -> result.notImplemented()
        }
    }

    private fun requestVpn(config: String?, result: MethodChannel.Result) {
        if (config.isNullOrBlank()) {
            result.error("INVALID_CONFIG", "Mihomo 配置为空", null)
            return
        }
        if (pendingResult != null) {
            result.error("VPN_PERMISSION_PENDING", "正在等待 VPN 授权", null)
            return
        }

        val runtimeDirectory = File(filesDir, "mihomo").apply { mkdirs() }
        val configFile = File(runtimeDirectory, "config.json")
        configFile.writeText(config)

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent == null) {
            startMihomoService(configFile.absolutePath)
            result.success(true)
            return
        }

        pendingConfigPath = configFile.absolutePath
        pendingResult = result
        startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST)
    }

    private fun startMihomoService(configPath: String) {
        MihomoVpnService.prepareStart()
        val intent = Intent(this, MihomoVpnService::class.java).apply {
            action = MihomoVpnService.ACTION_START
            putExtra(MihomoVpnService.EXTRA_CONFIG_PATH, configPath)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != VPN_PERMISSION_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingResult
        val configPath = pendingConfigPath
        pendingResult = null
        pendingConfigPath = null
        if (resultCode == Activity.RESULT_OK && configPath != null) {
            startMihomoService(configPath)
            result?.success(true)
        } else {
            result?.error("VPN_PERMISSION_DENIED", "用户未授予 VPN 权限", null)
        }
    }

    companion object {
        private const val MIHOMO_CHANNEL = "xiaov2b/mihomo"
        private const val VPN_PERMISSION_REQUEST = 1909
    }
}
