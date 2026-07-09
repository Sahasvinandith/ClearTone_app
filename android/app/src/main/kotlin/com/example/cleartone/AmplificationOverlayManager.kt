package com.example.cleartone

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

class AmplificationOverlayManager(private val context: Context) {
    private val appContext = context.applicationContext
    private val windowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var overlayView: View? = null
    private var titleView: TextView? = null
    private var autoView: TextView? = null
    private var detectedView: TextView? = null
    private var colorBarView: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var dismissed = false
    private var downRawX = 0f
    private var downRawY = 0f
    private var downX = 0
    private var downY = 0
    private var moved = false

    fun canDrawOverlays(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(appContext)
    }

    fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || canDrawOverlays()) return

        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${appContext.packageName}")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appContext.startActivity(intent)
    }

    fun show(
        mode: String,
        autoDetectEnabled: Boolean,
        detectedEnvironment: String,
        confidence: Double
    ): Boolean {
        dismissed = false
        return render(mode, autoDetectEnabled, detectedEnvironment, confidence)
    }

    fun update(
        mode: String,
        autoDetectEnabled: Boolean,
        detectedEnvironment: String,
        confidence: Double
    ): Boolean {
        if (dismissed) return true
        return render(mode, autoDetectEnabled, detectedEnvironment, confidence)
    }

    fun hide(resetDismissed: Boolean) {
        overlayView?.let { view ->
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
            }
        }
        overlayView = null
        titleView = null
        autoView = null
        detectedView = null
        colorBarView = null
        params = null
        if (resetDismissed) dismissed = false
    }

    private fun render(
        mode: String,
        autoDetectEnabled: Boolean,
        detectedEnvironment: String,
        confidence: Double
    ): Boolean {
        if (!canDrawOverlays()) return false

        if (overlayView == null) {
            createOverlay()
        }

        val color = colorForMode(mode)
        colorBarView?.setBackgroundColor(color)
        titleView?.text = mode
        titleView?.setTextColor(color)
        autoView?.text = if (autoDetectEnabled) "Auto Detect: On" else "Auto Detect: Off"
        autoView?.setTextColor(if (autoDetectEnabled) Color.rgb(20, 184, 166) else Color.rgb(185, 185, 185))

        val confidenceLabel = (confidence.coerceIn(0.0, 1.0) * 100).roundToInt()
        detectedView?.text = if (autoDetectEnabled && detectedEnvironment.isNotBlank()) {
            "Detected: $detectedEnvironment  $confidenceLabel%"
        } else {
            "Detected: --"
        }

        return true
    }

    private fun createOverlay() {
        val density = appContext.resources.displayMetrics.density
        val root = LinearLayout(appContext).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.rgb(18, 18, 18))
                cornerRadius = 16f * density
                setStroke((1f * density).roundToInt(), Color.rgb(58, 58, 58))
            }
            elevation = 12f * density
            setPadding(0, (10f * density).roundToInt(), (10f * density).roundToInt(), (10f * density).roundToInt())
        }

        colorBarView = View(appContext).apply {
            layoutParams = LinearLayout.LayoutParams((5f * density).roundToInt(), (68f * density).roundToInt())
        }
        root.addView(colorBarView)

        val content = LinearLayout(appContext).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((12f * density).roundToInt(), 0, (12f * density).roundToInt(), 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }

        titleView = TextView(appContext).apply {
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
        }
        autoView = TextView(appContext).apply {
            textSize = 12f
            includeFontPadding = false
            setPadding(0, (6f * density).roundToInt(), 0, 0)
        }
        detectedView = TextView(appContext).apply {
            textSize = 12f
            setTextColor(Color.rgb(230, 230, 230))
            includeFontPadding = false
            setPadding(0, (4f * density).roundToInt(), 0, 0)
        }

        content.addView(titleView)
        content.addView(autoView)
        content.addView(detectedView)
        root.addView(content)

        val close = TextView(appContext).apply {
            text = "x"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            background = GradientDrawable().apply {
                setColor(Color.rgb(42, 42, 42))
                shape = GradientDrawable.OVAL
            }
            layoutParams = LinearLayout.LayoutParams((32f * density).roundToInt(), (32f * density).roundToInt())
            setOnClickListener {
                dismissed = true
                hide(resetDismissed = false)
            }
        }
        root.addView(close)

        root.setOnTouchListener { view, event -> handleTouch(view, event) }

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        params = WindowManager.LayoutParams(
            (300f * density).roundToInt(),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = (16f * density).roundToInt()
            y = (96f * density).roundToInt()
        }

        overlayView = root
        windowManager.addView(root, params)
    }

    private fun handleTouch(view: View, event: MotionEvent): Boolean {
        val currentParams = params ?: return false
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = event.rawX
                downRawY = event.rawY
                downX = currentParams.x
                downY = currentParams.y
                moved = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val deltaX = (event.rawX - downRawX).roundToInt()
                val deltaY = (event.rawY - downRawY).roundToInt()
                if (kotlin.math.abs(deltaX) > 8 || kotlin.math.abs(deltaY) > 8) {
                    moved = true
                    currentParams.x = (downX - deltaX).coerceAtLeast(0)
                    currentParams.y = (downY + deltaY).coerceAtLeast(0)
                    windowManager.updateViewLayout(view, currentParams)
                    return true
                }
            }
            MotionEvent.ACTION_UP -> {
                if (!moved) {
                    view.performClick()
                    openApp()
                }
                return true
            }
        }
        return true
    }

    private fun openApp() {
        val intent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
            ?: Intent(appContext, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        appContext.startActivity(intent)
    }

    private fun colorForMode(mode: String): Int {
        return when (mode) {
            "Conversation" -> Color.rgb(34, 197, 94)
            "Transit", "Transportation" -> Color.rgb(245, 158, 11)
            else -> Color.rgb(47, 128, 237)
        }
    }
}
