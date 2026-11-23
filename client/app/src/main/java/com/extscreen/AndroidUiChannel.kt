package com.extscreen

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Each UI engine observes its own native activity. All callbacks run on the Android UI thread. */
internal class AndroidUiChannel(
    messenger: BinaryMessenger,
    private val state: () -> Map<String, Any?>,
    onCall: MethodChannel.MethodCallHandler
) : AutoCloseable, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "extscreen/android")
    private val events = EventChannel(messenger, "extscreen/android/events")
    private var listener: EventChannel.EventSink? = null
    private var lastState: Map<String, Any?>? = null

    init {
        methods.setMethodCallHandler(onCall)
        events.setStreamHandler(this)
    }

    fun publish() {
        val sink = listener ?: return
        val current = state()
        if (current == lastState) return
        lastState = current
        sink.success(current)
    }

    fun notify(method: String) {
        methods.invokeMethod(method, null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        listener = events
        lastState = null
        publish()
    }

    override fun onCancel(arguments: Any?) {
        listener = null
        lastState = null
    }

    override fun close() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        listener = null
    }
}
