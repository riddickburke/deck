import CGtk4
import DeckCore
import Foundation

/// Builds the window once and updates it in place. GTK has no diffing layer, so each
/// section has an explicit refresh and only the list is rebuilt wholesale.
final class Window {
    private let model: AppModel
    private var window: Widget?

    // Retained so refresh can update them without walking the widget tree.
    private var deviceLabel: Widget?
    private var contentTitle: Widget?
    private var contentList: Widget?
    private var sidebarList: Widget?
    private var nowTitle: Widget?
    private var nowArtist: Widget?
    private var nowArt: Widget?
    private var playButton: Widget?
    private var positionLabel: Widget?
    private var durationLabel: Widget?
    private var scrubber: Widget?
    private var statusContext: Widget?
    private var statusMessage: Widget?

    /// Suppresses the scrubber's own change handler while we set its value from a tick.
    private var updatingScrubber = false
    /// Rows currently shown, so activation can map an index back to an action.
    private var rowActions: [() -> Void] = []

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Construction

    func build(application: Widget) {
        let win = deck_app_window_new(application)!
        window = win
        deck_window_set_title(win, "deck")
        deck_window_set_default_size(win, 1180, 760)

        let root = GTK.box(horizontal: false)
        root.append(buildTitlebar())

        let main = GTK.box(horizontal: true)
        main.expandVertically()
        main.append(buildSidebar())
        main.append(GTK.separator(horizontal: false))
        main.append(buildContent())
        root.append(main)

        root.append(buildTransport())
        root.append(buildStatusBar())

        deck_window_set_child(win, root)
        installKeyboard(on: win)

        model.onChange = { [weak self] in self?.refresh() }

        // Playback position and device presence both need polling.
        everyMilliseconds(500) { [weak self] in
            guard let self else { return false }
            if self.model.isPlaying { self.model.tick() }
            return true
        }
        everyMilliseconds(4000) { [weak self] in
            guard let self else { return false }
            self.model.refreshDevices()
            return true
        }

        Styling.apply(model.theme)
        deck_window_present(win)

        model.refreshDevices()
        model.scanLibrary()
        refresh()
    }

    private func buildTitlebar() -> Widget {
        let bar = GTK.box(horizontal: true, spacing: 8, css: "titlebar")
        bar.append(GTK.box(horizontal: false).styled("rule").sized(width: 2, height: 11))
        bar.append(GTK.label("deck", css: "title"))

        let spacer = GTK.box(horizontal: true)
        spacer.expandHorizontally()
        bar.append(spacer)

        let device = GTK.label("no device", css: "muted")
        deviceLabel = device
        bar.append(device)
        return bar
    }

    private func buildSidebar() -> Widget {
        let panel = GTK.box(horizontal: false, css: "sidebar")
        panel.sized(width: 210)

        let list = GTK.list()
        sidebarList = list
        panel.append(GTK.scrolled(list))
        return panel
    }

    private func buildContent() -> Widget {
        let panel = GTK.box(horizontal: false, css: "panel")
        panel.expandHorizontally()
        panel.expandVertically()

        let header = GTK.box(horizontal: true, spacing: 8, css: "titlebar")
        header.append(GTK.box(horizontal: false).styled("rule").sized(width: 2, height: 11))
        let title = GTK.label("deck://albums", css: "title")
        contentTitle = title
        header.append(title)
        panel.append(header)

        let list = GTK.list()
        contentList = list
        panel.append(GTK.scrolled(list))

        onSignalWithArgument(list, "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let index = Int(deck_listbox_row_index(row))
            guard self.rowActions.indices.contains(index) else { return }
            self.model.selection = index
            self.rowActions[index]()
        }
        return panel
    }

