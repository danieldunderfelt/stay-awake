import AppKit
import IOKit

// Toggles pmset's SleepDisabled flag, which (unlike caffeinate) also blocks
// clamshell sleep with no external display. While the lid is closed and no
// external display is connected it can also switch to Low Power Mode. Needs the
// sudoers rule from install.sh.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let toggleItem = NSMenuItem(title: "Stay Awake (even with lid closed)", action: #selector(toggle), keyEquivalent: "")
    private let lowPowerItem = NSMenuItem(title: "Low Power Mode While Lid Closed", action: #selector(toggleLowPower), keyEquivalent: "")
    // Set while we've temporarily lifted SleepDisabled for a manual sleep.
    private let reenableKey = "reenableOnWake"
    private let lowPowerKey = "lowPowerWhenClosed"
    // Power modes to restore on lid open, e.g. ["-b": "0", "-c": "2"]; present while Low Power is applied.
    private let savedModesKey = "savedPowerModes"
    private var lidTimer: Timer?

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
        restorePowerModes()
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

    @objc private func updatePowerMode() {
        let applied = UserDefaults.standard.dictionary(forKey: savedModesKey) != nil
        let wantLowPower = lidClosed && !externalDisplayConnected && UserDefaults.standard.bool(forKey: lowPowerKey) && (applied || sleepDisabled)
        if wantLowPower, !applied {
            let modes = currentPowerModes()
            if sudoPmset(["-a", "powermode", "1"]).ok {
                UserDefaults.standard.set(modes, forKey: savedModesKey)
            }
        } else if !wantLowPower, applied {
            restorePowerModes()
        }
    }

    private func restorePowerModes() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedModesKey) as? [String: String] else { return }
        if saved.allSatisfy({ sudoPmset([$0.key, "powermode", $0.value]).ok }) {
            UserDefaults.standard.removeObject(forKey: savedModesKey)
        }
    }

    // Reads the per-power-source powermode from `pmset -g custom`, keyed by pmset flag.
    private func currentPowerModes() -> [String: String] {
        var modes: [String: String] = [:]
        var flag: String?
        for line in run("/usr/bin/pmset", ["-g", "custom"]).output.split(separator: "\n") {
            if line.hasPrefix("Battery Power") {
                flag = "-b"
            } else if line.hasPrefix("AC Power") {
                flag = "-c"
            } else if let flag {
                let parts = line.split(separator: " ")
                if parts.count == 2, parts[0] == "powermode" { modes[flag] = String(parts[1]) }
            }
        }
        return modes
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
