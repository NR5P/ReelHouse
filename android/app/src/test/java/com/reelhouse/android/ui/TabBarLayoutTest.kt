package com.reelhouse.android.ui

import com.reelhouse.android.ui.AppSection.MOVIES
import com.reelhouse.android.ui.AppSection.MUSIC
import com.reelhouse.android.ui.AppSection.PODCASTS
import com.reelhouse.android.ui.AppSection.SETTINGS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TabBarLayoutTest {

    private val all = AppSection.visible(moviesEnabled = true, musicEnabled = true, podcastsEnabled = true)

    @Test
    fun `settings is always there, alone when the server has nothing switched on`() {
        assertEquals(listOf(SETTINGS), AppSection.visible())
    }

    @Test
    fun `every section switched on is movies, music, podcasts, settings`() {
        assertEquals(listOf(MOVIES, MUSIC, PODCASTS, SETTINGS), all)
        assertEquals(AppSection.entries.toList(), all)
    }

    @Test
    fun `movies, music and podcasts each follow their own switch`() {
        assertEquals(listOf(MOVIES, SETTINGS), AppSection.visible(moviesEnabled = true))
        assertEquals(listOf(MUSIC, SETTINGS), AppSection.visible(musicEnabled = true))
        assertEquals(listOf(PODCASTS, SETTINGS), AppSection.visible(podcastsEnabled = true))
        assertEquals(listOf(MUSIC, PODCASTS, SETTINGS), AppSection.visible(musicEnabled = true, podcastsEnabled = true))
    }

    @Test
    fun `every section gets a tab by default`() {
        val layout = TabBarLayout(pinned = null, visible = all)

        assertEquals(listOf(MOVIES, MUSIC, PODCASTS, SETTINGS), layout.bar)
        assertFalse(layout.showsMore)
        assertEquals(5, TabBarLayout.limit(all))
    }

    @Test
    fun `a customized list keeps its order`() {
        val layout = TabBarLayout(pinned = listOf(SETTINGS, PODCASTS, MUSIC, MOVIES), visible = all)

        assertEquals(listOf(SETTINGS, PODCASTS, MUSIC, MOVIES), layout.bar)
        assertFalse(layout.showsMore)
    }

    @Test
    fun `a pinned list with a section left out adds More even when everything would fit`() {
        val layout = TabBarLayout(pinned = listOf(MUSIC, MOVIES), visible = all)

        assertEquals(listOf(MUSIC, MOVIES), layout.bar)
        assertEquals(listOf(PODCASTS, SETTINGS), layout.more)
        assertTrue(layout.showsMore)
    }

    @Test
    fun `a pinned section switched off server-side drops out`() {
        val visible = AppSection.visible(moviesEnabled = true, musicEnabled = true)
        val layout = TabBarLayout(pinned = listOf(PODCASTS, MUSIC, SETTINGS, MOVIES), visible = visible)

        assertEquals(listOf(MUSIC, SETTINGS, MOVIES), layout.bar)
        assertFalse(layout.showsMore)
    }

    @Test
    fun `a pinned list with nothing left visible falls back to the default`() {
        val visible = AppSection.visible(musicEnabled = true)
        val layout = TabBarLayout(pinned = listOf(MOVIES, PODCASTS), visible = visible)

        assertEquals(listOf(MUSIC, SETTINGS), layout.bar)
        assertFalse(layout.showsMore)
    }

    @Test
    fun `duplicates in the pinned list are dropped`() {
        val layout = TabBarLayout(pinned = listOf(MUSIC, MUSIC, MOVIES, PODCASTS, SETTINGS), visible = all)

        assertEquals(listOf(MUSIC, MOVIES, PODCASTS, SETTINGS), layout.bar)
    }

    @Test
    fun `encode and decode round trip`() {
        val sections = listOf(SETTINGS, PODCASTS, MOVIES, MUSIC)

        assertEquals("settings,podcasts,movies,music", TabBarLayout.encode(sections))
        assertEquals(sections, TabBarLayout.decode(TabBarLayout.encode(sections)))
    }

    @Test
    fun `blank storage means never customized`() {
        assertNull(TabBarLayout.decode(""))
        assertNull(TabBarLayout.decode(null))
    }

    @Test
    fun `garbage in storage is skipped`() {
        assertNull(TabBarLayout.decode("nonsense,,MOVIES, ,{}"))
        assertEquals(listOf(MUSIC, SETTINGS), TabBarLayout.decode("music,nonsense,,settings"))
    }
}
