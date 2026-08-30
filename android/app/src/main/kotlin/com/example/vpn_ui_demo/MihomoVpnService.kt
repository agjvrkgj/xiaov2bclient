package com.example.vpn_ui_demo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import com.example.vpn_ui_demo.core.MihomoCore
import com.example.vpn_ui_demo.core.TunInterface
import java.io.File
import java.util.concurrent.Executors

class MihomoVpnService : VpnService() {
    private val coreExecutor = Executors.newSingleThreadExecutor()
    private var tunInterface: ParcelFileDescriptor? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopMihomo()
            ACTION_START -> {
                startForeground(NOTIFICATION_ID, buildNotification())
                val configPath = intent.getStringExtra(EXTRA_CONFIG_PATH)
                if (configPath.isNullOrBlank()) {
                    fail("缺少 Mihomo 配置文件")
                } else {
                    startMihomo(configPath)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startMihomo(configPath: String) {
        coreExecutor.execute {
            try {
                if (MihomoCore.nativeIsRunning()) {
                    MihomoCore.nativeStop()
                }
                val descriptor = establishTun()
                    ?: throw IllegalStateException("Android 无法建立 VPN TUN 接口")
                tunInterface = descriptor
                val detachedFd = descriptor.detachFd()
                tunInterface = null

                val homeDirectory = File(filesDir, "mihomo").apply { mkdirs() }
                var nativeCallReturned = false
                val error = try {
                    MihomoCore.nativeStart(
                        homeDirectory.absolutePath,
                        configPath,
                        detachedFd,
                        object : TunInterface {
                            override fun protect(fd: Int): Boolean = this@MihomoVpnService.protect(fd)
                        },
                    ).also { nativeCallReturned = true }
                } finally {
                    if (!nativeCallReturned) {
                        runCatching { ParcelFileDescriptor.adoptFd(detachedFd).close() }
                    }
                }
                if (error != null) {
                    throw IllegalStateException(error)
                }
                running = true
                starting = false
                lastError = null
            } catch (error: Throwable) {
                fail(error.message ?: error.javaClass.simpleName)
            }
        }
    }

    private fun establishTun(): ParcelFileDescriptor? {
        val builder = Builder()
            .setSession("XiaoV2B · Mihomo")
            .setMtu(9000)
            .addAddress(TUN_ADDRESS, 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(TUN_DNS)

        // Keep the host app and Mihomo's outbound sockets outside the tunnel.
        // The native socket hook additionally calls VpnService.protect().
        runCatching { builder.addDisallowedApplication(packageName) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        return builder.establish()
    }

    private fun stopMihomo() {
        coreExecutor.execute {
            runCatching {
                if (MihomoCore.nativeIsRunning()) {
                    MihomoCore.nativeStop()
                }
            }.onFailure { lastError = it.message }
            tunInterface?.close()
            tunInterface = null
            running = false
            starting = false
            removeForegroundNotification()
            stopSelf()
        }
    }

    private fun fail(message: String) {
        lastError = message
        running = false
        starting = false
        runCatching {
            if (MihomoCore.nativeIsRunning()) {
                MihomoCore.nativeStop()
            }
        }
        tunInterface?.close()
        tunInterface = null
        removeForegroundNotification()
        stopSelf()
    }

    override fun onRevoke() {
        stopMihomo()
        super.onRevoke()
    }

    override fun onDestroy() {
        if (running || starting) {
            runCatching {
                if (MihomoCore.nativeIsRunning()) {
                    MihomoCore.nativeStop()
                }
            }
        }
        tunInterface?.close()
        tunInterface = null
        running = false
        starting = false
        coreExecutor.shutdown()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "VPN 连接",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Mihomo VPN 运行状态"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("XiaoV2B 已连接")
            .setContentText("Mihomo 正在保护设备流量")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    @Suppress("DEPRECATION")
    private fun removeForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    companion object {
        const val ACTION_START = "com.example.vpn_ui_demo.action.START_MIHOMO"
        const val ACTION_STOP = "com.example.vpn_ui_demo.action.STOP_MIHOMO"
        const val EXTRA_CONFIG_PATH = "config_path"

        private const val NOTIFICATION_CHANNEL_ID = "mihomo_vpn"
        private const val NOTIFICATION_ID = 19090
        private const val TUN_ADDRESS = "198.18.0.1"
        private const val TUN_DNS = "198.18.0.2"

        @Volatile var starting: Boolean = false
            private set
        @Volatile var running: Boolean = false
            private set
        @Volatile var lastError: String? = null
            private set

        fun prepareStart() {
            starting = true
            running = false
            lastError = null
        }
    }
}