    private func buildTransport() -> Widget {
        let bar = GTK.box(horizontal: true, spacing: 14, css: "transport")

        let art = GTK.picture(size: 46).styled("art")
        nowArt = art
        bar.append(art)

        let info = GTK.box(horizontal: false, spacing: 2)
        info.sized(width: 220)
        let title = GTK.label("nothing playing")
        let artist = GTK.label("—", css: "muted")
        nowTitle = title
        nowArtist = artist
        info.append(title)
        info.append(artist)
        bar.append(info)

        let centre = GTK.box(horizontal: false, spacing: 4)
        centre.expandHorizontally()

        let buttons = GTK.box(horizontal: true, spacing: 10)
        buttons.append(GTK.button("[ ⇄ ]") { [weak self] in self?.model.toggleShuffle() })
        buttons.append(GTK.button("[ |◀ ]") { [weak self] in self?.model.previous() })
        let play = GTK.button("[ ▶ play ]", css: "primary") { [weak self] in
            self?.model.togglePlayPause()
        }
        playButton = play
        buttons.append(play)
        buttons.append(GTK.button("[ ▶| ]") { [weak self] in self?.model.next() })
        buttons.append(GTK.button("[ ↻ ]") { [weak self] in self?.model.cycleRepeat() })
        centre.append(buttons)

        let scrubRow = GTK.box(horizontal: true, spacing: 8)
        let elapsed = GTK.label("0:00", css: "muted")
        positionLabel = elapsed
        scrubRow.append(elapsed)

        let scale = GTK.scale(min: 0, max: 1)
        scale.expandHorizontally()
        scrubber = scale
        onSignal(scale, "value-changed") { [weak self] in
            guard let self, !self.updatingScrubber else { return }
            self.model.seek(to: deck_scale_value(scale))
        }
        scrubRow.append(scale)

        let total = GTK.label("0:00", css: "muted")
        durationLabel = total
        scrubRow.append(total)
        centre.append(scrubRow)

        bar.append(centre)
        return bar
    }

    private func buildStatusBar() -> Widget {
        let bar = GTK.box(horizontal: true, spacing: 0, css: "statusbar")
        bar.append(GTK.label("NORMAL", css: "mode"))

        let context = GTK.label("albums", css: "segment")
        statusContext = context
        bar.append(context)

        let message = GTK.label("", css: "muted")
        deck_set_margins(message, 0, 0, 10, 0)
        statusMessage = message
        bar.append(message)
        return bar
    }

    // MARK: - Refresh

    func refresh() {
        refreshSidebar()
        refreshContent()
        refreshTransport()
        refreshStatus()
    }

    private func refreshSidebar() {
        guard let list = sidebarList else { return }
        deck_listbox_remove_all(list)

        var actions: [() -> Void] = []

        func entry(_ label: String, _ detail: String, _ action: @escaping () -> Void) {
            let text = GTK.label(label)
            text.expandHorizontally()
            let row = GTK.row([text, GTK.label(detail, css: "muted")])
            deck_listbox_append(list, row)
            actions.append(action)
        }

        entry("albums", "\(model.albums.count)") { [weak self] in self?.go(.albums) }
        entry("artists", "\(model.artistNames.count)") { [weak self] in self?.go(.artists) }
        entry("songs", "\(model.tracks.count)") { [weak self] in self?.go(.songs) }
        entry("queue", "\(model.queue.count)") { [weak self] in self?.go(.queue) }
        entry("sync", model.selectedDevice == nil ? "—" : "ready") { [weak self] in
            self?.go(.sync)
        }

        for playlist in model.playlists {
            let marker = playlist.syncEnabled ? "◆" : "◇"
            entry("\(marker) \(playlist.name)", "\(playlist.trackPaths.count)") { [weak self] in
                guard let self else { return }
                self.model.play(tracks: self.model.tracks(in: playlist))
            }
        }

        sidebarActions = actions
        onSignalWithArgument(list, "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let index = Int(deck_listbox_row_index(row))
            guard self.sidebarActions.indices.contains(index) else { return }
            self.sidebarActions[index]()
        }
    }

    private var sidebarActions: [() -> Void] = []

    private func refreshContent() {
        guard let list = contentList else { return }
        deck_listbox_remove_all(list)
        rowActions = []

        switch model.route {
        case .albums:
            contentTitle?.setText("deck://albums")
            for album in model.albums {
                appendAlbumRow(album, to: list)
            }
        case .artists:
            contentTitle?.setText("deck://artists")
            for artist in model.artistNames {
                let name = GTK.label(artist)
                name.expandHorizontally()
                let count = model.albums.count { $0.artist == artist }
                deck_listbox_append(list, GTK.row([name, GTK.label("\(count)", css: "muted")]))
                rowActions.append {}
            }
        case .songs:
            contentTitle?.setText("deck://songs")
            let all = model.tracks
            for (index, track) in all.enumerated() {
                appendTrackRow(track, to: list) { [weak self] in
                    self?.model.play(tracks: all, startingAt: index)
                }
            }
        case .album(let key):
            guard let album = model.album(for: key) else { break }
            contentTitle?.setText("deck://albums/\(album.title)")
            for (index, track) in album.tracks.enumerated() {
                appendTrackRow(track, to: list) { [weak self] in
                    self?.model.play(tracks: album.tracks, startingAt: index)
                }
            }
        case .queue:
            contentTitle?.setText("deck://queue")
            let queued = model.queue
            for (index, track) in queued.enumerated() {
                appendTrackRow(track, to: list) { [weak self] in
                    self?.model.play(tracks: queued, startingAt: index)
                }
            }
        case .sync:
            contentTitle?.setText("deck://sync")
            appendSyncRows(to: list)
        case .settings:
            contentTitle?.setText("deck://settings")
            appendSettingsRows(to: list)
        }
    }

