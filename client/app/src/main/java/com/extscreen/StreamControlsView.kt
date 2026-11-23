package com.extscreen

import android.content.Context
import android.graphics.RectF
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView

/**
 * Composes controls over the existing video and ink views. A pen gesture which starts on
 * the screen belongs to the native input pipeline until it ends, even across a control.
 */
internal class StreamControlsView(context: Context) : FlutterView(
    context, FlutterTextureView(context).apply { isOpaque = false }
) {
    var modal = false
        private set
    private var areas = emptyList<RectF>()
    private var controlGesture = false

    fun setHitAreas(modal: Boolean, rectangles: List<RectF>) {
        this.modal = modal
        areas = rectangles
    }

    private fun isControl(event: MotionEvent): Boolean {
        if (modal) return true
        val density = resources.displayMetrics.density
        val x = event.x / density
        val y = event.y / density
        return areas.any { it.contains(x, y) }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) controlGesture = isControl(event)
        if (!controlGesture) return false
        super.dispatchTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            controlGesture = false
        }
        return true
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        isControl(event) && super.dispatchGenericMotionEvent(event)

    override fun dispatchHoverEvent(event: MotionEvent): Boolean =
        isControl(event) && super.dispatchHoverEvent(event)
}
