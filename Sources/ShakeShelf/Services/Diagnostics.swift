import Foundation

enum Diagnostics {
    private static let fileName = "Diagnostics.log"
    private static let maxFileSize = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.paresh.shakeshelf.diagnostics")
    nonisolated(unsafe) private static var logFD: Int32 = -1

    private static var logURL: URL {
        let supportDirectory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        return supportDirectory
            .appendingPathComponent("Shake Shelf", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func setup() {
        prepareFile()
        shakeShelfFatalLogFD = logFD
        installSignalHandlers()
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            Diagnostics.log("UNCAUGHT EXCEPTION: \(exception.name.rawValue) \(exception.reason ?? "")")
            Diagnostics.log("Stack:\n\(stack)")
            abort()
        }

        log("APP STARTED \(appVersionInfo())")
    }

    static func noteTermination() {
        log("APP TERMINATED NORMALLY")
    }

    static func log(_ message: String) {
        queue.sync {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"

            prepareFile()

            if let data = line.data(using: .utf8) {
                if logFD >= 0 {
                    _ = data.withUnsafeBytes { buffer in
                        write(logFD, buffer.baseAddress, buffer.count)
                    }
                } else if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            }

            rotateIfNeeded()
        }
    }

    private static func prepareFile() {
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        if logFD < 0 {
            logFD = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        }
    }

    private static func rotateIfNeeded() {
        guard logFD >= 0 else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard size > maxFileSize else { return }

        close(logFD)
        logFD = -1
        try? FileManager.default.removeItem(at: logURL)
        prepareFile()
    }

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP]

        for signalNumber in signals {
            signal(signalNumber, shakeShelfFatalSignalHandler)
        }
    }

    private static func appVersionInfo() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "v\(version) (\(build)) macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    }
}

private nonisolated(unsafe) var shakeShelfFatalLogFD: Int32 = -1
private nonisolated(unsafe) let shakeShelfFatalMessage: UnsafeMutablePointer<UInt8> = {
    let bytes = Array("[fatal] terminated by signal\n".utf8)
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
    pointer.initialize(from: bytes, count: bytes.count)
    return pointer
}()
private let shakeShelfFatalMessageLength: Int = "[fatal] terminated by signal\n".utf8.count

private func shakeShelfFatalSignalHandler(_ receivedSignal: Int32) {
    if shakeShelfFatalLogFD >= 0 {
        _ = write(shakeShelfFatalLogFD, shakeShelfFatalMessage, shakeShelfFatalMessageLength)
    }
    signal(receivedSignal, SIG_DFL)
    raise(receivedSignal)
}
