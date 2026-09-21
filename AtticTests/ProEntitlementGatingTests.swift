import XCTest
@testable import TimeCapsule

/// Guards the contract that round four got badly wrong.
///
/// An earlier version reset the two Pro settings to their free defaults
/// whenever a reading of the entitlement came back empty — and several
/// readings do without the entitlement being gone, because an unverified
/// transaction is skipped by the same `guard` as an absent one. The reset
/// also cleared the cached flag, so nothing restored the values when the
/// entitlement reappeared: a transient misread permanently destroyed a
/// paying user's preferences.
///
/// The replacement gates at the point of use and never writes. These tests
/// exist so that "never writes" is checked by a machine rather than by
/// reading the diff, because the failure is silent and unrecoverable.
final class ProEntitlementGatingTests: XCTestCase {
    private var savedEntitlement: Bool!
    private var savedWindow: Any?
    private var savedStartHour: Any?

    override func setUp() {
        super.setUp()
        savedEntitlement = AtticDefaults.isProEntitled
        savedWindow = AtticDefaults.shared.object(forKey: MemoryWindow.storageKey)
        savedStartHour = AtticDefaults.shared.object(forKey: MemoryWindow.dayStartHourKey)
    }

    override func tearDown() {
        AtticDefaults.isProEntitled = savedEntitlement
        restore(savedWindow, to: MemoryWindow.storageKey)
        restore(savedStartHour, to: MemoryWindow.dayStartHourKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, to key: String) {
        if let value {
            AtticDefaults.shared.set(value, forKey: key)
        } else {
            AtticDefaults.shared.removeObject(forKey: key)
        }
    }

    func testProSettingsApplyWhenEntitled() {
        AtticDefaults.isProEntitled = true
        AtticDefaults.shared.set(5, forKey: MemoryWindow.storageKey)
        AtticDefaults.shared.set(4, forKey: MemoryWindow.dayStartHourKey)

        XCTAssertEqual(MemoryWindow.dayWindow, 5)
        XCTAssertEqual(MemoryWindow.dayStartHour, 4)
    }

    func testProSettingsStopApplyingWhenNotEntitled() {
        AtticDefaults.isProEntitled = false
        AtticDefaults.shared.set(5, forKey: MemoryWindow.storageKey)
        AtticDefaults.shared.set(4, forKey: MemoryWindow.dayStartHourKey)

        XCTAssertEqual(MemoryWindow.dayWindow, MemoryWindow.defaultDayWindow)
        XCTAssertEqual(MemoryWindow.dayStartHour, MemoryWindow.defaultDayStartHour)
    }

    /// The heart of it: losing the entitlement must cost nothing but a
    /// temporary drop to free-tier behaviour, with nothing for the user to
    /// re-enter when it comes back.
    func testLosingTheEntitlementDoesNotDestroyTheStoredValues() {
        AtticDefaults.isProEntitled = true
        AtticDefaults.shared.set(6, forKey: MemoryWindow.storageKey)
        AtticDefaults.shared.set(3, forKey: MemoryWindow.dayStartHourKey)

        AtticDefaults.isProEntitled = false
        _ = MemoryWindow.dayWindow
        _ = MemoryWindow.dayStartHour

        XCTAssertEqual(
            AtticDefaults.shared.object(forKey: MemoryWindow.storageKey) as? Int, 6,
            "Reading the window while unentitled must not overwrite what the user chose"
        )
        XCTAssertEqual(
            AtticDefaults.shared.object(forKey: MemoryWindow.dayStartHourKey) as? Int, 3,
            "Reading the day start while unentitled must not overwrite what the user chose"
        )

        AtticDefaults.isProEntitled = true
        XCTAssertEqual(MemoryWindow.dayWindow, 6, "Re-entitling must restore the value with nothing to re-enter")
        XCTAssertEqual(MemoryWindow.dayStartHour, 3)
    }

    /// A corrupt or legacy value must be clamped rather than trusted, in both
    /// directions, so a bad write cannot widen fetches without bound.
    func testStoredValuesAreClampedNotTrusted() {
        AtticDefaults.isProEntitled = true
        AtticDefaults.shared.set(999, forKey: MemoryWindow.storageKey)
        AtticDefaults.shared.set(23, forKey: MemoryWindow.dayStartHourKey)
        XCTAssertEqual(MemoryWindow.dayWindow, 7)
        XCTAssertEqual(MemoryWindow.dayStartHour, 6)

        AtticDefaults.shared.set(-5, forKey: MemoryWindow.storageKey)
        AtticDefaults.shared.set(-2, forKey: MemoryWindow.dayStartHourKey)
        XCTAssertEqual(MemoryWindow.dayWindow, 0)
        XCTAssertEqual(MemoryWindow.dayStartHour, 0)
    }
}
