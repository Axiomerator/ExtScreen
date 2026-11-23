package com.extscreen

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Native discovery and pairing controller for the Prism connection screen. */
class ConnectActivity : FlutterActivity() {
    private val store by lazy { ConnectionStore(this) }
    private val handler = Handler(Looper.getMainLooper())
    private var ui: AndroidUiChannel? = null
    private var appearance: AppearanceChannel? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var lastIfaceSpec: String? = null
    private var usbReceiver: BroadcastReceiver? = null
    private var permissionAskedFor: UsbAccessory? = null
    private var suppressAutoConnect = false
    private var launchPending = false
    private var hosts = emptyList<Peer>()
    private var tetherActive = false
    private var pairing: Peer? = null
    private var notice: String? = null
    private var noticeDetail: String? = null

    private data class Peer(val target: Target, val id: String?)

    private val refresh = object : Runnable {
        override fun run() {
            val ifaces = NetworkUtils.activeInterfaces()
            val spec = NetworkUtils.toNativeSpec(ifaces)
            if (spec != lastIfaceSpec) {
                lastIfaceSpec = spec
                NativeEngine.setDiscoveryInterfaces(spec)
            }
            tetherActive = NetworkUtils.isUsbTetheringActive(ifaces)
            hosts = NativeEngine.getDiscoveredHosts().lineSequence().mapNotNull { line ->
                val parts = line.split('|')
                if (parts.size < 4) return@mapNotNull null
                val port = parts[1].toIntOrNull() ?: return@mapNotNull null
                Peer(Target(parts[0], port, parts[2], parts.getOrNull(4) == "usb"), parts[3])
            }.toList()
            if (!suppressAutoConnect && !launchPending && pairing == null) {
                val pairedUsb = hosts.firstOrNull {
                    it.target.isUsbTether && it.id?.let(store::hasCredentialFor) == true
                }
                if (pairedUsb != null) {
                    launch(pairedUsb, "")
                    return
                }
            }
            ui?.publish()
            handler.postDelayed(this, REFRESH_MS)
        }
    }

    override fun getInitialRoute(): String = "/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appearance = AppearanceChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        ui = AndroidUiChannel(flutterEngine.dartExecutor.binaryMessenger, ::state, ::handleCall)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appearance?.close()
        appearance = null
        ui?.close()
        ui = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        NativeEngine.initNativeLogging()
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        if (!suppressAutoConnect) checkAndLaunchAoa(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        if (!suppressAutoConnect) checkAndLaunchAoa(intent)
    }

