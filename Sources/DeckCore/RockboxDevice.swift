import Foundation

/// A mounted Rockbox player. Detection is by the presence of a `.rockbox` directory at
/// the volume root, which is how every Rockbox install is laid out regardless of target.
public struct RockboxDevice: Identifiable, Hashable, Sendable {
    public var id: String { mountPoint.path }

    public let mountPoint: URL
    public let volumeName: String
    public let rockboxVersion: String?
    public let target: String?
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    /// True when `.rockbox` is present. False means we found a removable volume that
    /// might be a player but has no Rockbox install yet.
    public let hasRockbox: Bool

    public var usedCapacity: Int64 { totalCapacity - availableCapacity }
    public var musicDirectory: URL { mountPoint.appendingPathComponent("Music") }

    public var displayName: String {
        if let target, !target.isEmpty { return "\(volumeName) · \(target)" }
        return volumeName
    }

    public var capacityFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedCapacity) / Double(totalCapacity)
    }

    public init(
        mountPoint: URL, volumeName: String, rockboxVersion: String?, target: String?,
        totalCapacity: Int64, availableCapacity: Int64, hasRockbox: Bool
    ) {
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.rockboxVersion = rockboxVersion
        self.target = target
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.hasRockbox = hasRockbox
    }
}

public enum DeviceScanner {
    /// Volumes we should never offer as a sync target.
    static let excludedNames: Set<String> = ["Macintosh HD", "Preboot", "Recovery", "VM", "Data"]

    public static func scan() -> [RockboxDevice] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        ]
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }

        var devices: [RockboxDevice] = []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)) else { continue }
            let name = values.volumeName ?? volume.lastPathComponent
            if excludedNames.contains(name) { continue }

            let removable = (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || (values.volumeIsInternal == false)

            let rockboxDir = volume.appendingPathComponent(".rockbox")
            let hasRockbox = fm.fileExists(atPath: rockboxDir.path)

            // Show Rockbox volumes always; show other removable volumes so a freshly
            // formatted player is still selectable.
            guard hasRockbox || removable else { continue }

            let info = hasRockbox ? readInfo(rockboxDir) : (nil, nil)
            devices.append(RockboxDevice(
                mountPoint: volume,
                volumeName: name,
                rockboxVersion: info.0,
                target: info.1,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
                hasRockbox: hasRockbox
            ))
        }
        // Real Rockbox installs first.
        return devices.sorted {
            $0.hasRockbox != $1.hasRockbox ? $0.hasRockbox : $0.volumeName < $1.volumeName
        }
    }

    /// `.rockbox/rockbox-info.txt` is a plain `Key: value` file written by the build.
    public static func readInfo(_ rockboxDir: URL) -> (version: String?, target: String?) {
        let infoURL = rockboxDir.appendingPathComponent("rockbox-info.txt")
        guard let text = try? String(contentsOf: infoURL, encoding: .utf8) else { return (nil, nil) }
        var version: String?
        var target: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "version": version = parts[1]
            case "target": target = parts[1]
            default: break
            }
        }
        return (version, target)
    }
}
