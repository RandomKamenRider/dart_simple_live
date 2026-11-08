package com.xycz.simple_live

import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private var activityResumed = false
    private var windowFocused = false
    private val foregroundOrientation = ForegroundOrientationController { orientation ->
        super.setRequestedOrientation(orientation)
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        foregroundOrientation.requestOrientation(requestedOrientation)
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
        windowFocused = hasWindowFocus()
        updateOrientation()
    }

    override fun onPause() {
        activityResumed = false
        windowFocused = false
        updateOrientation()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        windowFocused = hasFocus
        updateOrientation()
        super.onWindowFocusChanged(hasFocus)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        updateOrientation(inPictureInPicture = isInPictureInPictureMode)
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    }

    private fun updateOrientation(
        inPictureInPicture: Boolean = isInPictureInPictureMode,
    ) {
        foregroundOrientation.updateWindowState(
            resumed = activityResumed,
            focused = windowFocused,
            inPictureInPicture = inPictureInPicture,
        )
    }
}
