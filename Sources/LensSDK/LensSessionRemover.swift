import Foundation

/// Removes a session delegate registration. Dropping this value leaves it registered.
public final class LensSessionRemover {
    private let lock = NSLock()
    private var remove: (() -> Void)?

    internal init(_ remove: @escaping () -> Void) {
        self.remove = remove
    }

    /// Safe to call more than once.
    public func cancel() {
        lock.lock()
        let action = remove
        remove = nil
        lock.unlock()
        action?()
    }
}
