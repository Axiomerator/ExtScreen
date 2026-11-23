package com.extscreen

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/** Low-latency native pen, touch indicator and Windows cursor rendering. */
class InkOverlayView(context: Context) : View(context) {

    // Backing bitmap for persistent ink.
    private var canvasBitmap: Bitmap? = null
    private var drawCanvas: Canvas? = null

    // Active pointer tracking (zero-allocation fixed pool supporting arbitrary Android pointer IDs)
    private class CachedPointer {
        var active: Boolean = false
        var pointerId: Int = -1
        var x: Float = 0f
        var y: Float = 0f
        var pressure: Float = 0f
        var toolType: Int = 0
    }
    private val cachedPointers = Array(16) { CachedPointer() }

    private fun findPointerSlot(pointerId: Int, allocate: Boolean): CachedPointer? {
        var free: CachedPointer? = null
        for (i in cachedPointers.indices) {
            val slot = cachedPointers[i]
            if (slot.active && slot.pointerId == pointerId) {
                return slot
            }
            if (free == null && !slot.active) {
                free = slot
            }
        }
        if (allocate && free != null) {
            free.pointerId = pointerId
            return free
        }
        return null
    }

    // Colors
    private val colorStylus = Color.rgb(0, 240, 255)    // Cyber Cyan
    private val colorFinger = Color.rgb(0, 230, 118)    // Neon Mint Green
    private val colorEraser = Color.rgb(255, 82, 82)    // Coral Red

