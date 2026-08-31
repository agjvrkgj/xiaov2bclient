package com.example.vpn_ui_demo.core

import androidx.annotation.Keep

@Keep
interface TunInterface {
    fun protect(fd: Int): Boolean
}