    private func appendAlbumRow(_ album: Album, to list: Widget) {
        let art = GTK.picture(size: 44).styled("art")
        loadArtwork(album, into: art)

        let text = GTK.box(horizontal: false, spacing: 1)
        text.expandHorizontally()
        text.append(GTK.label(album.title))
        let detail = album.year.map { "\(album.artist) · \($0)" } ?? album.artist
        text.append(GTK.label(detail, css: "muted"))

        let meta = GTK.label("\(album.tracks.count) tracks", css: "muted")
        deck_listbox_append(list, GTK.row([art, text, meta]))
        rowActions.append { [weak self] in self?.go(.album(album.key)) }
    }

    private func appendTrackRow(_ track: Track, to list: Widget, action: @escaping () -> Void) {
        let number = GTK.label(track.trackNumber.map { String(format: "%2d", $0) } ?? "  ", css: "muted")
        number.sized(width: 24)

        let text = GTK.box(horizontal: false, spacing: 1)
        text.expandHorizontally()
        let playing = model.currentTrack?.id == track.id
        text.append(GTK.label(track.title, css: playing ? "ok" : nil))
        text.append(GTK.label(track.artist, css: "muted"))

        let codec = GTK.label(track.codec, css: "muted")
        codec.sized(width: 48)
        let time = GTK.label(track.duration.clockString, css: "muted")

        deck_listbox_append(list, GTK.row([number, text, codec, time]))
        rowActions.append(action)
    }

    private func appendSyncRows(to list: Widget) {
        if model.devices.isEmpty {
            deck_listbox_append(list, GTK.row([
                GTK.label("no removable volume mounted — connect the player in disk mode", css: "muted"),
            ]))
            rowActions.append {}
            return
        }

        for device in model.devices {
            let marker = model.selectedDevice?.id == device.id ? "▸" : "·"
            let text = GTK.box(horizontal: false, spacing: 1)
            text.expandHorizontally()
            text.append(GTK.label("\(marker) \(device.displayName)"))
            text.append(GTK.label(
                "\(device.availableCapacity.byteString) free of \(device.totalCapacity.byteString)",
                css: "muted"))
            let status = GTK.label(
                device.hasRockbox ? "rockbox \(device.rockboxVersion ?? "?")" : "no .rockbox",
                css: device.hasRockbox ? "ok" : "warn")
            deck_listbox_append(list, GTK.row([text, status]))
            rowActions.append { [weak self] in
                self?.model.selectedDevice = device
                self?.model.syncPlan = nil
                self?.refresh()
            }
        }

        let selection = model.syncSelection
        deck_listbox_append(list, GTK.row([
            GTK.label("selection: \(selection.count) tracks", css: "muted"),
        ]))
        rowActions.append {}

        if let plan = model.syncPlan {
            let summary = "\(plan.transfers.count) to transfer · "
                + "\(plan.upToDateCount) current · \(plan.bytesToTransfer.byteString)"
            deck_listbox_append(list, GTK.row([
                GTK.label(summary, css: plan.fits ? "ok" : "danger"),
            ]))
            rowActions.append {}

            deck_listbox_append(list, GTK.row([GTK.label("[ start sync ]", css: "ok")]))
            rowActions.append { [weak self] in self?.model.runSync() }
        } else {
            deck_listbox_append(list, GTK.row([GTK.label("[ dry run ]", css: "accent")]))
            rowActions.append { [weak self] in self?.model.buildPlan() }
        }

        if let progress = model.syncProgress {
            deck_listbox_append(list, GTK.row([
                GTK.label("\(progress.phase) \(progress.completed)/\(progress.total) · \(progress.currentFile)",
                          css: "muted"),
            ]))
            rowActions.append {}
        }
    }

    private func appendSettingsRows(to list: Widget) {
        for root in model.config.libraryRoots {
            deck_listbox_append(list, GTK.row([GTK.label(root, css: "muted")]))
            rowActions.append {}
        }

        deck_listbox_append(list, GTK.row([GTK.label("[ + add music folder ]", css: "accent")]))
        rowActions.append { [weak self] in self?.chooseFolder() }

        deck_listbox_append(list, GTK.row([GTK.label("[ rescan library ]")]))
        rowActions.append { [weak self] in self?.model.scanLibrary() }

        deck_listbox_append(list, GTK.row([
            GTK.label("theme: \(model.theme.name)  [ cycle with t ]", css: "muted"),
        ]))
        rowActions.append { [weak self] in self?.model.cycleTheme() }

        let tools = [
            ("ffmpeg", Shell.has("ffmpeg")),
            ("ffprobe", Shell.has("ffprobe")),
            ("mpv", Shell.has("mpv")),
        ]
        for (name, present) in tools {
            deck_listbox_append(list, GTK.row([
                GTK.label("\(present ? "[ok]" : "[--]") \(name)", css: present ? "ok" : "danger"),
            ]))
            rowActions.append {}
        }
    }

