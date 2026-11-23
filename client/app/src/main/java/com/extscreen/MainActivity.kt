package com.extscreen

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.graphics.RectF
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.util.Log
import android.hardware.display.DisplayManager
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.pow

enum class PressureCurve(val gamma: Float) {
    LINEAR(1.0f), SOFT(0.65f), FIRM(1.35f), HARD(1.8f)
}

enum class BarrelButtonMapping { RIGHT_CLICK, ERASER }

enum class TouchMode { ALL_TOUCH, PEN_ONLY, TWO_FINGER_SCROLL }

class MainActivity : Activity(), SurfaceHolder.Callback, View.OnTouchListener, View.OnGenericMotionListener {
    private lateinit var surfaceView: SurfaceView
    private lateinit var inkOverlayView: InkOverlayView
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var controlsView: StreamControlsView
    private lateinit var controlsEngine: FlutterEngine
    private var ui: AndroidUiChannel? = null
    private var appearance: AppearanceChannel? = null
    private var diagnostics = false
    private var minimap = true
    private var shortcuts = false
    private val heldKeys = mutableSetOf<Int>()
    private var lastLinkStatus = NativeEngine.STATUS_DISCONNECTED

    private lateinit var store: ConnectionStore
    private var target: Target = Target.USB
    private var targetHostId: String? = null
    private var pinUsed = ""
    private var wifiLock: WifiManager.WifiLock? = null
    private var lastBackPress = 0L
    private var leaving = false
    private var aoaBridge: AoaBridge? = null
    private var usbReceiver: BroadcastReceiver? = null
    private var tetherRediscoveryActive = false
    private var disconnectedSinceMs = 0L
    private var lastTetherIfaceSpec: String? = null

    /**
     * Frame rate the host streams at and the panel is asked to run at: the panel's highest
     * refresh rate at its current size (144 Hz on the Pad 7). A stream below the panel's rate
     * makes it repeat frames unevenly, which reads as jitter.
     */
    private var reportedFps = 0

