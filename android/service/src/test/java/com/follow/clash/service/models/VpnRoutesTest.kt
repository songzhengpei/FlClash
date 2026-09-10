package com.follow.clash.service.models

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class VpnRoutesTest {
    @Test fun parsesBothAddressFamilies() {
        assertEquals(24, "192.168.1.0/24".toCIDR().prefixLength)
        assertEquals(16, "2001:db8::/32".toCIDR().address.address.size)
        assertEquals(0, "::/0".toCIDR().prefixLength)
    }

    @Test fun rejectsInvalidRouteRatherThanFallingBackToAllTraffic() {
        for (route in listOf("example.com/24", "10.0.0.0/33", "::/129", "::/-1", "1.2.3.4")) {
            assertFailsWith<IllegalArgumentException>(route) { route.toCIDR() }
        }
    }
}
