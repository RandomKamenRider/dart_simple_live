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

    fun updateActivityState(resumed: Boolean, inPictureInPicture: Boolean) {
        canApplyOrientation = resumed && !inPictureInPicture
        applyCurrentOrientation()
    }

    private fun applyCurrentOrientation() {
        // Floating apps can take focus while this Activity is still visible and resumed.
        // Yield only when paused or in PiP, keeping Flutter's fullscreen direction intact.
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
