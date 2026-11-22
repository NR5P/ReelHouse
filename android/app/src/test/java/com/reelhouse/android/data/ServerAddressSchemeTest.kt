package com.reelhouse.android.data

import org.junit.Assert.assertEquals
import org.junit.Test

// A typed address with no scheme: home-network addresses keep http:// (how the dashboard ships),
// internet addresses get https:// so a password never crosses the internet in plain text. The
// App Review demo (demo.nr5p.com) answers on plain HTTP too, which is why this matters.
class ServerAddressSchemeTest {
    private fun normalize(value: String) = ReelHouseRepository.normalizeAddress(value)

    @Test
    fun `home network addresses default to http`() {
        assertEquals("http://192.168.1.50:3350", normalize("192.168.1.50:3350"))
        assertEquals("http://reelhouse.local:3350", normalize("reelhouse.local:3350"))
        assertEquals("http://mediabox:3350", normalize("mediabox:3350"))
        assertEquals("http://localhost:3350", normalize("localhost:3350"))
        assertEquals("http://[fe80::1]:3350", normalize("[fe80::1]:3350"))
        assertEquals("http://nas.home.arpa:3350", normalize("nas.home.arpa"))
    }

    @Test
    fun `a home address with no port gets the dashboard port`() {
        assertEquals("http://192.168.1.50:3350", normalize("192.168.1.50"))
        assertEquals("http://mediabox:3350", normalize("mediabox/"))
        assertEquals("http://192.168.1.50:80", normalize("192.168.1.50:80"))
        assertEquals("http://192.168.1.50", normalize("http://192.168.1.50"))
    }

    @Test
    fun `internet addresses default to https`() {
        assertEquals("https://demo.nr5p.com", normalize("demo.nr5p.com"))
        assertEquals("https://home.example.com:8443", normalize("home.example.com:8443/"))
    }

    @Test
    fun `a typed or forced scheme wins`() {
        assertEquals("http://demo.nr5p.com", normalize("http://demo.nr5p.com"))
        assertEquals("https://192.168.1.50:3453", normalize("https://192.168.1.50:3453"))
        assertEquals("https://192.168.1.50", ReelHouseRepository.normalizeAddress("192.168.1.50", defaultScheme = "https"))
    }
}
