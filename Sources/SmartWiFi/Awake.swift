import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Holds a "prevent idle sleep" assertion while enabled and on AC power, so the
/// Mac stays reachable. Lid-closed sleep is not affected.
final class Awake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func update(enabled: Bool) {
        let want = enabled && onACPower()
        if want, !held {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SmartWiFi: keeping the Mac reachable" as CFString,
                &assertion)
            held = status == kIOReturnSuccess
            if held { log("awake: preventing idle sleep") }
        } else if !want, held {
            IOPMAssertionRelease(assertion)
            held = false
            log("awake: allowing idle sleep")
        }
    }

    private func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}
