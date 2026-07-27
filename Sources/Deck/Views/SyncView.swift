import DeckCore
import SwiftUI

struct SyncView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                deviceSection
                optionsSection
                selectionSection
                planSection
                if app.isSyncing { progressSection }
                if let report = app.syncReport { reportSection(report) }
            }
            .padding(18)
        }
    }

    // MARK: Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "target device")

            if app.devices.isEmpty {
                Text("no removable volume mounted.")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.muted)
                Text("connect your player over usb and put it in disk mode.")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted.opacity(0.7))
            } else {
                ForEach(app.devices) { device in
                    deviceCard(device)
                }
            }

            BracketButton(label: "rescan devices") { app.refreshDevices() }
        }
    }

    private func deviceCard(_ device: RockboxDevice) -> some View {
        let selected = app.selectedDevice?.id == device.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(selected ? "▸" : "·")
                    .font(DeckFont.mono(12))
                    .foregroundStyle(selected ? app.theme.green : app.theme.muted)
                Text(device.displayName)
                    .font(DeckFont.mono(12))
                    .foregroundStyle(app.theme.fg)
                if let version = device.rockboxVersion {
                    Text("rockbox \(version)")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.green)
                } else {
                    Text("no .rockbox found")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.yellow)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                BlockMeter(
                    fraction: device.capacityFraction, width: 24,
                    tint: device.capacityFraction > 0.9 ? app.theme.red : app.theme.accent)
                Text("\(device.usedCapacity.byteString) / \(device.totalCapacity.byteString)  ·  \(device.availableCapacity.byteString) free")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
            }
            Text(device.mountPoint.path)
                .font(DeckFont.mono(9))
                .foregroundStyle(app.theme.muted.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(app.theme.bgInset)
        .overlay(Rectangle().strokeBorder(
            selected ? app.theme.accent : app.theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            app.selectedDevice = device
            app.syncPlan = nil
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "options")

            toggleRow(
                "convert flac/alac to mp3",
                detail: "originals stay untouched — only the device copy is converted",
                isOn: Binding(
                    get: { app.config.convertFlacToMP3 },
                    set: { app.config.convertFlacToMP3 = $0; app.syncPlan = nil })
            )

            if app.config.convertFlacToMP3 {
                HStack(spacing: 8) {
                    Text("  quality")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.muted)
                    Picker("", selection: Binding(
                        get: { app.config.mp3Quality },
                        set: { app.config.mp3Quality = $0; app.syncPlan = nil })
                    ) {
                        Text("V0 · ~245k").tag(0)
                        Text("V2 · ~190k").tag(2)
                        Text("V4 · ~165k").tag(4)
                        Text("V6 · ~115k").tag(6)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                }
            }

            toggleRow(
                "write cover.jpg to device",
                detail: "resized to \(app.config.deviceArtworkSize)px so rockbox can load it",
                isOn: Binding(
                    get: { app.config.writeDeviceArtwork },
                    set: { app.config.writeDeviceArtwork = $0 })
            )

            toggleRow(
                "remove files no longer selected",
                detail: "only removes files this app previously wrote",
                isOn: $app.removeOrphans,
                tint: app.theme.red
            )
        }
    }

    private func toggleRow(
        _ label: String, detail: String, isOn: Binding<Bool>, tint: Color? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(isOn.wrappedValue ? "[x]" : "[ ]")
                .font(DeckFont.mono(11))
                .foregroundStyle(isOn.wrappedValue ? (tint ?? app.theme.green) : app.theme.muted)
                .onTapGesture { isOn.wrappedValue.toggle() }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                Text(detail)
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    // MARK: Selection

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "selection")
            let selection = app.syncSelection
            if selection.isEmpty {
                Text("no playlists marked for sync.")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.muted)
                Text("click the ◇ next to a playlist in the sidebar to include it.")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted.opacity(0.7))
            } else {
                let bytes = selection.reduce(Int64(0)) { $0 + $1.fileSize }
                Text("\(selection.count) tracks · \(bytes.byteString) at source")
                    .font(DeckFont.mono(11))
                    .foregroundStyle(app.theme.fg)
                ForEach(app.playlists.filter(\.syncEnabled)) { playlist in
                    Text("  ◆ \(playlist.name) (\(playlist.trackPaths.count))")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.green)
                }
            }
        }
    }

    // MARK: Plan

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BracketButton(
                    label: app.isPlanning ? "planning…" : "dry run",
                    disabled: app.isPlanning || app.selectedDevice == nil
                ) { app.buildPlan() }

                if let plan = app.syncPlan, !plan.transfers.isEmpty {
                    BracketButton(
                        label: app.isSyncing ? "syncing…" : "start sync",
                        tint: plan.fits ? app.theme.green : app.theme.red,
                        disabled: app.isSyncing || !plan.fits
                    ) { app.runSync() }
                }
                if app.isSyncing {
                    BracketButton(label: "cancel", tint: app.theme.red) { app.cancelSync() }
                }
            }

            if let plan = app.syncPlan {
                VStack(alignment: .leading, spacing: 4) {
                    statRow("to copy", "\(plan.transfers.count - plan.convertCount)", app.theme.accent)
                    if plan.convertCount > 0 {
                        statRow("to convert", "\(plan.convertCount)", app.theme.magenta)
                    }
                    statRow("already current", "\(plan.upToDateCount)", app.theme.muted)
                    if !plan.orphans.isEmpty {
                        statRow(
                            app.removeOrphans ? "will remove" : "stale on device",
                            "\(plan.orphans.count) · \(plan.orphanBytes.byteString)",
                            app.removeOrphans ? app.theme.red : app.theme.yellow)
                    }
                    statRow("transfer size", plan.bytesToTransfer.byteString, app.theme.fg)
                    statRow(
                        plan.fits ? "free after sync" : "over capacity by",
                        abs(plan.headroomAfterSync).byteString,
                        plan.fits ? app.theme.green : app.theme.red)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(app.theme.bgInset)
                .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))

                if !plan.transfers.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(plan.transfers.prefix(300)) { action in
                                HStack(spacing: 6) {
                                    Text(action.kind == .convert ? "cnv" : "cp ")
                                        .foregroundStyle(action.kind == .convert
                                            ? app.theme.magenta : app.theme.accent)
                                    Text(relativePath(action.destination))
                                        .foregroundStyle(app.theme.muted)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(action.estimatedBytes.byteString)
                                        .foregroundStyle(app.theme.muted.opacity(0.6))
                                }
                                .font(DeckFont.mono(9))
                            }
                            if plan.transfers.count > 300 {
                                Text("… and \(plan.transfers.count - 300) more")
                                    .font(DeckFont.mono(9))
                                    .foregroundStyle(app.theme.muted)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("file list")
                            .font(DeckFont.mono(10))
                            .foregroundStyle(app.theme.accent)
                    }
                }
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = app.selectedDevice?.mountPoint.path else { return url.path }
        return url.path.replacingOccurrences(of: root, with: "")
    }

    private func statRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(DeckFont.mono(10))
                .foregroundStyle(app.theme.muted)
            Spacer()
            Text(value)
                .font(DeckFont.mono(10))
                .foregroundStyle(color)
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = app.syncProgress {
                let overall = progress.total > 0
                    ? Double(progress.completed) / Double(progress.total) : 0
                HStack(spacing: 10) {
                    BlockMeter(fraction: overall, width: 30, tint: app.theme.green)
                    Text("\(progress.completed)/\(progress.total)")
                        .font(DeckFont.mono(10))
                        .foregroundStyle(app.theme.fg)
                }
                Text("\(progress.phase): \(progress.currentFile)")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.muted)
                    .lineLimit(1)
                if progress.currentFileFraction > 0 {
                    BlockMeter(
                        fraction: progress.currentFileFraction, width: 30,
                        tint: app.theme.magenta)
                }
                Text("\(progress.bytesWritten.byteString) of \(progress.bytesTotal.byteString)")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(app.theme.bgInset)
        .overlay(Rectangle().strokeBorder(app.theme.accent, lineWidth: 1))
    }

    // MARK: Report

    private func reportSection(_ report: SyncReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "last sync")
            statRow("copied", "\(report.copied)", app.theme.accent)
            statRow("converted", "\(report.converted)", app.theme.magenta)
            statRow("removed", "\(report.removed)", app.theme.red)
            statRow("skipped", "\(report.skipped)", app.theme.yellow)
            statRow("playlists written", "\(report.playlistsWritten)", app.theme.green)
            statRow("written", report.bytesWritten.byteString, app.theme.fg)
            statRow("elapsed", report.duration.clockString, app.theme.muted)

            if !report.errors.isEmpty {
                Text("errors")
                    .font(DeckFont.mono(10))
                    .foregroundStyle(app.theme.red)
                    .padding(.top, 4)
                ForEach(Array(report.errors.prefix(20).enumerated()), id: \.offset) { _, error in
                    Text("  \(error)")
                        .font(DeckFont.mono(9))
                        .foregroundStyle(app.theme.red.opacity(0.85))
                        .lineLimit(2)
                }
            }

            if report.copied + report.converted > 0 {
                Text("tip: on the player, run settings → general → database → update now so the new files appear in the database browser.")
                    .font(DeckFont.mono(9))
                    .foregroundStyle(app.theme.muted)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(app.theme.bgInset)
        .overlay(Rectangle().strokeBorder(app.theme.border, lineWidth: 1))
    }
}
