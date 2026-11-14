import Foundation

struct FolderPreference {
    private let defaults: UserDefaults
    private let key = "scan.lastFolderBookmark"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func remember(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }

    enum Restoration {
        case none
        case unavailable
        case folder(URL)
    }

    func restore() -> Restoration {
        guard let data = defaults.data(forKey: key) else { return .none }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: url.path) else { return .unavailable }
            if stale { try? remember(url) }
            return .folder(url)
        } catch { return .unavailable }
    }
}
