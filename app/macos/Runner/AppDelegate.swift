import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // "Öffnen mit Famio" in the Finder, also when Famio is not running yet.
  override func application(_ application: NSApplication, open urls: [URL]) {
    OpenedFiles.shared.receive(urls)
  }
}

/// Calendar files opened with Famio (`famio/open_file`): kept until Dart
/// takes them.
final class OpenedFiles {
  static let shared = OpenedFiles()

  private var channel: FlutterMethodChannel?
  private var pending: (name: String, data: Data)?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "famio/open_file", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "take" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let file = self?.pending
      self?.pending = nil
      result(
        file.map { ["name": $0.name, "bytes": FlutterStandardTypedData(bytes: $0.data)] })
    }
    self.channel = channel
  }

  func receive(_ urls: [URL]) {
    guard let url = urls.first(where: \.isFileURL),
      let data = try? Data(contentsOf: url),
      data.count <= 10 * 1024 * 1024
    else { return }
    pending = (url.lastPathComponent, data)
    channel?.invokeMethod("opened", arguments: nil)
  }
}
