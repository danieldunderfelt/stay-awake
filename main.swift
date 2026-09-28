import AppKit
import IOKit
import IOKit.ps

// Toggles pmset's SleepDisabled flag, which (unlike caffeinate) also blocks
// clamshell sleep with no external display. It also sets the Energy Mode: High
// Power with an external display on AC power, Low Power (optional) with the lid
// closed on battery, and Automatic otherwise. Needs the sudoers rule from install.sh.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let toggleItem = NSMenuItem(title: "Stay Awake (even with lid closed)", action: #selector(toggle), keyEquivalent: "")
    private let lowPowerItem = NSMenuItem(title: "Low Power Mode While Lid Closed on Battery", action: #selector(toggleLowPower), keyEquivalent: "")
    // Set while we've temporarily lifted SleepDisabled for a manual sleep.
    private let reenableKey = "reenableOnWake"
    private let lowPowerKey = "lowPowerWhenClosed"
    private var lidTimer: Timer?
    // Last `pmset powermode` value we set, so we only call pmset when the target changes.
    private var appliedMode: PowerMode?
    // Pending switch to Low Power; cancelled if the target changes before it fires.
    private var lowPowerDelay: Timer?

    private enum PowerMode: String {
        case automatic = "0", low = "1", high = "2"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [lowPowerKey: true])

        let menu = NSMenu()
        menu.delegate = self
        toggleItem.target = self
        lowPowerItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(lowPowerItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sleep Now", action: #selector(sleepNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit StayAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePowerMode), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        lidTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(updatePowerMode),
                                        userInfo: nil, repeats: true)
        didWake()
    }

    func applicationWillTerminate(_ notification: Notification) {
        setPowerMode(.automatic)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private var sleepDisabled: Bool {
        run("/usr/bin/pmset", ["-g"]).output.contains("SleepDisabled\t\t1")
    }

    private var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? false
    }

    private var onACPower: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPMACPowerKey
    }

    private var externalDisplayConnected: Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func refresh() {
        let on = sleepDisabled
        toggleItem.state = on ? .on : .off
        lowPowerItem.state = UserDefaults.standard.bool(forKey: lowPowerKey) ? .on : .off
        let image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                            accessibilityDescription: on ? "Staying awake" : "Normal sleep")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func toggle() {
        setSleepDisabled(!sleepDisabled)
        refresh()
    }

    @objc private func toggleLowPower() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: lowPowerKey), forKey: lowPowerKey)
        updatePowerMode()
        refresh()
    }

    @objc private func sleepNow() {
        if sleepDisabled {
            guard setSleepDisabled(false) else { return }
            UserDefaults.standard.set(true, forKey: reenableKey)
        }
        run("/usr/bin/pmset", ["sleepnow"])
    }

    // Also runs at launch, in case the Mac was restarted instead of woken.
    @objc private func didWake() {
        if UserDefaults.standard.bool(forKey: reenableKey), setSleepDisabled(true) {
            UserDefaults.standard.removeObject(forKey: reenableKey)
        }
        updatePowerMode()
        refresh()
    }

    private var targetMode: PowerMode {
        if externalDisplayConnected {
            return onACPower ? .high : .automatic
        }
        if lidClosed && !onACPower && UserDefaults.standard.bool(forKey: lowPowerKey) {
            return .low
        }
        return .automatic
    }

    // Low Power waits 10s (keeping the current mode) and only applies if it's still the target then.
    @objc private func updatePowerMode() {
        let target = targetMode
        if target != .low {
            lowPowerDelay?.invalidate()
            lowPowerDelay = nil
        }
        guard target != appliedMode else { return }
        if target != .low {
            setPowerMode(target)
        } else if lowPowerDelay == nil {
            lowPowerDelay = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                guard let self else { return }
                lowPowerDelay = nil
                if targetMode == .low { setPowerMode(.low) }
            }
        }
    }

    private func setPowerMode(_ mode: PowerMode) {
        if sudoPmset(["-a", "powermode", mode.rawValue]).ok { appliedMode = mode }
    }

    @discardableResult
    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let result = sudoPmset(["-a", "disablesleep", disabled ? "1" : "0"])
        if result.ok { return true }
        let alert = NSAlert()
        alert.messageText = "Couldn't change sleep setting"
        alert.informativeText = "Run ./install.sh in ~/Work/StayAwake to install the sudoers rule.\n\n\(result.output)"
        NSApp.activate()
        alert.runModal()
        return false
    }

    private func sudoPmset(_ args: [String]) -> (ok: Bool, output: String) {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (false, "Failed to launch \(path)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
