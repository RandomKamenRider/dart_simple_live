package com.xycz.simple_live

import android.content.pm.ActivityInfo

internal class ForegroundOrientationController(
    private val applyOrientation: (Int) -> Unit,
) {
    private var desiredOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    private var canApplyOrientation = false
    private var appliedOrientation: Int? = null

    fun requestOrientation(orientation: Int) {
        desiredOrientation = orientation
        applyCurrentOrientation()
    }

    fun updateWindowState(resumed: Boolean, focused: Boolean, inPictureInPicture: Boolean) {
        canApplyOrientation = resumed && focused && !inPictureInPicture
        applyCurrentOrientation()
    }

    private fun applyCurrentOrientation() {
        // Calls and overlays can inherit the underlying Activity's orientation.
        // Keep Flutter's latest request, but yield control until we own the screen.
        val orientation = if (canApplyOrientation) {
            desiredOrientation
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (orientation != appliedOrientation) {
            applyOrientation(orientation)
            appliedOrientation = orientation
        }
    }
}
