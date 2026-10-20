import CoreGraphics
import Foundation
import IOKit.ps

/// State of the Mac that decides whether background work may run now.
public enum Machine {
    /// Plugged in (desktops always are).
    public static var onACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        return (type as String) == "AC Power"
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    public static var idleSeconds: Double {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Full executable paths of running processes (`ps -axo comm=` prints full paths on macOS).
    public static func runningExecutables() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Something is running from inside the folder (a game is open).
    public static func isRunning(inside folder: URL, executables: [String]? = nil) -> Bool {
        let prefix = folder.standardizedFileURL.path + "/"
        return (executables ?? runningExecutables()).contains { $0.hasPrefix(prefix) }
    }
}
