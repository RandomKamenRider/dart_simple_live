package com.xycz.simple_live

import android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_USER
import android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
import android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE
import org.junit.Assert.assertEquals
import org.junit.Test

class ForegroundOrientationControllerTest {
    private val applied = mutableListOf<Int>()
    private val controller = ForegroundOrientationController(applied::add)

    @Test
    fun incomingCallReleasesLandscapeBeforeActivityIsPaused() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        // A call overlay can take focus without pausing the underlying Activity.
        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        controller.updateWindowState(resumed = false, focused = false, inPictureInPicture = false)
        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        foreground()
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())
    }

    @Test
    fun pauseReleasesLandscapeEvenIfWindowStillReportsFocus() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        controller.updateWindowState(resumed = false, focused = true, inPictureInPicture = false)

        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
    }

    @Test
    fun backgroundOrientationRequestsWaitForForegroundFocus() {
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        assertEquals(listOf(SCREEN_ORIENTATION_UNSPECIFIED), applied)

        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)
        controller.requestOrientation(SCREEN_ORIENTATION_FULL_USER)
        assertEquals(listOf(SCREEN_ORIENTATION_UNSPECIFIED), applied)

        foreground()
        assertEquals(SCREEN_ORIENTATION_FULL_USER, applied.last())
    }

    @Test
    fun leavingFullscreenDuringInterruptionDoesNotRestoreOldLandscape() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)

        controller.requestOrientation(SCREEN_ORIENTATION_FULL_USER)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
        foreground()

        assertEquals(SCREEN_ORIENTATION_FULL_USER, applied.last())
    }

    @Test
    fun pictureInPictureDoesNotLockTheCallingAppEvenWhenResumedAndFocused() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        controller.updateWindowState(resumed = true, focused = true, inPictureInPicture = true)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateWindowState(resumed = false, focused = false, inPictureInPicture = true)
        controller.updateWindowState(resumed = true, focused = true, inPictureInPicture = true)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        foreground()
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())
    }

    @Test
    fun exitingPictureInPictureWithoutFocusCannotRestoreLandscape() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateWindowState(resumed = false, focused = false, inPictureInPicture = true)

        controller.updateWindowState(resumed = false, focused = false, inPictureInPicture = false)
        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        foreground()
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())
    }

    @Test
    fun repeatedLifecycleCallbacksDoNotSendDuplicateRotationRequests() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateWindowState(resumed = true, focused = false, inPictureInPicture = false)
        controller.updateWindowState(resumed = false, focused = false, inPictureInPicture = false)
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        foreground()

        assertEquals(
            listOf(
                SCREEN_ORIENTATION_UNSPECIFIED,
                SCREEN_ORIENTATION_USER_LANDSCAPE,
                SCREEN_ORIENTATION_UNSPECIFIED,
                SCREEN_ORIENTATION_USER_LANDSCAPE,
            ),
            applied,
        )
    }

    private fun foreground() {
        controller.updateWindowState(resumed = true, focused = true, inPictureInPicture = false)
    }
}
