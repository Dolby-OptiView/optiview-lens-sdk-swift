import Foundation

/// Release closures captured where a registration is made, so subscribe and
/// unsubscribe never live in separate lists that can fall out of sync.
/// `release()` runs everything still held, newest first, once; anything added
/// afterwards is released immediately, so a registration made during teardown
/// cannot outlive it.
internal final class Teardown {
    private final class Entry {
        let release: () -> Void
        init(_ release: @escaping () -> Void) { self.release = release }
    }

    private let lock = NSLock()
    private var entries: [Entry]? = []

    /// Captures a release at its registration site; the returned closure releases just it.
    @discardableResult
    func add(_ release: @escaping () -> Void) -> () -> Void {
        lock.lock()
        guard entries != nil else {
            lock.unlock()
            release()
            return {}
        }
        let entry = Entry(release)
        entries!.append(entry)
        lock.unlock()
        return {
            self.lock.lock()
            let index = self.entries?.firstIndex { $0 === entry }
            if let index { self.entries!.remove(at: index) }
            self.lock.unlock()
            if index != nil { entry.release() }
        }
    }

    func release() {
        lock.lock()
        guard let held = entries else {
            lock.unlock()
            return
        }
        entries = nil
        lock.unlock()
        for entry in held.reversed() { entry.release() }
    }
}
