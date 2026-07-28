import CGtk4
import DeckCore
import Foundation

// `deck --scan` indexes the configured folders and prints a summary without opening a
// window, the same as the macOS build. Useful over SSH and for checking that a library
// is reachable before launching the UI.
if CommandLine.arguments.contains("--scan") {
    HeadlessScan.run()
}

if CommandLine.arguments.contains("--version") {
    print("deck \(DeckVersion.current)")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    deck \(DeckVersion.current) — music player and Rockbox sync

    usage: deck [options]

      --scan       index the configured library folders and print a summary
      --version    print the version
      --help       show this message

    requires: ffmpeg (tags, artwork, conversion), mpv (playback)
    config:   \(Config.configURL.path)
    """)
    exit(0)
}

Config.migrateLegacyDataIfNeeded()

let model = AppModel()
let window = Window(model: model)

guard let application = deck_application_new("com.riddickburke.deck") else {
    FileHandle.standardError.write(Data("failed to create GTK application\n".utf8))
    exit(1)
}

onSignal(application, "activate") {
    window.build(application: application)
}

// GTK parses argv itself; passing our own through keeps --display and friends working.
var arguments = CommandLine.arguments.map { strdup($0) }
defer { arguments.forEach { free($0) } }

let status = arguments.withUnsafeMutableBufferPointer { buffer in
    deck_application_run(application, Int32(buffer.count), buffer.baseAddress)
}

deck_object_unref(application)
exit(status)
