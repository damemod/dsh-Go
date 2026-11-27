package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Intent: the phone-storage bind set exposes shared storage through exactly one
 * controlled mount point (/sdcard). A bare `/storage` bind must never appear —
 * it would expose the physical shared-storage tree outside that mount point.
 *
 * These are invariant assertions, not a single golden value. The terminal-state
 * check and the negative probes below together close off the bypass even if
 * someone later re-adds a `/storage` entry through a different code path.
 */
class PhoneStorageBindsTest {
    @get:Rule val temp = TemporaryFolder()

    private fun readableRoot(): File = File(temp.root, "shared-storage").apply { mkdirs() }
    private fun unreadableRoot(): File = File(temp.root, "missing-storage") // never created

    /**
     * The gate: assert every bind invariant for a given bind list. Used by both
     * the real implementation test and the corruption probe, so the probe proves
     * the *same* gate rejects a reintroduced `/storage` bind.
     */
    private fun assertNoStorageBypass(binds: List<String>, host: String) {
        assertEquals(1, binds.size)
        val only = binds.single()
        assertTrue(only, only.startsWith("$host:"))
        assertTrue(only, only.endsWith(":${PhoneStorage.GUEST_PATH}"))
        assertEquals("$host:${PhoneStorage.GUEST_PATH}", only)

        // The bypass is absent in every spelling that could be reintroduced.
        assertFalse(binds.any { it == "/storage" })
        assertFalse(binds.any { it.startsWith("/storage:") })
        assertFalse(binds.any { it.startsWith("/storage/") })
        assertFalse(binds.any { it.contains(":/storage") })
    }

    @Test fun binds_exposesOnlySdcardMountAndNeverBareStorage() {
        val host = readableRoot().absolutePath
        assertNoStorageBypass(PhoneStorage.binds(host), host)
    }

    @Test fun binds_withUnreadableHost_returnsNoMount() {
        // When host storage is unreadable, no mount is emitted at all — neither
        // /sdcard nor a bare /storage fallback.
        assertTrue(PhoneStorage.binds(unreadableRoot().absolutePath).isEmpty())
    }

    @Test fun binds_terminalState_hasExactlyOneHostToSdcardMount() {
        val host = readableRoot().absolutePath
        val binds = PhoneStorage.binds(host)

        // Terminal state: the whole bind list is fully accounted for by the
        // single intended mount; there is no second entry and no residue.
        val expected = setOf("$host:${PhoneStorage.GUEST_PATH}")
        assertEquals(expected, binds.toSet())
        assertEquals(binds.size, expected.size)
        assertEquals(1, binds.count { it.endsWith(":${PhoneStorage.GUEST_PATH}") })
        assertEquals(0, binds.count { it.contains("/storage") })
    }

    /**
     * Corruption probe: if the bare `/storage` bind is reintroduced (the exact
     * regression this change fixes), the very same gate above must reject it.
     * This models the bad production implementation without leaving it in the
     * shipped code.
     */
    @Test fun corruptionProbe_readdingBareStorage_isRejectedByTheGate() {
        val host = readableRoot().absolutePath
        val badBinds = listOf("$host:${PhoneStorage.GUEST_PATH}", "/storage")

        var gateRejected = false
        try {
            assertNoStorageBypass(badBinds, host)
        } catch (e: AssertionError) {
            gateRejected = true
        }
        assertTrue("a bare /storage bind must be rejected by the gate", gateRejected)
    }
}