    private func refreshTransport() {
        nowTitle?.setText(model.currentTrack?.title ?? "nothing playing")
        nowArtist?.setText(model.currentTrack.map { "\($0.artist) — \($0.album)" } ?? "—")
        deck_button_set_label(playButton, model.isPlaying ? "[ ‖ pause ]" : "[ ▶ play ]")
        positionLabel?.setText(model.position.clockString)
        durationLabel?.setText(model.duration.clockString)

        if let scrubber {
            updatingScrubber = true
            deck_scale_set_range(scrubber, 0, max(model.duration, 0.001))
            deck_scale_set_value(scrubber, model.position)
            updatingScrubber = false
        }

        if let art = nowArt, let track = model.currentTrack,
           let album = model.album(for: track.albumKey) {
            loadArtwork(album, into: art)
        }
    }

    private func refreshStatus() {
        let context: String
        switch model.route {
        case .albums: context = "albums (\(model.albums.count))"
        case .artists: context = "artists (\(model.artistNames.count))"
        case .songs: context = "songs (\(model.tracks.count))"
        case .album(let key): context = key.album
        case .queue: context = "queue (\(model.queue.count))"
        case .sync: context = "sync"
        case .settings: context = "settings"
        }
        statusContext?.setText(context)

        var message = model.statusMessage
        if let progress = model.scanProgress {
            message = "indexing \(progress.scanned)/\(progress.total)"
        }
        statusMessage?.setText(message)

        deviceLabel?.setText(
            model.selectedDevice.map { "device: \($0.volumeName)" } ?? "no device")
    }

    // MARK: - Artwork

    /// Resolves cover art off the main thread, then points the picture at the cached
    /// file. GtkPicture loads from a path, so the store's on-disk cache is the handoff.
    private func loadArtwork(_ album: Album, into picture: Widget) {
        Task.detached {
            guard await ArtworkStore.shared.artworkData(for: album) != nil else { return }
            let path = await ArtworkStore.shared.cachePath(for: album.key).path
            onMainThread {
                if FileManager.default.fileExists(atPath: path) {
                    deck_picture_set_file(picture, path)
                }
            }
        }
    }

    // MARK: - Navigation and keys

    private func go(_ route: AppModel.Route) {
        model.route = route
        model.selection = 0
        refresh()
    }

    private func chooseFolder() {
        guard let window else { return }
        guard let dialog = deck_file_chooser_new(window, "Choose a music folder") else { return }
        onSignalWithArgument(dialog, "response") { [weak self] _ in
            if let raw = deck_file_chooser_path(dialog) {
                let path = String(cString: raw)
                free(raw)
                self?.model.addLibraryRoot(path)
            }
            deck_dialog_destroy(dialog)
        }
        deck_window_present(dialog)
    }

    private func installKeyboard(on window: Widget) {
        onKeyPressed(window) { [weak self] keyval, _ in
            guard let self else { return false }
            switch keyval {
            case Key.space:
                self.model.togglePlayPause(); return true
            case Key.character("n"):
                self.model.next(); return true
            case Key.character("p"):
                self.model.previous(); return true
            case Key.character("s"):
                self.model.toggleShuffle(); return true
            case Key.character("r"):
                self.model.cycleRepeat(); return true
            case Key.character("t"):
                self.model.cycleTheme(); return true
            case Key.character("1"):
                self.go(.albums); return true
            case Key.character("2"):
                self.go(.artists); return true
            case Key.character("3"):
                self.go(.songs); return true
            case Key.character("4"):
                self.go(.queue); return true
            case Key.character("S"):
                self.go(.sync); return true
            case Key.character(","):
                self.go(.settings); return true
            case Key.character("R"):
                self.model.scanLibrary(); return true
            case Key.character("H"), Key.left:
                self.model.seekRelative(-10); return true
            case Key.character("L"), Key.right:
                self.model.seekRelative(10); return true
            case Key.escape:
                self.go(.albums); return true
            default:
                // Everything else, including typing in an entry, propagates normally.
                return false
            }
        }
    }
}
