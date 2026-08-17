import AppKit
import ShakeShelfCore

@MainActor
final class ShelfHistoryRecorder {
    private var store: ShelfHistoryStore
    private var debounceWorkItem: DispatchWorkItem?
    private var heartbeat: Timer?
    private var lastKnownURLs: [URL] = []

    private let debounceInterval: TimeInterval = 2
    private let heartbeatInterval: TimeInterval = 60

    init(store: ShelfHistoryStore) {
        self.store = store
    }

    var sessionList: [ShelfSession] {
        store.allSessions()
    }

    func restoreState(from session: ShelfSession) -> (urls: [URL], missing: Int) {
        store.restoreState(from: session)
    }

    func contentsChanged(to urls: [URL]) {
        lastKnownURLs = urls
        scheduleRecord(urls)
        updateHeartbeat(for: urls)
    }

    func contentsWillClear(current urls: [URL]) {
        record(urls, immediate: true)
    }

    func recordAtTermination() {
        record(lastKnownURLs, immediate: true)
    }

    func clearHistory() {
        debounceWorkItem?.cancel()
        store.clearHistory()
        persist()
    }

    private func record(_ urls: [URL], immediate: Bool) {
        if immediate {
            debounceWorkItem?.cancel()
            store.record(urls: urls, at: Date())
            persist()
        } else {
            scheduleRecord(urls)
        }
    }

    private func scheduleRecord(_ urls: [URL]) {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.record(urls: urls, at: Date())
            self.persist()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func updateHeartbeat(for urls: [URL]) {
        if urls.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
        } else if heartbeat == nil {
            heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
                self?.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() {
        store.record(urls: lastKnownURLs, at: Date())
        persist()
    }

    private func persist() {
        let snapshot = store
        DispatchQueue.global(qos: .utility).async {
            snapshot.persistToDisk()
        }
    }
}

enum ShelfHistoryFormatter {
    static func title(for session: ShelfSession) -> String {
        let day = dayLabel(for: session.lastSeen)
        let time = Self.timeFormatter.string(from: session.lastSeen)
        let count = session.urls.count
        let fileLabel = count == 1 ? "file" : "files"
        return "\(day) \(time) · \(count) \(fileLabel) · \(durationLabel(from: session.firstSeen, to: session.lastSeen))"
    }

    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return Self.weekdayFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static func durationLabel(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))

        if seconds < 60 {
            return "moments"
        }

        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours) h" : "\(hours) h \(remainingMinutes) m"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days) d" : "\(days) d \(remainingHours) h"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
