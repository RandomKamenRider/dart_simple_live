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
    fun resumedPlaybackKeepsLandscapeUntilActivityIsPaused() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        // A floating app can take focus while the underlying Activity stays resumed.
        controller.updateActivityState(resumed = true, inPictureInPicture = false)
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())

        controller.updateActivityState(resumed = false, inPictureInPicture = false)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        foreground()
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())
    }

    @Test
    fun pauseReleasesLandscape() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        controller.updateActivityState(resumed = false, inPictureInPicture = false)

        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
    }

    @Test
    fun backgroundOrientationRequestsWaitForResume() {
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        assertEquals(listOf(SCREEN_ORIENTATION_UNSPECIFIED), applied)

        controller.updateActivityState(resumed = false, inPictureInPicture = false)
        controller.requestOrientation(SCREEN_ORIENTATION_FULL_USER)
        assertEquals(listOf(SCREEN_ORIENTATION_UNSPECIFIED), applied)

        foreground()
        assertEquals(SCREEN_ORIENTATION_FULL_USER, applied.last())
    }

    @Test
    fun leavingFullscreenDuringInterruptionDoesNotRestoreOldLandscape() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateActivityState(resumed = false, inPictureInPicture = false)

        controller.requestOrientation(SCREEN_ORIENTATION_FULL_USER)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
        foreground()

        assertEquals(SCREEN_ORIENTATION_FULL_USER, applied.last())
    }

    @Test
    fun pictureInPictureDoesNotLockTheCallingAppEvenWhenResumed() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)

        controller.updateActivityState(resumed = true, inPictureInPicture = true)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateActivityState(resumed = false, inPictureInPicture = true)
        controller.updateActivityState(resumed = true, inPictureInPicture = true)
        assertEquals(SCREEN_ORIENTATION_UNSPECIFIED, applied.last())

        foreground()
        assertEquals(SCREEN_ORIENTATION_USER_LANDSCAPE, applied.last())
    }

    @Test
    fun exitingPictureInPictureWhilePausedCannotRestoreLandscape() {
        foreground()
        controller.requestOrientation(SCREEN_ORIENTATION_USER_LANDSCAPE)
        controller.updateActivityState(resumed = false, inPictureInPicture = true)

        controller.updateActivityState(resumed = false, inPictureInPicture = false)
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
        controller.updateActivityState(resumed = true, inPictureInPicture = false)
        controller.updateActivityState(resumed = false, inPictureInPicture = false)
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
        controller.updateActivityState(resumed = true, inPictureInPicture = false)
    }
}
