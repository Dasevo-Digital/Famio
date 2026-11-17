import UIKit
import UniformTypeIdentifiers

/// "Teilen an Famio" in other apps' share sheet (Safari, a recipe app,
/// Photos, Files): leaves the link, the text and the files in the app group
/// (one folder per share, read by ShareInbox in the app) and opens Famio,
/// which shows its share sheet. If iOS does not let it open the app, Famio
/// takes the share the next time it comes to the front.
final class ShareViewController: UIViewController {
  /// As for "Teilen an Famio" on Android: at most 10 files, 100 MB.
  private static let maxFiles = 10
  private static let maxBytes: Int64 = 100 * 1024 * 1024

  private let label = UILabel()
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.text = Texts.opening
    label.numberOfLines = 0
    label.textAlignment = .center
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task { @MainActor in
      let kept = await keep()
      if kept && openApp() {
        extensionContext?.completeRequest(returningItems: nil)
      } else {
        show(kept ? Texts.kept : Texts.failed)
      }
    }
  }

  /// Writes the share into the app group; false if nothing could be kept.
  private func keep() async -> Bool {
    guard let inbox = Self.inbox else { return false }
    let manager = FileManager.default
    let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    let folder = inbox.appendingPathComponent(
      "\(stamp)-\(UUID().uuidString)", isDirectory: true)
    guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    else { return false }
    var texts: [String] = []
    var subject = ""
    var files: [[String: String]] = []
    var bytes: Int64 = 0
    func addText(_ text: String) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || texts.contains(where: { $0.contains(trimmed) }) { return }
      texts.removeAll(where: { trimmed.contains($0) })
      texts.append(trimmed)
    }
    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      if subject.isEmpty, let title = item.attributedTitle?.string {
        subject = title.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let content = item.attributedContentText?.string { addText(content) }
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
          let url = await loadURL(provider)
        {
          if !url.isFileURL {
            addText(url.absoluteString)
            continue
          }
        }
        if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
          provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
          let text = await loadText(provider)
        {
          addText(text)
          continue
        }
        guard files.count < Self.maxFiles,
          let type = [UTType.image, .pdf, .movie, .data, .item]
            .first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
          let file = await copyFile(
            provider, type: type, into: folder, index: files.count,
            left: Self.maxBytes - bytes)
        else { continue }
        bytes += file.size
        files.append(["file": file.stored, "name": file.name, "mime": file.mime])
      }
    }
    let text = texts.joined(separator: "\n")
    guard !text.isEmpty || !files.isEmpty,
      let json = try? JSONSerialization.data(withJSONObject: [
        "text": text, "subject": subject, "files": files,
      ]),
      (try? json.write(to: folder.appendingPathComponent("share.json"))) != nil
    else {
      try? manager.removeItem(at: folder)
      return false
    }
    return true
  }

  private func loadURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { done in
      provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
        done.resume(returning: item as? URL)
      }
    }
  }

  private func loadText(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { done in
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
        done.resume(returning: item as? String)
      }
    }
  }

  /// Copies the file of [provider] (valid only inside the callback) into
  /// [folder]; nil if it is larger than [left] bytes or unreadable.
  private func copyFile(
    _ provider: NSItemProvider, type: UTType, into folder: URL, index: Int, left: Int64
  ) async -> (stored: String, name: String, mime: String, size: Int64)? {
    await withCheckedContinuation { done in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return done.resume(returning: nil) }
        let size = Int64(
          (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max)
        guard size <= left else { return done.resume(returning: nil) }
        let name = url.lastPathComponent.isEmpty ? "datei" : url.lastPathComponent
        // A number in front: two files of the same name stay apart.
        let stored = "\(index)-\(name)".replacingOccurrences(of: "/", with: "_")
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
          ?? type.preferredMIMEType ?? "application/octet-stream"
        do {
          try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(stored))
          done.resume(returning: (stored, name, mime, size))
        } catch {
          done.resume(returning: nil)
        }
      }
    }
  }

  /// Opens Famio at its share sheet. Extensions may not call the app's
  /// `open`, so it is looked up at run time along the responder chain.
  private func openApp() -> Bool {
    guard let url = URL(string: "famio://share") else { return false }
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: selector) else { return false }
        typealias Open = @convention(c) (
          AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any],
          ((Bool) -> Void)?
        ) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: Open.self)
        open(application, selector, url, [:], nil)
        return true
      }
      responder = current.next
    }
    return false
  }

  private func show(_ text: String) {
    label.text = text
    let done = UIButton(type: .system)
    done.setTitle(Texts.done, for: .normal)
    done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    done.translatesAutoresizingMaskIntoConstraints = false
    done.addAction(
      UIAction { [weak self] _ in
        self?.extensionContext?.completeRequest(returningItems: nil)
      }, for: .touchUpInside)
    view.addSubview(done)
    NSLayoutConstraint.activate([
      done.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
      done.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  private static var inbox: URL? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "FamioAppGroup") as? String,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return container.appendingPathComponent("Share", isDirectory: true)
  }
}

/// The few words of the extension, in the app's languages.
private enum Texts {
  private static let language = Locale.preferredLanguages.first?.prefix(2) ?? "en"

  private static func pick(_ de: String, _ en: String, _ es: String) -> String {
    switch language {
    case "de": return de
    case "es": return es
    default: return en
    }
  }

  static var opening: String { pick("Famio öffnet …", "Opening Famio …", "Abriendo Famio …") }
  static var kept: String {
    pick(
      "Für Famio bereit. Öffne Famio, um es abzulegen.",
      "Ready for Famio. Open Famio to file it.",
      "Listo para Famio. Abre Famio para guardarlo.")
  }
  static var failed: String {
    pick(
      "Famio konnte das nicht übernehmen.",
      "Famio could not take this over.",
      "Famio no ha podido recogerlo.")
  }
  static var done: String { pick("Fertig", "Done", "Listo") }
}
