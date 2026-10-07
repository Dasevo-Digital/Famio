import Cocoa
import FlutterMacOS
import PDFKit
import Vision

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Text in photos (appointments from a letter), on the device.
    let ocr = FlutterMethodChannel(
      name: "famio/ocr",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    ocr.setMethodCallHandler { call, result in
      if call.method == "pdfText",
        let path = (call.arguments as? [String: Any])?["path"] as? String
      {
        pdfText(at: path, result: result)
        return
      }
      guard call.method == "recognize",
        let path = (call.arguments as? [String: Any])?["path"] as? String,
        let image = NSImage(contentsOfFile: path),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        result(nil)
        return
      }
      recognizeText(in: cg, result: result)
    }

    super.awakeFromNib()
  }
}

/// Lines of text in [image], top to bottom (German first), via Vision.
func recognizeText(in image: CGImage, result: @escaping FlutterResult) {
  let request = VNRecognizeTextRequest { request, _ in
    let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
      .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
      .compactMap { $0.topCandidates(1).first?.string }
    DispatchQueue.main.async { result(lines.joined(separator: "\n")) }
  }
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["de-DE", "en-US"]
  request.usesLanguageCorrection = true
  DispatchQueue.global(qos: .userInitiated).async {
    do {
      try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
      DispatchQueue.main.async { result(nil) }
    }
  }
}

/// The text of a PDF: its text layer, or (scanned letters) the first pages
/// read with Vision.
func pdfText(at path: String, result: @escaping FlutterResult) {
  guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
    result(nil)
    return
  }
  if let text = document.string, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
    result(text)
    return
  }
  guard let page = document.page(at: 0) else {
    result(nil)
    return
  }
  let box = page.bounds(for: .mediaBox)
  let size = NSSize(width: box.width * 2, height: box.height * 2)
  let image = page.thumbnail(of: size, for: .mediaBox)
  guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    result(nil)
    return
  }
  recognizeText(in: cg, result: result)
}
