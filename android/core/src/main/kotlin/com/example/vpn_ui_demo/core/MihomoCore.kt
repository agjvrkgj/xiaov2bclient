package com.example.vpn_ui_demo.core

object MihomoCore {
    external fun nativeStart(
        homeDirectory: String,
        configPath: String,
        tunFd: Int,
        callback: TunInterface,
    ): String?

    external fun nativeStop()

    external fun nativeIsRunning(): Boolean

    init {
        System.loadLibrary("xiaov2b_core")
    }
}
