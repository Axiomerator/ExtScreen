package com.extscreen

import android.content.Context
import android.content.res.Configuration
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class AppearanceChannel(
    private val context: Context,
    messenger: BinaryMessenger,
    private val applyBars: (Boolean) -> Unit
) : AutoCloseable {
    private val prefs = context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, "extscreen/appearance")

    private fun themeMode(): String? = when (val saved = prefs.getString("themeMode", null)) {
        "system", "light", "dark" -> saved
        else -> if (prefs.contains("dark")) {
            if (prefs.getBoolean("dark", false)) "dark" else "light"
        } else null
    }

    fun syncSystemBars() {
        applyBars(
            when (themeMode()) {
                "dark" -> true
                "light" -> false
                else -> (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                    Configuration.UI_MODE_NIGHT_YES
            }
        )
    }

    private fun setThemeMode(mode: String) {
        val edit = prefs.edit().putString("themeMode", mode)
        if (mode == "system") edit.remove("dark")
        else edit.putBoolean("dark", mode == "dark")
        edit.apply()
        syncSystemBars()
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    val mode = themeMode()
                    result.success(mapOf(
                        "language" to prefs.getString("language", null),
                        "themeMode" to (mode ?: "system"),
                        "dark" to when (mode) {
                            "dark" -> true
                            "light" -> false
                            else -> null
                        }
                    ))
                }
                "setLanguage" -> {
                    val language = call.arguments as? String
                    if (language == "zh" || language == "en") {
                        prefs.edit().putString("language", language).apply()
                        result.success(null)
                    } else result.error("language", "Expected en or zh", null)
                }
                "setThemeMode" -> {
                    val mode = call.arguments as? String
                    if (mode == "system" || mode == "light" || mode == "dark") {
                        setThemeMode(mode)
                        result.success(null)
                    } else result.error("themeMode", "Expected system, light or dark", null)
                }
                "setDark", "setEffectiveDark" -> {
                    val dark = call.arguments as? Boolean
                    if (dark != null) {
                        if (call.method == "setDark") setThemeMode(if (dark) "dark" else "light")
                        else applyBars(dark)
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