    override fun onResume() {
        super.onResume()
        launchPending = false
        usbReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                    checkAndLaunchAoa(intent)
                }
            }
        }.also { receiver ->
            ContextCompat.registerReceiver(
                this, receiver, IntentFilter(ACTION_USB_PERMISSION), ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
        if (!suppressAutoConnect && checkAndLaunchAoa()) return

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifi?.createMulticastLock("extscreen-discovery")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        lastIfaceSpec = NetworkUtils.toNativeSpec(NetworkUtils.activeInterfaces())
        NativeEngine.setDiscoveryInterfaces(lastIfaceSpec.orEmpty())
        NativeEngine.startDiscovery()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        NativeEngine.stopDiscovery()
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
        usbReceiver?.let(::unregisterReceiver)
        usbReceiver = null
        super.onPause()
    }

    private fun checkAndLaunchAoa(intentToCheck: Intent? = null): Boolean {
        if (launchPending) return true
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        val accessory: UsbAccessory? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intentToCheck?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            intentToCheck?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        } ?: usbManager.accessoryList?.firstOrNull()
        if (accessory == null) {
            permissionAskedFor = null
            return false
        }
        if (!usbManager.hasPermission(accessory)) {
            if (permissionAskedFor != accessory) {
                permissionAskedFor = accessory
                // Mutable so the system can add the accessory and permission result.
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                val permission = PendingIntent.getBroadcast(
                    this, 0, Intent(ACTION_USB_PERMISSION).setPackage(packageName), flags
                )
                usbManager.requestPermission(accessory, permission)
            }
            return false
        }
        launchPending = true
        startActivity(
            Intent(this, MainActivity::class.java)
                .setAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
                .putExtra(UsbManager.EXTRA_ACCESSORY, accessory)
        )
        finish()
        return true
    }

    private fun handleIntent(intent: Intent) {
        if (!InternalIntents.isInternal(intent)) return
        if (intent.getBooleanExtra(EXTRA_NO_AUTO_CONNECT, false)) {
            suppressAutoConnect = true
            intent.removeExtra(EXTRA_NO_AUTO_CONNECT)
        }
        notice = intent.getStringExtra(EXTRA_NOTICE)
        noticeDetail = intent.getStringExtra(EXTRA_MESSAGE)
        if (notice != null) suppressAutoConnect = true
        if (intent.getBooleanExtra(EXTRA_NEED_PIN, false)) {
            suppressAutoConnect = true
            val host = intent.getStringExtra(EXTRA_HOST)
            if (host != null) {
                pairing = Peer(
                    Target(
                        host,
                        intent.getIntExtra(EXTRA_PORT, Target.DEFAULT_PORT),
                        intent.getStringExtra(EXTRA_NAME) ?: host,
                        intent.getBooleanExtra(EXTRA_USB_TETHER, false)
                    ),
                    intent.getStringExtra(EXTRA_HOST_ID)
                )
            }
        }
        intent.removeExtra(EXTRA_NEED_PIN)
        intent.removeExtra(EXTRA_NOTICE)
        intent.removeExtra(EXTRA_MESSAGE)
        ui?.publish()
    }

    private fun state(): Map<String, Any?> = mapOf(
        "hosts" to hosts.map(::peerMap),
        "lastTarget" to store.lastTarget?.let { peerMap(Peer(it, store.lastHostId)) },
        "tetherActive" to tetherActive,
        "pairing" to pairing?.let(::peerMap),
        "notice" to notice,
        "noticeDetail" to noticeDetail
    )

    private fun peerMap(peer: Peer): Map<String, Any?> = mapOf(
        "host" to peer.target.host,
        "port" to peer.target.port,
        "name" to peer.target.name,
        "hostId" to peer.id,
        "usbTether" to peer.target.isUsbTether,
        "paired" to (peer.id?.let(store::hasCredentialFor) ?: false)
    )

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getConnectionState" -> result.success(state())
            "openUsbTethering" -> {
                NetworkUtils.openUsbTetheringSettings(this)
                result.success(null)
            }
            "cancelPairing" -> {
                pairing = null
                ui?.publish()
                result.success(null)
            }
            "clearNotice" -> {
                notice = null
                noticeDetail = null
                ui?.publish()
                result.success(null)
            }
            "connect" -> {
                connect(call)
                result.success(state())
            }
            else -> result.notImplemented()
        }
    }

    private fun connect(call: MethodCall) {
        if (launchPending) return
        val rawHost = call.argument<String>("host").orEmpty().trim()
        val host = rawHost.substringBefore(':')
        val port = if (':' in rawHost) rawHost.substringAfter(':').toIntOrNull()
            else call.argument<Int>("port") ?: Target.DEFAULT_PORT
        val octets = host.split('.')
        notice = null
        noticeDetail = null
        if (port == null || port !in 1..65535 || octets.size != 4 ||
            octets.any { it.toIntOrNull()?.let { number -> number in 0..255 } != true || it.any { char -> char !in '0'..'9' } }) {
            notice = "invalidAddress"
            ui?.publish()
            return
        }
        val target = Target(
            host,
            port,
            call.argument<String>("name")?.takeIf(String::isNotBlank) ?: host,
            call.argument<Boolean>("usbTether") == true
        )
        val peer = Peer(target, call.argument<String>("hostId"))
        val pin = call.argument<String>("pin").orEmpty()
        if (pin.isNotEmpty() && (pin.length != 6 || pin.any { it !in '0'..'9' })) {
            notice = "invalidPin"
        } else if (pin.isEmpty() && !target.isUsb &&
            peer.id?.let { !store.hasCredentialFor(it) } == true) {
            pairing = peer
        } else {
            suppressAutoConnect = false
            launch(peer, pin)
        }
        ui?.publish()
    }

    private fun launch(peer: Peer, pin: String) {
        if (launchPending) return
        launchPending = true
        pairing = null
        store.lastTarget = peer.target
        store.lastHostId = peer.id
        startActivity(
            InternalIntents.mark(Intent(this, MainActivity::class.java))
                .putExtra(MainActivity.EXTRA_HOST, peer.target.host)
                .putExtra(MainActivity.EXTRA_PORT, peer.target.port)
                .putExtra(MainActivity.EXTRA_NAME, peer.target.name)
                .putExtra(MainActivity.EXTRA_PIN, pin)
                .putExtra(MainActivity.EXTRA_USB_TETHER, peer.target.isUsbTether)
                .putExtra(MainActivity.EXTRA_HOST_ID, peer.id)
        )
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.extscreen.USB_ACCESSORY_PERMISSION"
        const val EXTRA_NOTICE = "notice"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_NEED_PIN = "need_pin"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_NAME = "name"
        const val EXTRA_HOST_ID = "host_id"
        const val EXTRA_USB_TETHER = "usb_tether"
        const val EXTRA_NO_AUTO_CONNECT = "no_auto_connect"
        private const val REFRESH_MS = 500L
    }
}
