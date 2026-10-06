import Cocoa
import FlutterMacOS
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
