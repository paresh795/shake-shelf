import Foundation

/// Detects main-thread stalls and logs them to the diagnostics file.
/// Runs entirely on a background queue, so a blocked main thread cannot stop it.
final class MainThreadWatchdog {
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)

        timer.setEventHandler {
            let mark = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                mark.signal()
            }

            if mark.wait(timeout: .now() + 3) == .timedOut {
                Diagnostics.log("WATCHDOG: main thread blocked for more than 3 seconds")
            }
        }

        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
