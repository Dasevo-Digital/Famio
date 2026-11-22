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
      let (kept, omitted) = await keep()
      if kept && omitted.isEmpty && openApp() {
        extensionContext?.completeRequest(returningItems: nil)
      } else {
        let status = kept ? Texts.kept : Texts.failed
        let details = Omission.allCases.compactMap { reason in
          omitted[reason].map { Texts.omitted(reason, count: $0) }
        }
        show(([status] + details).joined(separator: "\n\n"))
      }
    }
  }

  /// Only publish completed shares. The app may read the inbox while a
  /// provider is still preparing a file for the extension.
  private func keep() async -> (Bool, [Omission: Int]) {
    guard let inbox = Self.inbox else { return (false, [:]) }
    let manager = FileManager.default
    let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    let name = "\(stamp)-\(UUID().uuidString)"
    let folder = inbox.appendingPathComponent(".staging", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    guard Self.prepare(inbox: inbox, folder: folder) else { return (false, [:]) }
    defer { try? manager.removeItem(at: folder) }
    var omitted: [Omission: Int] = [:]
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
        guard files.count < Self.maxFiles else {
          omitted[.count, default: 0] += 1
          continue
        }
        guard let type = [UTType.image, .pdf, .movie, .data, .item]
          .first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
        else {
          omitted[.unreadable, default: 0] += 1
          continue
        }
        switch await copyFile(
          provider, type: type, into: folder, index: files.count,
          left: Self.maxBytes - bytes)
        {
        case .success(let file):
          bytes += file.size
          files.append(["file": file.stored, "name": file.name, "mime": file.mime])
        case .failure(let reason):
          omitted[reason, default: 0] += 1
        }
      }
    }
    let text = texts.joined(separator: "\n")
    guard !text.isEmpty || !files.isEmpty else { return (false, omitted) }
    do {
      let json = try JSONSerialization.data(withJSONObject: [
        "text": text, "subject": subject, "files": files,
      ])
      try json.write(
        to: folder.appendingPathComponent("share.json"),
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      try manager.moveItem(at: folder, to: inbox.appendingPathComponent(name))
      return (true, omitted)
    } catch {
      return (false, omitted)
    }
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
  /// the staging folder, reporting why an attachment could not be kept.
  private func copyFile(
    _ provider: NSItemProvider, type: UTType, into folder: URL, index: Int, left: Int64
  ) async -> Result<(stored: String, name: String, mime: String, size: Int64), Omission> {
    await withCheckedContinuation { done in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url,
          let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true, let size = values.fileSize
        else { return done.resume(returning: .failure(.unreadable)) }
        guard Int64(size) <= left else { return done.resume(returning: .failure(.bytes)) }
        let name = url.lastPathComponent.isEmpty ? "datei" : url.lastPathComponent
        // A number in front: two files of the same name stay apart.
        let stored = "\(index)-\(name)".replacingOccurrences(of: "/", with: "_")
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
          ?? type.preferredMIMEType ?? "application/octet-stream"
        do {
          let copy = folder.appendingPathComponent(stored)
          try FileManager.default.copyItem(at: url, to: copy)
          try? FileManager.default.setAttributes(
            ShareViewController.protection, ofItemAtPath: copy.path)
          done.resume(returning: .success((stored, name, mime, Int64(size))))
        } catch {
          done.resume(returning: .failure(.unreadable))
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

  /// What waits for the app is readable only after the phone was unlocked
  /// once since it started (#580).
  static var protection: [FileAttributeKey: Any] {
    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
  }

  /// Makes [folder] in the inbox, with the inbox's own protection and the
  /// inbox kept out of the device's backup: shares wait there only until
  /// Famio takes them (#580).
  private static func prepare(inbox: URL, folder: URL) -> Bool {
    let manager = FileManager.default
    guard
      (try? manager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: protection)) != nil
    else { return false }
    // Made before this protection existed: new files in them get it too.
    for existing in [inbox, folder.deletingLastPathComponent()] {
      try? manager.setAttributes(protection, ofItemAtPath: existing.path)
    }
    var url = inbox
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
    return true
  }

  private static var inbox: URL? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "FamioAppGroup") as? String,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return container.appendingPathComponent("Share", isDirectory: true)
  }
}

private enum Omission: Error, CaseIterable {
  case count, bytes, unreadable
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
  static func omitted(_ reason: Omission, count: Int) -> String {
    switch reason {
    case .count:
      return pick(
        "Dateien über der Grenze von 10 Anhängen (\(count))",
        "Files beyond the limit of 10 attachments (\(count))",
        "Archivos que superan el límite de 10 adjuntos (\(count))")
    case .bytes:
      return pick(
        "Dateien über der Gesamtgrenze von 100 MB (\(count))",
        "Files beyond the total limit of 100 MB (\(count))",
        "Archivos que superan el límite total de 100 MB (\(count))")
    case .unreadable:
      return pick(
        "Dateien, die Famio nicht lesen konnte (\(count))",
        "Files Famio could not read (\(count))",
        "Archivos que Famio no pudo leer (\(count))")
    }
  }

  static var done: String { pick("Fertig", "Done", "Listo") }
}