    /** Tells the host when the panel starts running faster than it was told (the PC follows). */
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != windowManager.defaultDisplay.displayId) return
            val now = windowManager.defaultDisplay.refreshRate.toInt()
            // Only upward: the panel idles at lower rates when the picture is still, and the
            // PC's monitor must not be switched back and forth for that.
            if (reportedFps in 1 until now) {
                reportedFps = now
                if (customFps == null) NativeEngine.updateStreamSettings(now, 0)
            }
        }
    }

    private val panelFps: Float by lazy {
        val display = windowManager.defaultDisplay
        val size = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == size.physicalWidth && it.physicalHeight == size.physicalHeight }
            .maxOfOrNull { it.refreshRate } ?: display.refreshRate
        minOf(best, MAX_STREAM_FPS)
    }

    // Client-side viewport: the decoded video is scaled/translated locally, so zoom costs no
    // bandwidth or latency. Input is mapped back through the inverse transform before it is
    // sent to Windows, so taps and pen strokes land where they appear on the zoomed picture.
    private var zoomScale = 1f
    private var panX = 0f
    private var panY = 0f
    private var pinchZoomEnabled = true

    // Pen, touch and stream settings.
    private var touchMode = TouchMode.ALL_TOUCH
    private var penOnlyMode = false
    private var currentPressureCurve = PressureCurve.LINEAR
    private var barrelMapping = BarrelButtonMapping.RIGHT_CLICK
    private var inkMode = InkOverlayView.InkMode.FADE
    private var scrollPrevY = 0f
    private var customFps: Int? = null
    private var currentBitrateKbps = NativeEngine.BITRATE_AUTO

    private fun streamState(): Map<String, Any?> {
        val width = surfaceView.width.coerceAtLeast(1)
        val height = surfaceView.height.coerceAtLeast(1)
        val left = -panX / (width * zoomScale)
        val top = -panY / (height * zoomScale)
        return mapOf(
            "status" to lastLinkStatus,
            "peerName" to NativeEngine.getHostName().ifEmpty { target.name },
            "usbTether" to target.isUsbTether,
            "directUsb" to target.isUsb,
            "estimatedWidth" to surfaceView.width,
            "estimatedHeight" to surfaceView.height,
            "fps" to (customFps ?: reportedFps.takeIf { it > 0 } ?: panelFps.toInt()),
            "maxFps" to panelFps.toInt(),
            "bitrateKbps" to currentBitrateKbps,
            "rttUs" to if (diagnostics) NativeEngine.getRoundTripLatencyUs() else 0L,
            "packetsSent" to if (diagnostics) NativeEngine.getSentPacketsCount() else 0L,
            "touchMode" to touchMode.name,
            "pressureCurve" to currentPressureCurve.name,
            "barrelMapping" to barrelMapping.name,
            "inkMode" to inkMode.name,
            "pinchZoom" to pinchZoomEnabled,
            "diagnostics" to diagnostics,
            "minimap" to minimap,
            "shortcuts" to shortcuts,
            "heldKeys" to heldKeys.toList(),
            "viewport" to mapOf(
                "scale" to zoomScale,
                "left" to left.coerceIn(0f, 1f),
                "top" to top.coerceIn(0f, 1f),
                "right" to (left + 1f / zoomScale).coerceIn(0f, 1f),
                "bottom" to (top + 1f / zoomScale).coerceIn(0f, 1f)
            ),
            "diagnosticData" to if (diagnostics) mapOf(
                "toolType" to inkOverlayView.lastToolType,
                "pressure" to inkOverlayView.lastPressure,
                "tiltX" to inkOverlayView.lastTiltX,
                "tiltY" to inkOverlayView.lastTiltY,
                "sampleRateHz" to inkOverlayView.sampleRateHz
            ) else null
        )
    }

    private fun handleUiCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStreamState" -> result.success(streamState())
            "setStreamOptions" -> {
                setStreamOptions(call)
                ui?.publish()
                result.success(streamState())
            }
            "streamHitAreas" -> {
                val regions = call.argument<List<Map<String, Number>>>("rects").orEmpty().mapNotNull { r ->
                    val left = r["left"]?.toFloat() ?: return@mapNotNull null
                    val top = r["top"]?.toFloat() ?: return@mapNotNull null
                    val right = r["right"]?.toFloat() ?: return@mapNotNull null
                    val bottom = r["bottom"]?.toFloat() ?: return@mapNotNull null
                    if (left < right && top < bottom) RectF(left, top, right, bottom) else null
                }
                controlsView.setHitAreas(call.argument<Boolean>("modal") == true, regions)
                result.success(null)
            }
            "resetZoom" -> {
                resetZoom()
                result.success(streamState())
            }
            "clearInk" -> {
                inkOverlayView.clearCanvas()
                result.success(null)
            }
            "sendKey" -> {
                val key = call.argument<Int>("code")
                val action = call.argument<Int>("action")
                val modifiers = call.argument<Int>("modifiers") ?: NativeEngine.MOD_NONE
                if (key != null && action != null && lastLinkStatus == NativeEngine.STATUS_CONNECTED) {
                    when (action) {
                        NativeEngine.KEY_ACTION_DOWN -> heldKeys.add(key)
                        NativeEngine.KEY_ACTION_UP -> heldKeys.remove(key)
                    }
                    NativeEngine.sendKeyEvent(key, action, modifiers)
                    ui?.publish()
                }
                result.success(null)
            }
            "disconnect" -> {
                result.success(null)
                returnToConnect(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun setStreamOptions(call: MethodCall) {
        fun <T : Enum<T>> select(key: String, values: Array<T>): T? {
            val value = call.argument<String>(key)
            return values.firstOrNull { it.name == value }
        }
        select("touchMode", TouchMode.values())?.let {
            touchMode = it
            penOnlyMode = it == TouchMode.PEN_ONLY
        }
        select("pressureCurve", PressureCurve.values())?.let { currentPressureCurve = it }
        select("barrelMapping", BarrelButtonMapping.values())?.let { barrelMapping = it }
        select("inkMode", InkOverlayView.InkMode.values())?.let {
            inkMode = it
            inkOverlayView.inkMode = it
        }
        call.argument<Boolean>("pinchZoom")?.let {
            pinchZoomEnabled = it
            if (!it) resetZoom()
        }
        call.argument<Boolean>("diagnostics")?.let { diagnostics = it }
        call.argument<Boolean>("minimap")?.let { minimap = it }
        call.argument<Boolean>("shortcuts")?.let {
            shortcuts = it
            if (!it) releaseHeldKeys()
        }

        val fps = call.argument<Int>("fps")
        val bitrate = call.argument<Int>("bitrateKbps")
        var updatedFps = 0
        var updatedBitrate = 0
        if (fps != null && (fps == 0 || fps in 1..panelFps.toInt())) {
            customFps = fps.takeIf { it > 0 }
            updatedFps = customFps ?: reportedFps
            setSurfaceFrameRate(customFps?.toFloat() ?: panelFps)
        }
        if (bitrate != null && (bitrate == NativeEngine.BITRATE_AUTO || bitrate > 0)) {
            currentBitrateKbps = bitrate
            updatedBitrate = bitrate
        }
        if (updatedFps != 0 || updatedBitrate != 0) {
            NativeEngine.updateStreamSettings(updatedFps, updatedBitrate)
        }
    }

    private fun setSurfaceFrameRate(fps: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val surface = surfaceView.holder.surface
            if (surface.isValid) runCatching {
                surface.setFrameRate(fps, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            }
        }
    }

    private fun releaseHeldKeys() {
        for (key in heldKeys) {
            NativeEngine.sendKeyEvent(key, NativeEngine.KEY_ACTION_UP, NativeEngine.MOD_NONE)
        }
        heldKeys.clear()
    }

    private fun applyPressureCurve(rawPressure: Float): Float {
        if (rawPressure <= 0f) return 0f
        val clamped = rawPressure.coerceIn(0f, 1f)
        if (currentPressureCurve == PressureCurve.LINEAR) return clamped
        return clamped.toDouble().pow(currentPressureCurve.gamma.toDouble()).toFloat()
    }

    // Two-finger gesture state.
    private var twoFingerScrollActive = false
    private var gestureActive = false
    private var gestureNeedsAnchor = false
    private var anchorSpan = 1f
    private var anchorFocusX = 0f
    private var anchorFocusY = 0f
    private var anchorScale = 1f
    private var anchorPanX = 0f
    private var anchorPanY = 0f
    private var gestureStartTime = 0L
    private var gestureTravel = 0f
    private var lastTwoFingerTapTime = 0L

    private val statusUpdateRunnable = object : Runnable {
        override fun run() {
            if (::inkOverlayView.isInitialized) {
                val status = NativeEngine.getConnectionStatus()
                if (status != lastLinkStatus) {
                    inkOverlayView.linkStatus = status
                    inkOverlayView.invalidate()
                    if (status != NativeEngine.STATUS_CONNECTED) heldKeys.clear()
                    lastLinkStatus = status
                }
                ui?.publish()
                persistNewCredential()
                if (status == NativeEngine.STATUS_CONNECTED) {
                    disconnectedSinceMs = 0L
                    stopTetherRediscovery()
                } else if (status == NativeEngine.STATUS_NEEDS_PIN || status == NativeEngine.STATUS_AUTH_FAILED ||
                    status == NativeEngine.STATUS_TAKEN_OVER) {
                    stopTetherRediscovery()
                    returnToConnect(status)
                    return
                } else if (target.isUsbTether && targetHostId != null) {
                    maybeRediscoverUsbTetherHost()
                }
            }
            handler.postDelayed(this, 250)
        }
    }

    /**
     * Android 11+ randomizes the USB tethering subnet whenever USB tethering is toggled off and on.
     * If our USB-tethered link drops, probe active interfaces until the same PC (`targetHostId`)
     * reappears on its new USB IP, then seamlessly reconnect.
     */
    private fun maybeRediscoverUsbTetherHost() {
        val now = SystemClock.elapsedRealtime()
        if (disconnectedSinceMs == 0L) {
            disconnectedSinceMs = now
            return
        }
        if (now - disconnectedSinceMs < TETHER_REDISCOVERY_DELAY_MS) return

        val ifaces = NetworkUtils.activeInterfaces()
        val spec = NetworkUtils.toNativeSpec(ifaces)
        if (spec != lastTetherIfaceSpec) {
            lastTetherIfaceSpec = spec
            NativeEngine.setDiscoveryInterfaces(spec)
        }
        if (!tetherRediscoveryActive) {
            tetherRediscoveryActive = true
            NativeEngine.startDiscovery()
        }
        val expectedId = targetHostId ?: return
        val snapshot = NativeEngine.getDiscoveredHosts()
        for (line in snapshot.lineSequence()) {
            val parts = line.split('|')
            if (parts.size < 5) continue
            val ip = parts[0]
            val port = parts[1].toIntOrNull() ?: continue
            val name = parts[2]
            val hostId = parts[3]
            val isUsb = parts[4] == "usb"
            if (isUsb && hostId == expectedId && (ip != target.host || port != target.port)) {
                Log.i("MainActivity", "USB Tethering PC moved to $ip:$port; reconnecting automatically")
                target = Target(ip, port, name, isUsbTether = true)
                store.lastTarget = target
                disconnectedSinceMs = 0L
                stopTetherRediscovery()
                startNativeClient()
                return
            }
        }
    }

    private fun stopTetherRediscovery() {
        if (tetherRediscoveryActive) {
            tetherRediscoveryActive = false
            lastTetherIfaceSpec = null
            NativeEngine.stopDiscovery()
        }
    }

    /** A completed pairing hands over the secret once; losing it would force re-pairing. */
    private fun persistNewCredential() {
        val credential = NativeEngine.takeNewCredential()
        if (credential.isNotEmpty()) {
            store.saveCredential(credential)
            val id = credential.substringBefore(':', "")
            if (id.isNotEmpty()) targetHostId = id
            // The one-time PIN has been consumed; future reconnects must resume with the stored secret.
            pinUsed = ""
        }
    }

    /** Goes back to the connection picker, explaining why when the PC refused us. */
    private fun returnToConnect(status: Int?, usbDetached: Boolean = false) {
        if (leaving) return
        leaving = true
        stopTetherRediscovery()
        aoaBridge?.close()
        aoaBridge = null
        val message = if (status != null) NativeEngine.getLastError().takeIf(String::isNotEmpty) else null
        val name = NativeEngine.getHostName().ifEmpty { target.name }
        val notice = when {
            usbDetached -> "usbDetached"
            status == NativeEngine.STATUS_NEEDS_PIN -> "needsPin"
            status == NativeEngine.STATUS_AUTH_FAILED -> "authFailed"
            status == NativeEngine.STATUS_TAKEN_OVER -> "takenOver"
            else -> null
        }
        val needPin = status == NativeEngine.STATUS_NEEDS_PIN ||
            (status == NativeEngine.STATUS_AUTH_FAILED && pinUsed.isNotEmpty())
        NativeEngine.stopClient()
        startActivity(
            InternalIntents.mark(Intent(this, ConnectActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(ConnectActivity.EXTRA_MESSAGE, message)
                .putExtra(ConnectActivity.EXTRA_NOTICE, notice)
                .putExtra(ConnectActivity.EXTRA_NEED_PIN, needPin)
                .putExtra(ConnectActivity.EXTRA_HOST, target.host)
                .putExtra(ConnectActivity.EXTRA_PORT, target.port)
                .putExtra(ConnectActivity.EXTRA_NAME, name)
                .putExtra(ConnectActivity.EXTRA_HOST_ID, targetHostId)
                .putExtra(ConnectActivity.EXTRA_USB_TETHER, target.isUsbTether)
                .putExtra(ConnectActivity.EXTRA_NO_AUTO_CONNECT, status == null)
        )
        finish()
    }

    /** Wi-Fi power saving adds tens of milliseconds of jitter; hold the radio awake while streaming over Wi-Fi. */
    @Suppress("DEPRECATION")
    private fun updateWifiLock() {
        releaseWifiLock()
        if (target.isUsb || target.isUsbTether) return
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager ?: return
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wifi.createWifiLock(mode, "extscreen-stream").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
    }

    /**
     * Starts (or restarts) the link for the target in [intent]. Launching with no target, for
     * example from `adb shell am start`, means USB, so the cable workflow is unchanged.
     */
    private fun connectFrom(intent: Intent) {
        // A network target and PIN are accepted only from our own ConnectActivity: this activity
        // is exported, and another app must not be able to point it at a PC it controls.
        val internal = InternalIntents.isInternal(intent)
        if (!internal && (intent.hasExtra(EXTRA_HOST) || intent.hasExtra(EXTRA_PIN))) {
            Log.w("MainActivity", "Ignoring connection extras from an external caller")
        }
        val host = if (internal) intent.getStringExtra(EXTRA_HOST) else null
        val explicitNetworkHost = host != null && host != Target.USB_HOST

        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        val explicitAccessory: UsbAccessory? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
        // Only fall back to an attached USB accessory when the user did not explicitly pick a Wi-Fi host.
        val accessory: UsbAccessory? = explicitAccessory
            ?: if (!explicitNetworkHost) usbManager?.accessoryList?.firstOrNull() else null

        aoaBridge?.close()
        aoaBridge = null

        target = if (accessory != null && usbManager != null) {
            try {
                val bridge = AoaBridge(usbManager, accessory)
                aoaBridge = bridge
                Log.i("MainActivity", "AOA Direct USB mode initialized on port ${bridge.port}")
                Target("127.0.0.1", bridge.port, "Direct USB (Plug & Play)")
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to start AOA bridge: ${e.message}; falling back to default USB")
                Target.USB
            }
        } else if (host != null) {
            Target(
                host,
                intent.getIntExtra(EXTRA_PORT, Target.DEFAULT_PORT),
                intent.getStringExtra(EXTRA_NAME) ?: host,
                intent.getBooleanExtra(EXTRA_USB_TETHER, false)
            )
        } else {
            Target.USB
        }
        targetHostId = if (internal) intent.getStringExtra(EXTRA_HOST_ID) ?: store.lastHostId else null
        pinUsed = if (internal) intent.getStringExtra(EXTRA_PIN) ?: "" else ""
        leaving = false
        disconnectedSinceMs = 0L
        stopTetherRediscovery()

        updateWifiLock()
        startNativeClient()
    }

    private fun startNativeClient() {
        // The whole panel, not `displayMetrics`: that excludes the cutout/status area (3200x2006 on a
        // 3200x2136 panel), so the host would pick a virtual monitor with the wrong aspect ratio.
        val metrics = resources.displayMetrics
        val display = (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay
        val panel = android.util.DisplayMetrics().also {
            @Suppress("DEPRECATION")
            display.getRealMetrics(it)
        }
        // What the panel actually runs at, not what it could: the system may cap apps below the
        // panel's top mode (120 of 144 Hz here), and a faster stream would then be dropped unevenly.
        val refreshRate = display.refreshRate.toInt().coerceAtLeast(60)
        reportedFps = refreshRate
        NativeEngine.startClient(
            host = target.host,
            port = target.port,
            deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
            screenWidth = panel.widthPixels,
            screenHeight = panel.heightPixels,
            maxRefreshRate = customFps ?: refreshRate,
            dpi = metrics.densityDpi,
            supportsStylus = true,
            clientId = store.clientId,
            pin = pinUsed,
            credentials = store.credentials
        )
        if (currentBitrateKbps != NativeEngine.BITRATE_AUTO) {
            NativeEngine.updateStreamSettings(0, currentBitrateKbps)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        connectFrom(intent)
    }

    @Deprecated("Back is guarded: an edge swipe while drawing must not drop the connection")
    override fun onBackPressed() {
        if (controlsView.modal) {
            ui?.notify("dismissStreamMenu")
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastBackPress < BACK_CONFIRM_MS) {
            returnToConnect(null)
        } else {
            lastBackPress = now
            ui?.notify("backHint")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = ConnectionStore(this)

        val usbFilter = IntentFilter(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        usbReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == UsbManager.ACTION_USB_ACCESSORY_DETACHED) {
                    val detached: UsbAccessory? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                    }
                    if (detached == null || detached == aoaBridge?.accessory) {
                        Log.i("MainActivity", "USB accessory detached; returning to connect screen")
                        returnToConnect(null, usbDetached = true)
                    }
                }
            }
        }
        // ACCESSORY_DETACHED is a protected system broadcast; it reaches non-exported receivers.
        ContextCompat.registerReceiver(this, usbReceiver, usbFilter, ContextCompat.RECEIVER_NOT_EXPORTED)

        // Keep screen awake & full immersive fullscreen mode
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                or WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        // Draw under the camera cutout so the video covers the full panel and matches what the host streams.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
                preferredRefreshRate = panelFps
            }
        }
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        )

        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.BLACK))
        NativeEngine.initNativeLogging()

        val rootLayout = FrameLayout(this).apply {
            // Prevent a second finger from being assigned to Flutter midway through a native pinch.
            isMotionEventSplittingEnabled = false
        }

        surfaceView = SurfaceView(this).apply {
            setZOrderMediaOverlay(true)
            holder.addCallback(this@MainActivity)
            pivotX = 0f
            pivotY = 0f
        }

        inkOverlayView = InkOverlayView(this).apply {
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
            setOnTouchListener(this@MainActivity)
            setOnGenericMotionListener(this@MainActivity)
            inkMode = this@MainActivity.inkMode
        }

        rootLayout.addView(
            surfaceView,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        )
        rootLayout.addView(
            inkOverlayView,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        )
        controlsEngine = FlutterEngine(this)
        val initialRoute = "/stream"
        controlsView = StreamControlsView(this)
        controlsView.attachToFlutterEngine(controlsEngine)
        rootLayout.addView(
            controlsView,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        )
        appearance = AppearanceChannel(this, controlsEngine.dartExecutor.binaryMessenger)
        ui = AndroidUiChannel(controlsEngine.dartExecutor.binaryMessenger, ::streamState, ::handleUiCall)
        controlsEngine.navigationChannel.setInitialRoute(initialRoute)
        controlsEngine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())

        setContentView(rootLayout)
        connectFrom(intent)
    }

    override fun onResume() {
        super.onResume()
        controlsEngine.lifecycleChannel.appIsResumed()
        (getSystemService(DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayListener, handler)
        if (::inkOverlayView.isInitialized) {
            inkOverlayView.setVsyncActive(true)
        }
        handler.post(statusUpdateRunnable)
    }

    override fun onPause() {
        super.onPause()
        controlsEngine.lifecycleChannel.appIsPaused()
        releaseHeldKeys()
        (getSystemService(DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener)
        if (::inkOverlayView.isInitialized) {
            inkOverlayView.setVsyncActive(false)
        }
        handler.removeCallbacks(statusUpdateRunnable)
        stopTetherRediscovery()
        persistNewCredential()
    }

    override fun onDestroy() {
        stopTetherRediscovery()
        usbReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
            usbReceiver = null
        }
        aoaBridge?.close()
        aoaBridge = null
        appearance?.close()
        appearance = null
        ui?.close()
        ui = null
        controlsView.detachFromFlutterEngine()
        controlsEngine.destroy()
        super.onDestroy()
        persistNewCredential()
        releaseWifiLock()
        NativeEngine.stopClient()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        // Without this the panel idles at its adaptive minimum (50 Hz seen on the Pad 7) and the
        // 120 fps stream is presented unevenly, which reads as jitter.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            setSurfaceFrameRate(customFps?.toFloat() ?: panelFps)
        }
        NativeEngine.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        applyViewport()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        NativeEngine.setSurface(null)
    }

    // ---------------------------------------------------------------------------------------
    // Viewport (pinch-zoom / pan)
    // ---------------------------------------------------------------------------------------

    /** Screen X on the tablet -> normalized X on the Windows display, through the zoom. */
    private fun toNormX(x: Float, width: Float): Float = (((x - panX) / zoomScale) / width).coerceIn(0f, 1f)

    private fun toNormY(y: Float, height: Float): Float = (((y - panY) / zoomScale) / height).coerceIn(0f, 1f)

    private fun applyViewport() {
        val w = surfaceView.width.toFloat()
        val h = surfaceView.height.toFloat()
        if (w <= 0f || h <= 0f) return

        zoomScale = zoomScale.coerceIn(1f, MAX_ZOOM)
        // Keep the picture covering the whole screen: no black gaps at the edges.
        panX = panX.coerceIn(w - w * zoomScale, 0f)
        panY = panY.coerceIn(h - h * zoomScale, 0f)

        surfaceView.scaleX = zoomScale
        surfaceView.scaleY = zoomScale
        surfaceView.translationX = panX
        surfaceView.translationY = panY

        inkOverlayView.setViewport(zoomScale, panX, panY)
    }

    private fun resetZoom() {
        zoomScale = 1f
        panX = 0f
        panY = 0f
        inkOverlayView.clearCanvas()
        applyViewport()
        ui?.publish()
    }

    private fun anchorGesture(event: MotionEvent, skipIndex: Int = -1) {
        val idx = twoPointerIndices(event, skipIndex) ?: return
        val (a, b) = idx
        anchorSpan = hypot(event.getX(a) - event.getX(b), event.getY(a) - event.getY(b)).coerceAtLeast(1f)
        anchorFocusX = (event.getX(a) + event.getX(b)) / 2f
        anchorFocusY = (event.getY(a) + event.getY(b)) / 2f
        anchorScale = zoomScale
        anchorPanX = panX
        anchorPanY = panY
        gestureNeedsAnchor = false
    }

    private fun twoPointerIndices(event: MotionEvent, skipIndex: Int): Pair<Int, Int>? {
        var first = -1
        for (i in 0 until event.pointerCount) {
            if (i == skipIndex) continue
            if (first < 0) first = i else return Pair(first, i)
        }
        return null
    }

    private fun updateGesture(event: MotionEvent) {
        if (gestureNeedsAnchor) {
            anchorGesture(event)
            return
        }
        val (a, b) = twoPointerIndices(event, -1) ?: return
        val span = hypot(event.getX(a) - event.getX(b), event.getY(a) - event.getY(b))
        val focusX = (event.getX(a) + event.getX(b)) / 2f
        val focusY = (event.getY(a) + event.getY(b)) / 2f

        gestureTravel = maxOf(
            gestureTravel,
            hypot(focusX - anchorFocusX, focusY - anchorFocusY),
            abs(span - anchorSpan)
        )

        // Keep the content point that was under the fingers' midpoint under it while
        // scaling, and let the midpoint's movement pan the view.
        val newScale = (anchorScale * span / anchorSpan).coerceIn(1f, MAX_ZOOM)
        val contentX = (anchorFocusX - anchorPanX) / anchorScale
        val contentY = (anchorFocusY - anchorPanY) / anchorScale
        zoomScale = newScale
        panX = focusX - contentX * newScale
        panY = focusY - contentY * newScale
        applyViewport()
    }

    private fun endGesture(eventTime: Long) {
        gestureActive = false
        if (zoomScale < 1.05f) resetZoom()

        // Two-finger double-tap resets zoom.
        val density = resources.displayMetrics.density
        val wasTap = eventTime - gestureStartTime < TAP_MAX_MS && gestureTravel < TAP_SLOP_DP * density
        if (wasTap) {
            if (eventTime - lastTwoFingerTapTime < DOUBLE_TAP_MS) {
                resetZoom()
                lastTwoFingerTapTime = 0L
            } else {
                lastTwoFingerTapTime = eventTime
            }
        }
    }

    private fun cancelActiveFinger(event: MotionEvent, index: Int, width: Float, height: Float) {
        val id = event.getPointerId(index)
        val x = event.getX(index)
        val y = event.getY(index)
        inkOverlayView.processSample(id, MotionEvent.ACTION_CANCEL, MotionEvent.TOOL_TYPE_FINGER, x, y, 0f, 0f, 0f)
        NativeEngine.sendPointerEvent(
            pointerId = id,
            action = 6, // actions::CANCEL
            toolType = MotionEvent.TOOL_TYPE_FINGER,
            normX = toNormX(x, width),
            normY = toNormY(y, height),
            pressure = 0f,
            tiltX = 0f,
            tiltY = 0f,
            buttons = 0,
            timestampUs = event.eventTime * 1000L
        )
    }

    /**
     * Consumes two-finger gestures for local zoom. Returns true when the event must not be
     * forwarded to Windows.
     */
    private fun handleZoomGesture(event: MotionEvent, width: Float, height: Float): Boolean {
        val masked = event.actionMasked

        if (!gestureActive) {
            if (!pinchZoomEnabled || masked != MotionEvent.ACTION_POINTER_DOWN || event.pointerCount != 2) {
                return false
            }
            if (event.getToolType(0) != MotionEvent.TOOL_TYPE_FINGER ||
                event.getToolType(1) != MotionEvent.TOOL_TYPE_FINGER) {
                return false
            }

            // The first finger's DOWN already reached Windows: cancel it so the gesture
            // does not turn into a click or drag on the desktop.
            if (!penOnlyMode) {
                val first = if (event.actionIndex == 0) 1 else 0
                cancelActiveFinger(event, first, width, height)
            }

            // Local ink is drawn in screen space; once the picture moves it no longer lines up.
            inkOverlayView.clearCanvas()

            gestureActive = true
            gestureStartTime = event.eventTime
            gestureTravel = 0f
            anchorGesture(event)
            return true
        }

        when (masked) {
            MotionEvent.ACTION_POINTER_DOWN -> anchorGesture(event)
            MotionEvent.ACTION_MOVE -> if (event.pointerCount >= 2) updateGesture(event)
            MotionEvent.ACTION_POINTER_UP -> {
                // Re-anchor on the remaining pair so the view does not jump.
                if (event.pointerCount > 2) anchorGesture(event, event.actionIndex) else gestureNeedsAnchor = true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> endGesture(event.eventTime)
        }
        return true
    }

    // ---------------------------------------------------------------------------------------
    // Input forwarding
    // ---------------------------------------------------------------------------------------

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        v.requestUnbufferedDispatch(event)
        val width = v.width.toFloat()
        val height = v.height.toFloat()
        if (width <= 0f || height <= 0f) return false

        val actionMasked = event.actionMasked

        if (touchMode == TouchMode.TWO_FINGER_SCROLL) {
            if (!twoFingerScrollActive && actionMasked == MotionEvent.ACTION_POINTER_DOWN && event.pointerCount >= 2) {
                val isTwoFingers = event.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER &&
                    event.getToolType(1) == MotionEvent.TOOL_TYPE_FINGER
                if (isTwoFingers) {
                    val first = if (event.actionIndex == 0) 1 else 0
                    cancelActiveFinger(event, first, width, height)
                    twoFingerScrollActive = true
                    scrollPrevY = (event.getY(0) + event.getY(1)) / 2f
                    inkOverlayView.clearCanvas()
                    return true
                }
            }
            if (twoFingerScrollActive) {
                when (actionMasked) {
                    MotionEvent.ACTION_POINTER_DOWN -> if (event.pointerCount >= 2) {
                        scrollPrevY = (event.getY(0) + event.getY(1)) / 2f
                    }
                    MotionEvent.ACTION_POINTER_UP -> {
                        // Re-anchor on the remaining pair so lifting one of 3 fingers never jumps.
                        val pair = twoPointerIndices(event, event.actionIndex)
                        if (pair != null) {
                            scrollPrevY = (event.getY(pair.first) + event.getY(pair.second)) / 2f
                        }
                    }
                    MotionEvent.ACTION_MOVE -> if (event.pointerCount >= 2) {
                        val xMid = (event.getX(0) + event.getX(1)) / 2f
                        val yMid = (event.getY(0) + event.getY(1)) / 2f
                        val deltaY = yMid - scrollPrevY
                        if (abs(deltaY) >= 2f) {
                            NativeEngine.sendScrollEventAt(toNormX(xMid, width), toNormY(yMid, height), deltaY / 12f)
                            scrollPrevY = yMid
                        }
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> twoFingerScrollActive = false
                }
                return true
            }
        }

        if (handleZoomGesture(event, width, height)) {
            return true
        }

        val historySize = event.historySize
        val pointerCount = event.pointerCount
        var sentSample = false

        // 1. Process historical high-rate stylus / touch samples (120Hz - 240Hz digitizer pacing)
        for (h in 0 until historySize) {
            val histTimeUs = event.getHistoricalEventTime(h) * 1000L
            for (p in 0 until pointerCount) {
                val toolType = event.getToolType(p)
                if (penOnlyMode && toolType == MotionEvent.TOOL_TYPE_FINGER) {
                    continue
                }
                val tiltRad = event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, p, h)
                val orientRad = event.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, p, h)
                forwardPointerSample(
                    pointerId = event.getPointerId(p),
                    overlayAction = MotionEvent.ACTION_MOVE,
                    nativeAction = 1, // actions::MOVE
                    toolType = toolType,
                    buttonState = event.buttonState,
                    x = event.getHistoricalX(p, h),
                    y = event.getHistoricalY(p, h),
                    rawPressure = event.getHistoricalPressure(p, h),
                    tiltRad = tiltRad,
                    orientRad = orientRad,
                    width = width,
                    height = height,
                    timestampUs = histTimeUs,
                    invalidateNow = false
                )
                sentSample = true
            }
        }

        // 2. Process current sample
        val actionIndex = event.actionIndex
        val action = when (actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> 0 // DOWN
            MotionEvent.ACTION_MOVE -> 1 // MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> 2 // UP
            MotionEvent.ACTION_HOVER_ENTER -> 3 // HOVER_ENTER
            MotionEvent.ACTION_HOVER_MOVE -> 4 // HOVER_MOVE
            MotionEvent.ACTION_HOVER_EXIT -> 5 // HOVER_EXIT
            MotionEvent.ACTION_CANCEL -> 6 // CANCEL (Palm rejection)
            else -> 1 // Default to MOVE
        }

        val eventTimeUs = event.eventTime * 1000L

        for (p in 0 until pointerCount) {
            if ((actionMasked == MotionEvent.ACTION_POINTER_DOWN || actionMasked == MotionEvent.ACTION_POINTER_UP)
                && p != actionIndex) {
                continue
            }

            val toolType = event.getToolType(p)
            if (penOnlyMode && toolType == MotionEvent.TOOL_TYPE_FINGER) {
                continue
            }

            forwardPointerSample(
                pointerId = event.getPointerId(p),
                overlayAction = actionMasked,
                nativeAction = action,
                toolType = toolType,
                buttonState = event.buttonState,
                x = event.getX(p),
                y = event.getY(p),
                rawPressure = event.getPressure(p),
                tiltRad = event.getAxisValue(MotionEvent.AXIS_TILT, p),
                orientRad = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, p),
                width = width,
                height = height,
                timestampUs = eventTimeUs,
                invalidateNow = false
            )
            sentSample = true
        }

        if (sentSample) {
            inkOverlayView.invalidate()
        }
        if (event.actionMasked == MotionEvent.ACTION_UP) v.performClick()
        return true
    }

    private fun forwardPointerSample(
        pointerId: Int,
        overlayAction: Int,
        nativeAction: Int,
        toolType: Int,
        buttonState: Int,
        x: Float,
        y: Float,
        rawPressure: Float,
        tiltRad: Float,
        orientRad: Float,
        width: Float,
        height: Float,
        timestampUs: Long,
        invalidateNow: Boolean = true
    ) {
        val tiltDeg = Math.toDegrees(tiltRad.toDouble()).toFloat()
        val tiltX = (-Math.sin(orientRad.toDouble()) * tiltDeg).toFloat()
        val tiltY = (Math.cos(orientRad.toDouble()) * tiltDeg).toFloat()

        var effectiveToolType = toolType
        var effectiveButtons = buttonState
        val isStylus = toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER
        val hasBarrel = isStylus && (buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY)) != 0
        if (hasBarrel) {
            when (barrelMapping) {
                BarrelButtonMapping.RIGHT_CLICK -> effectiveButtons = 0x02
                BarrelButtonMapping.ERASER -> effectiveToolType = MotionEvent.TOOL_TYPE_ERASER
            }
        }

        val pressure = when (effectiveToolType) {
            MotionEvent.TOOL_TYPE_STYLUS -> applyPressureCurve(rawPressure)
            MotionEvent.TOOL_TYPE_FINGER -> {
                if (rawPressure > 0f) rawPressure
                else if (nativeAction == 0 || nativeAction == 1) 1f
                else 0f
            }
            else -> rawPressure
        }

        inkOverlayView.processSample(
            pointerId = pointerId,
            action = overlayAction,
            toolType = effectiveToolType,
            x = x,
            y = y,
            pressure = pressure,
            tiltX = tiltX,
            tiltY = tiltY,
            invalidateNow = invalidateNow
        )

        NativeEngine.sendPointerEvent(
            pointerId = pointerId,
            action = nativeAction,
            toolType = effectiveToolType,
            normX = toNormX(x, width),
            normY = toNormY(y, height),
            pressure = pressure,
            tiltX = tiltX,
            tiltY = tiltY,
            buttons = effectiveButtons,
            timestampUs = timestampUs
        )
    }

    override fun onGenericMotion(v: View, event: MotionEvent): Boolean {
        v.requestUnbufferedDispatch(event)
        // Handles stylus hover movement (in-air stylus tracking)
        val actionMasked = event.actionMasked
        if (actionMasked == MotionEvent.ACTION_HOVER_MOVE
            || actionMasked == MotionEvent.ACTION_HOVER_ENTER
            || actionMasked == MotionEvent.ACTION_HOVER_EXIT) {
            val width = v.width.toFloat()
            val height = v.height.toFloat()
            if (width <= 0f || height <= 0f || event.pointerCount == 0) return false

            val toolType = event.getToolType(0)
            if (penOnlyMode && toolType == MotionEvent.TOOL_TYPE_FINGER) {
                return false
            }

            val pointerId = event.getPointerId(0)
            val buttonState = event.buttonState

            if (actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
                for (h in 0 until event.historySize) {
                    forwardPointerSample(
                        pointerId = pointerId,
                        overlayAction = MotionEvent.ACTION_HOVER_MOVE,
                        nativeAction = 4, // actions::HOVER_MOVE
                        toolType = toolType,
                        buttonState = buttonState,
                        x = event.getHistoricalX(0, h),
                        y = event.getHistoricalY(0, h),
                        rawPressure = 0f,
                        tiltRad = event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, 0, h),
                        orientRad = event.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, 0, h),
                        width = width,
                        height = height,
                        timestampUs = event.getHistoricalEventTime(h) * 1000L,
                        invalidateNow = false
                    )
                }
            }

            val action = when (actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER -> 3
                MotionEvent.ACTION_HOVER_MOVE -> 4
                MotionEvent.ACTION_HOVER_EXIT -> 5
                else -> 4
            }

            forwardPointerSample(
                pointerId = pointerId,
                overlayAction = actionMasked,
                nativeAction = action,
                toolType = toolType,
                buttonState = buttonState,
                x = event.x,
                y = event.y,
                rawPressure = 0f,
                tiltRad = event.getAxisValue(MotionEvent.AXIS_TILT, 0),
                orientRad = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, 0),
                width = width,
                height = height,
                timestampUs = event.eventTime * 1000L,
                invalidateNow = true
            )
            return true
        }
        return false
    }

    companion object {
        /** The stream never runs faster than this, whatever the panel can do. */
        const val MAX_STREAM_FPS = 144f
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_NAME = "name"
        const val EXTRA_PIN = "pin"
        const val EXTRA_USB_TETHER = "usb_tether"
        const val EXTRA_HOST_ID = "host_id"

        private const val TETHER_REDISCOVERY_DELAY_MS = 1500L

        private const val BACK_CONFIRM_MS = 2000L
        private const val MAX_ZOOM = 5f
        private const val TAP_MAX_MS = 250L
        private const val DOUBLE_TAP_MS = 400L
        private const val TAP_SLOP_DP = 24f
    }
}
