import AppKit
import UniformTypeIdentifiers

// The system's own product image for a hardware model code such as `iPhone17,1`,
// the same artwork Finder and Find My draw. Unknown codes resolve to a dynamic
// type and return nil so the caller can fall back to a symbol.
enum DeviceModelIcon {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static var misses = Set<String>()
    private static let lock = NSLock()

    static func image(for productType: String) -> NSImage? {
        let key = productType.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.contains(",") else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        lock.lock()
        let missed = misses.contains(key)
        lock.unlock()
        if missed { return nil }

        guard let type = UTType(
            tag: key,
            tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
            conformingTo: nil
        ), !type.isDynamic else {
            lock.lock()
            misses.insert(key)
            lock.unlock()
            return nil
        }
        let image = NSWorkspace.shared.icon(for: type)
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
