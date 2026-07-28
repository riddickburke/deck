import Foundation

#if canImport(Glibc)
import Glibc
#endif

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
        let candidates = platformCandidates()

        var devices: [RockboxDevice] = []
        for candidate in candidates {
            if excludedNames.contains(candidate.name) { continue }

            let rockboxDir = candidate.mountPoint.appendingPathComponent(".rockbox")
            let hasRockbox = FileManager.default.fileExists(atPath: rockboxDir.path)

            // Show Rockbox volumes always; show other removable volumes so a freshly
            // formatted player is still selectable.
            guard hasRockbox || candidate.removable else { continue }

            let info = hasRockbox ? readInfo(rockboxDir) : (nil, nil)
            devices.append(RockboxDevice(
                mountPoint: candidate.mountPoint,
                volumeName: candidate.name,
                rockboxVersion: info.0,
                target: info.1,
                totalCapacity: candidate.total,
                availableCapacity: candidate.available,
                hasRockbox: hasRockbox))
        }

        // Real Rockbox installs first.
        return devices.sorted {
            $0.hasRockbox != $1.hasRockbox ? $0.hasRockbox : $0.volumeName < $1.volumeName
        }
    }

    struct Candidate {
        let mountPoint: URL
        let name: String
        let removable: Bool
        let total: Int64
        let available: Int64
    }

    // MARK: - macOS

    #if os(macOS)
    static func platformCandidates() -> [Candidate] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        ]
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }

        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)) else { return nil }
            let removable = (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || (values.volumeIsInternal == false)
            return Candidate(
                mountPoint: volume,
                name: values.volumeName ?? volume.lastPathComponent,
                removable: removable,
                total: Int64(values.volumeTotalCapacity ?? 0),
                available: Int64(values.volumeAvailableCapacity ?? 0))
        }
    }

    // MARK: - Linux

    #else
    /// swift-corelibs-foundation does not implement `mountedVolumeURLs`, so mounts come
    /// straight from the kernel. Capacity comes from `statvfs`, and removability from
    /// sysfs where the block device can be identified.
    static func platformCandidates() -> [Candidate] {
        var results: [Candidate] = []

        for mount in parseMounts() {
            // Skip the pseudo-filesystems that make up most of /proc/mounts.
            guard !Self.ignoredFilesystems.contains(mount.fstype) else { continue }
            guard mount.mountPoint != "/" else { continue }

            let url = URL(fileURLWithPath: mount.mountPoint)
            let capacity = capacity(of: mount.mountPoint)

            results.append(Candidate(
                mountPoint: url,
                name: url.lastPathComponent.isEmpty ? mount.device : url.lastPathComponent,
                removable: isRemovable(mount: mount),
                total: capacity.total,
                available: capacity.available))
        }
        return results
    }

    /// Kernel and container filesystems that are never a music player.
    static let ignoredFilesystems: Set<String> = [
        "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "securityfs", "cgroup", "cgroup2",
        "pstore", "efivarfs", "bpf", "debugfs", "tracefs", "configfs", "fusectl",
        "hugetlbfs", "mqueue", "binfmt_misc", "autofs", "squashfs", "ramfs", "rpc_pipefs",
        "nsfs", "overlay", "fuse.gvfsd-fuse", "fuse.portal", "selinuxfs",
    ]

    /// Where desktop environments and manual mounts put removable media.
    static let removableRoots = ["/media", "/run/media", "/mnt", "/media/" + (ProcessInfo.processInfo.environment["USER"] ?? "")]

    struct Mount {
        let device: String
        let mountPoint: String
        let fstype: String
    }

    static func parseMounts(path: String = "/proc/self/mounts") -> [Mount] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { return nil }
            return Mount(
                device: unescapeOctal(String(fields[0])),
                mountPoint: unescapeOctal(String(fields[1])),
                fstype: String(fields[2]))
        }
    }

    /// `/proc/mounts` escapes spaces, tabs, newlines and backslashes as octal.
    /// A player named "MY PLAYER" arrives as `/media/user/MY\040PLAYER`.
    static func unescapeOctal(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = ""
        var iterator = Array(raw)
        var i = 0
        while i < iterator.count {
            if iterator[i] == "\\", i + 3 < iterator.count,
               let value = UInt8(String(iterator[(i + 1)...(i + 3)]), radix: 8) {
                out.append(Character(UnicodeScalar(value)))
                i += 4
            } else {
                out.append(iterator[i])
                i += 1
            }
        }
        return out
    }

    /// Filesystems typical of a player, or a mount under a removable-media root, or a
    /// block device sysfs marks removable.
    static func isRemovable(mount: Mount) -> Bool {
        let portableFilesystems: Set<String> = ["vfat", "msdos", "exfat", "ntfs", "ntfs3", "fuseblk", "hfsplus"]
        if portableFilesystems.contains(mount.fstype) { return true }
        if removableRoots.contains(where: { !$0.isEmpty && mount.mountPoint.hasPrefix($0 + "/") }) {
            return true
        }
        return sysfsRemovable(device: mount.device)
    }

    /// `/sys/block/<disk>/removable` is 1 for USB mass storage and SD readers.
    static func sysfsRemovable(device: String) -> Bool {
        guard device.hasPrefix("/dev/") else { return false }
        var name = String(device.dropFirst("/dev/".count))
        // Strip the partition suffix: sda1 -> sda, mmcblk0p1 -> mmcblk0, nvme0n1p1 -> nvme0n1.
        if let range = name.range(of: #"p?\d+$"#, options: .regularExpression) {
            let stripped = String(name[..<range.lowerBound])
            if !stripped.isEmpty, FileManager.default.fileExists(atPath: "/sys/block/\(stripped)") {
                name = stripped
            }
        }
        let flag = "/sys/block/\(name)/removable"
        guard let value = try? String(contentsOfFile: flag, encoding: .utf8) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func capacity(of path: String) -> (total: Int64, available: Int64) {
        var stats = statvfs()
        guard statvfs(path, &stats) == 0 else { return (0, 0) }
        // f_frsize is the fragment size; f_bsize can differ and is the wrong multiplier.
        let unit = Int64(stats.f_frsize > 0 ? stats.f_frsize : stats.f_bsize)
        let total = Int64(stats.f_blocks) * unit
        // f_bavail excludes blocks reserved for root, which is what a user can actually use.
        let available = Int64(stats.f_bavail) * unit
        return (total, available)
    }
    #endif

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
