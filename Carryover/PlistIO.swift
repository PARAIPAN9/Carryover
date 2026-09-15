import Foundation

/// Format-preserving property list reading and writing. The manifest is XML and
/// conversation.plist is binary; each file is written back in the format it was read in.
enum PlistIO {
    struct File {
        var root: Any
        var format: PropertyListSerialization.PropertyListFormat
    }

    static func read(_ url: URL) throws -> File {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return File(root: root, format: format)
    }

    static func write(_ file: File, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: file.root, format: file.format, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Transcript entries reference files in the container's Snapshots/ directory via
    /// "snapshotIdBefore"/"snapshotIdAfter" keys at arbitrary depth.
    static func collectSnapshotIDs(in value: Any) -> Set<String> {
        var ids = Set<String>()
        collect(value, into: &ids)
        return ids
    }

    private static func collect(_ value: Any, into ids: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, sub) in dict {
                if key == "snapshotIdBefore" || key == "snapshotIdAfter", let id = sub as? String {
                    ids.insert(id)
                } else {
                    collect(sub, into: &ids)
                }
            }
        } else if let array = value as? [Any] {
            for sub in array {
                collect(sub, into: &ids)
            }
        }
    }
}
