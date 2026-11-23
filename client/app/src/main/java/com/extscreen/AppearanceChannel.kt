package com.extscreen

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class AppearanceChannel(context: Context, messenger: BinaryMessenger) : AutoCloseable {
    private val prefs = context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, "extscreen/appearance")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> result.success(mapOf(
                    "language" to prefs.getString("language", null),
                    "dark" to if (prefs.contains("dark")) prefs.getBoolean("dark", false) else null
                ))
                "setLanguage" -> {
                    val language = call.arguments as? String
                    if (language == "zh" || language == "en") {
                        prefs.edit().putString("language", language).apply()
                        result.success(null)
                    } else result.error("language", "Expected en or zh", null)
                }
                "setDark" -> {
                    val dark = call.arguments as? Boolean
                    if (dark != null) {
                        prefs.edit().putBoolean("dark", dark).apply()
                        result.success(null)
                    } else result.error("dark", "Expected boolean", null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun close() {
        channel.setMethodCallHandler(null)
    }
}