    // Pre-allocated Paints (reused every frame to prevent GC pause / stutter at 120Hz)
    private val inkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val eraserPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }

    private val fadePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private val cursorPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f
    }

    // Decoupled 120Hz Local Hardware Cursor State & Paints
    private val cursorStateBuf = FloatArray(5)
    private var cursorVisible = false
    private var cursorScreenX = 0f
    private var cursorScreenY = 0f
    private var cursorShape = NativeEngine.CURSOR_SHAPE_ARROW
    private data class CursorImage(val bitmap: Bitmap, val hotX: Int, val hotY: Int)
    private var cursorImageId = 0
    private var cursorImage: CursorImage? = null
    private var vsyncRequested = false
    private val arrowPath = android.graphics.Path()

    private val cursorFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.WHITE
    }

    private val cursorStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.BLACK
        strokeWidth = 2f
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }

    private val cursorShadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.argb(90, 0, 0, 0)
    }

    private val choreographerFrameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!vsyncRequested || !isAttachedToWindow) return
            if (linkStatus == NativeEngine.STATUS_CONNECTED && updateCursorFromNative()) {
                invalidate()
            }
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    // Preallocated ring buffer for fading stroke segments.
    // 1024 slots is plenty for 160ms of 120-240Hz digitizer points without any GC pressure
    private val MAX_SEGMENTS = 1024
    private val segX1 = FloatArray(MAX_SEGMENTS)
    private val segY1 = FloatArray(MAX_SEGMENTS)
    private val segX2 = FloatArray(MAX_SEGMENTS)
    private val segY2 = FloatArray(MAX_SEGMENTS)
    private val segWidth = FloatArray(MAX_SEGMENTS)
    private val segColor = IntArray(MAX_SEGMENTS)
    private val segIsEraser = BooleanArray(MAX_SEGMENTS)
    private val segTimestamp = LongArray(MAX_SEGMENTS)
    private var segCount = 0
    private var segHead = 0
    private var segTail = 0

    private val FADE_DURATION_MS = 160L
    enum class InkMode { FADE, OFF, PERSIST }
    var inkMode: InkMode = InkMode.FADE
        set(value) {
            if (field == value) return
            field = value
            if (value == InkMode.PERSIST) {
                ensurePersistentBitmap()
            } else {
                releasePersistentBitmap()
            }
            clearCanvas()
        }
    // Live Diagnostics State
    var linkStatus: Int = NativeEngine.STATUS_DISCONNECTED
        set(value) {
            val wasConnected = field == NativeEngine.STATUS_CONNECTED
            field = value
            if (wasConnected && value != NativeEngine.STATUS_CONNECTED) {
                cursorVisible = false
                cursorImageId = 0
                cursorImage = null
                isHovering = false
                cachedPointers.forEach { it.active = false }
            }
        }

    var lastToolType: Int = MotionEvent.TOOL_TYPE_UNKNOWN
    var lastPressure: Float = 0f
    var lastTiltX: Float = 0f
    var lastTiltY: Float = 0f
    var sampleRateHz: Int = 0

    var isHovering: Boolean = false
    var hoverX: Float = 0f
    var hoverY: Float = 0f

    // Sample rate calculation
    private var sampleCountWindow = 0
    private var windowStartMs = System.currentTimeMillis()

    private var zoomScale = 1f
    private var zoomPanX = 0f
    private var zoomPanY = 0f

    fun setViewport(scale: Float, panX: Float, panY: Float) {
        zoomScale = scale
        zoomPanX = panX
        zoomPanY = panY
        invalidate()
    }

    fun setVsyncActive(active: Boolean) {
        vsyncRequested = active
        updateVsyncCallback()
    }

    private fun updateVsyncCallback() {
        val choreographer = Choreographer.getInstance()
        choreographer.removeFrameCallback(choreographerFrameCallback)
        if (vsyncRequested && isAttachedToWindow) {
            choreographer.postFrameCallback(choreographerFrameCallback)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // Activity.onResume() can request vsync before this view is attached on a cold launch.
        updateVsyncCallback()
    }

    override fun onDetachedFromWindow() {
        Choreographer.getInstance().removeFrameCallback(choreographerFrameCallback)
        super.onDetachedFromWindow()
    }

    private fun updateCursorFromNative(): Boolean {
        if (width <= 0 || height <= 0) return false
        val active = NativeEngine.getCursorState(cursorStateBuf)
        if (!active) {
            if (cursorVisible) {
                cursorVisible = false
                return true
            }
            return false
        }
        val normX = cursorStateBuf[0]
        val normY = cursorStateBuf[1]
        val shape = cursorStateBuf[2].toInt()
        val vis = cursorStateBuf[3] > 0.5f
        val imageId = cursorStateBuf[4].toInt()
        val imageChanged = imageId != cursorImageId
        if (imageChanged) {
            cursorImageId = imageId
            cursorImage = if (imageId == 0) null else loadCursorImage(imageId)
        }

        val sx = (normX * width) * zoomScale + zoomPanX
        val sy = (normY * height) * zoomScale + zoomPanY

        val changed = imageChanged || (vis != cursorVisible) || (shape != cursorShape) ||
                (kotlin.math.abs(sx - cursorScreenX) > 0.5f) || (kotlin.math.abs(sy - cursorScreenY) > 0.5f)

        cursorVisible = vis
        cursorShape = shape
        cursorScreenX = sx
        cursorScreenY = sy
        return changed
    }

    private fun loadCursorImage(imageId: Int): CursorImage? {
        // Native code validates the header and byte count before exposing the bitmap.
        val bytes = NativeEngine.getCursorImage(imageId) ?: return null
        val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val width = data.short.toInt()
        val height = data.short.toInt()
        val hotX = data.short.toInt()
        val hotY = data.short.toInt()
        val pixels = IntArray(width * height) { data.int }
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        bitmap.density = Bitmap.DENSITY_NONE
        return CursorImage(bitmap, hotX, hotY)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (inkMode == InkMode.PERSIST) {
            ensurePersistentBitmap(w, h)
        }
    }

    private fun ensurePersistentBitmap(w: Int = width, h: Int = height) {
        if (w <= 0 || h <= 0) return
        val existing = canvasBitmap
        if (existing != null && existing.width == w && existing.height == h) return
        existing?.recycle()
        val newBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawCanvas = Canvas(newBmp)
        canvasBitmap = newBmp
    }

    private fun releasePersistentBitmap() {
        canvasBitmap?.recycle()
        canvasBitmap = null
        drawCanvas = null
    }

    fun clearCanvas() {
        canvasBitmap?.eraseColor(Color.TRANSPARENT)
        for (i in cachedPointers.indices) {
            cachedPointers[i].active = false
            cachedPointers[i].pointerId = -1
        }
        segHead = 0
        segTail = 0
        segCount = 0
        invalidate()
    }

    private fun addFadeSegment(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        strokeWidth: Float,
        color: Int,
        isEraser: Boolean,
        now: Long
    ) {
        if (segCount == MAX_SEGMENTS) {
            // Overwrite oldest segment
            segTail = (segTail + 1) % MAX_SEGMENTS
        } else {
            segCount++
        }
        segX1[segHead] = x1
        segY1[segHead] = y1
        segX2[segHead] = x2
        segY2[segHead] = y2
        segWidth[segHead] = strokeWidth
        segColor[segHead] = color
        segIsEraser[segHead] = isEraser
        segTimestamp[segHead] = now
        segHead = (segHead + 1) % MAX_SEGMENTS
    }

    /**
     * Called on each historical and current touch/stylus point from MainActivity.
     * Pass `invalidateNow = false` for intermediate historical samples so a batch triggers one redraw.
     */
    fun processSample(
        pointerId: Int,
        action: Int,
        toolType: Int,
        x: Float,
        y: Float,
        pressure: Float,
        tiltX: Float,
        tiltY: Float,
        invalidateNow: Boolean = true
    ) {
        // Update sample rate
        sampleCountWindow++
        val now = System.currentTimeMillis()
        if (now - windowStartMs >= 1000) {
            sampleRateHz = ((sampleCountWindow * 1000f) / (now - windowStartMs)).roundToInt()
            sampleCountWindow = 0
            windowStartMs = now
        }

        lastToolType = toolType
        lastPressure = pressure
        lastTiltX = tiltX
        lastTiltY = tiltY

        val isDownOrMove = action == MotionEvent.ACTION_DOWN ||
            action == MotionEvent.ACTION_POINTER_DOWN ||
            action == MotionEvent.ACTION_MOVE
        val p = findPointerSlot(pointerId, allocate = isDownOrMove)

        when (action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                isHovering = false
                p?.apply {
                    active = true
                    this.x = x
                    this.y = y
                    this.pressure = pressure
                    this.toolType = toolType
                }
                // Draw initial contact dab
                drawStrokeSegment(x, y, x + 0.1f, y + 0.1f, pressure, toolType)
            }

            MotionEvent.ACTION_MOVE -> {
                isHovering = false
                if (p != null && p.active) {
                    drawStrokeSegment(p.x, p.y, x, y, (p.pressure + pressure) * 0.5f, toolType)
                    p.x = x
                    p.y = y
                    p.pressure = pressure
                } else {
                    p?.apply {
                        active = true
                        this.x = x
                        this.y = y
                        this.pressure = pressure
                        this.toolType = toolType
                    }
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> {
                p?.active = false
                p?.pointerId = -1
                isHovering = false
            }

            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER -> {
                isHovering = toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER
                hoverX = x
                hoverY = y
            }

            MotionEvent.ACTION_HOVER_EXIT -> {
                isHovering = false
            }
        }

        if (invalidateNow) {
            invalidate()
        }
    }

    private fun drawStrokeSegment(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        pressure: Float,
        toolType: Int
    ) {
        val density = resources.displayMetrics.density
        val isEraser = toolType == MotionEvent.TOOL_TYPE_ERASER
        val strokeW = if (isEraser) {
            48f * density
        } else {
            when (toolType) {
                MotionEvent.TOOL_TYPE_STYLUS -> (2.5f + pressure.coerceIn(0.01f, 1f) * 18f) * density
                else -> 6f * density
            }
        }
        val strokeColor = when (toolType) {
            MotionEvent.TOOL_TYPE_STYLUS -> colorStylus
            MotionEvent.TOOL_TYPE_ERASER -> colorEraser
            else -> colorFinger
        }

        if (inkMode == InkMode.OFF) {
            return
        }
        if (inkMode == InkMode.FADE) {
            val now = android.os.SystemClock.uptimeMillis()
            addFadeSegment(x1, y1, x2, y2, strokeW, strokeColor, isEraser, now)
        } else {
            val canvas = drawCanvas ?: return
            if (isEraser) {
                eraserPaint.strokeWidth = strokeW
                canvas.drawLine(x1, y1, x2, y2, eraserPaint)
            } else {
                inkPaint.color = strokeColor
                inkPaint.strokeWidth = strokeW
                canvas.drawLine(x1, y1, x2, y2, inkPaint)
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density

        if (linkStatus != NativeEngine.STATUS_CONNECTED) return

        // 1. Render ink: either fading predictive overlay (<160ms ring buffer) or persistent canvas
        if (inkMode == InkMode.FADE) {
            val now = android.os.SystemClock.uptimeMillis()
            var hasRemaining = false
            var idx = segTail
            val count = segCount
            for (step in 0 until count) {
                val age = now - segTimestamp[idx]
                if (age >= FADE_DURATION_MS) {
                    segTail = (segTail + 1) % MAX_SEGMENTS
                    segCount--
                } else {
                    hasRemaining = true
                    val fraction = (age.toFloat() / FADE_DURATION_MS).coerceIn(0f, 1f)
                    val alpha = ((1f - fraction) * 255).roundToInt().coerceIn(0, 255)
                    if (segIsEraser[idx]) {
                        // PorterDuff.Mode.CLEAR renders black directly on a hardware-accelerated
                        // View canvas; draw a soft fading coral eraser trail instead.
                        fadePaint.color = colorEraser
                        fadePaint.alpha = (alpha * 0.35f).roundToInt().coerceIn(0, 255)
                        fadePaint.strokeWidth = segWidth[idx]
                        canvas.drawLine(segX1[idx], segY1[idx], segX2[idx], segY2[idx], fadePaint)
                    } else {
                        fadePaint.color = segColor[idx]
                        fadePaint.alpha = alpha
                        fadePaint.strokeWidth = segWidth[idx]
                        canvas.drawLine(segX1[idx], segY1[idx], segX2[idx], segY2[idx], fadePaint)
                    }
                }
                idx = (idx + 1) % MAX_SEGMENTS
            }
            if (hasRemaining) {
                postInvalidateOnAnimation()
            }
        } else {
            canvasBitmap?.let { bmp ->
                canvas.drawBitmap(bmp, 0f, 0f, null)
            }
        }

        // Render touch and pen feedback without a second pointer over the contact.
        var showingTouchIndicator = isHovering
        if (isHovering) {
            cursorPaint.color = Color.argb(160, 0, 240, 255)
            cursorPaint.style = Paint.Style.STROKE
            cursorPaint.strokeWidth = 2f * density
            canvas.drawCircle(hoverX, hoverY, 12f * density, cursorPaint)
        } else {
            for (i in cachedPointers.indices) {
                val pt = cachedPointers[i]
                if (!pt.active || pt.toolType == MotionEvent.TOOL_TYPE_MOUSE) continue
                showingTouchIndicator = true
                val radius = (4f + pt.pressure * 16f) * density
                cursorPaint.color = when (pt.toolType) {
                    MotionEvent.TOOL_TYPE_STYLUS -> colorStylus
                    MotionEvent.TOOL_TYPE_ERASER -> colorEraser
                    else -> colorFinger
                }
                cursorPaint.style = Paint.Style.STROKE
                cursorPaint.strokeWidth = 2f * density
                canvas.drawCircle(pt.x, pt.y, radius, cursorPaint)

                cursorPaint.style = Paint.Style.FILL
                cursorPaint.alpha = 100
                canvas.drawCircle(pt.x, pt.y, radius * 0.4f, cursorPaint)
            }
        }

        // 2b. Render Decoupled 120Hz Local Hardware Cursor
        if (!showingTouchIndicator && cursorVisible && cursorShape != NativeEngine.CURSOR_SHAPE_HIDDEN) {
            drawHardwareCursor(canvas, density)
        }

    }

    private fun drawHardwareCursor(canvas: Canvas, density: Float) {
        cursorImage?.let { image ->
            canvas.drawBitmap(image.bitmap, cursorScreenX - image.hotX, cursorScreenY - image.hotY, null)
            return
        }
        when (cursorShape) {
            NativeEngine.CURSOR_SHAPE_IBEAM -> {
                canvas.save()
                canvas.translate(cursorScreenX, cursorScreenY)
                val h = 10f * density
                val w = 4f * density
                cursorStrokePaint.color = Color.BLACK
                cursorStrokePaint.strokeWidth = 3f * density
                canvas.drawLine(-w, -h, w, -h, cursorStrokePaint)
                canvas.drawLine(0f, -h, 0f, h, cursorStrokePaint)
                canvas.drawLine(-w, h, w, h, cursorStrokePaint)

                cursorStrokePaint.color = Color.WHITE
                cursorStrokePaint.strokeWidth = 1.5f * density
                canvas.drawLine(-w, -h, w, -h, cursorStrokePaint)
                canvas.drawLine(0f, -h, 0f, h, cursorStrokePaint)
                canvas.drawLine(-w, h, w, h, cursorStrokePaint)
                canvas.restore()
            }
            NativeEngine.CURSOR_SHAPE_CROSS -> {
                canvas.save()
                canvas.translate(cursorScreenX, cursorScreenY)
                val arm = 8f * density
                cursorStrokePaint.color = Color.BLACK
                cursorStrokePaint.strokeWidth = 3f * density
                canvas.drawLine(-arm, 0f, arm, 0f, cursorStrokePaint)
                canvas.drawLine(0f, -arm, 0f, arm, cursorStrokePaint)

                cursorStrokePaint.color = Color.WHITE
                cursorStrokePaint.strokeWidth = 1.5f * density
                canvas.drawLine(-arm, 0f, arm, 0f, cursorStrokePaint)
                canvas.drawLine(0f, -arm, 0f, arm, cursorStrokePaint)
                canvas.restore()
            }
            NativeEngine.CURSOR_SHAPE_SIZE_ALL -> {
                canvas.save()
                canvas.translate(cursorScreenX, cursorScreenY)
                val arm = 9f * density
                cursorStrokePaint.color = Color.BLACK
                cursorStrokePaint.strokeWidth = 3f * density
                canvas.drawLine(-arm, 0f, arm, 0f, cursorStrokePaint)
                canvas.drawLine(0f, -arm, 0f, arm, cursorStrokePaint)

                cursorStrokePaint.color = Color.WHITE
                cursorStrokePaint.strokeWidth = 1.5f * density
                canvas.drawLine(-arm, 0f, arm, 0f, cursorStrokePaint)
                canvas.drawLine(0f, -arm, 0f, arm, cursorStrokePaint)
                canvas.restore()
            }
            else -> {
                // Precision Arrow Pointer (Arrow, Hand, or fallback)
                canvas.save()
                canvas.translate(cursorScreenX, cursorScreenY)

                arrowPath.reset()
                arrowPath.moveTo(0f, 0f)
                arrowPath.lineTo(0f, 20f * density)
                arrowPath.lineTo(5f * density, 15.5f * density)
                arrowPath.lineTo(8.5f * density, 23f * density)
                arrowPath.lineTo(11.5f * density, 21.5f * density)
                arrowPath.lineTo(8.2f * density, 14.5f * density)
                arrowPath.lineTo(14.5f * density, 14.5f * density)
                arrowPath.close()

                // Soft drop shadow
                canvas.save()
                canvas.translate(1.5f * density, 1.5f * density)
                canvas.drawPath(arrowPath, cursorShadowPaint)
                canvas.restore()

                // White body with crisp black border
                cursorStrokePaint.color = Color.BLACK
                cursorStrokePaint.strokeWidth = 1.5f * density
                canvas.drawPath(arrowPath, cursorFillPaint)
                canvas.drawPath(arrowPath, cursorStrokePaint)
                canvas.restore()
            }
        }
    }

}
