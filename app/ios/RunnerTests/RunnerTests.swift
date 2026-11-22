import CryptoKit
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers
import VisionKit
import XCTest

@testable import Runner

class LocationQueueTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func fix(_ secondsAgo: TimeInterval) -> [String: Any] {
    ["lat": 52.5, "lon": 13.4, "acc": 20.0,
     "at": Int64((now.timeIntervalSince1970 - secondsAgo) * 1000)]
  }

  private func times(_ queue: LocationQueue) -> [Int64] {
    queue.fixes.compactMap(LocationQueue.time)
  }

  func testOnlyOneUploadRunsAndAFollowUpIsRequested() {
    var queue = LocationQueue()
    queue.add(fix(30), now: now)
    let first = queue.beginUpload()
    XCTAssertEqual(first?.count, 1)
    queue.add(fix(20), now: now)
    XCTAssertNil(queue.beginUpload())
    XCTAssertTrue(queue.finishUpload(confirmed: first))
    XCTAssertEqual(times(queue), [LocationQueue.time(fix(20))!])
    XCTAssertEqual(queue.beginUpload()?.count, 1)
    XCTAssertFalse(queue.finishUpload(confirmed: nil))
  }

  func testAnswersInSwappedOrderKeepLaterFixes() {
    var queue = LocationQueue()
    queue.add(fix(50), now: now)
    queue.add(fix(40), now: now)
    let older = queue.fixes
    queue.add(fix(30), now: now)
    let newer = queue.fixes
    queue.add(fix(20), now: now)
    queue.add(fix(10), now: now)
    // The newer upload answers first, the older one afterwards.
    queue.confirm(newer)
    queue.confirm(older)
    XCTAssertEqual(times(queue), [fix(20), fix(10)].compactMap(LocationQueue.time))
  }

  func testFailedUploadKeepsEverything() {
    var queue = LocationQueue()
    queue.add(fix(20), now: now)
    _ = queue.beginUpload()
    queue.add(fix(10), now: now)
    _ = queue.finishUpload(confirmed: nil)
    XCTAssertEqual(queue.fixes.count, 2)
  }

  func testKeepsAtMost24HoursAnd500Fixes() {
    var queue = LocationQueue()
    queue.add(fix(25 * 60 * 60), now: now)
    XCTAssertTrue(queue.fixes.isEmpty)
    for i in 0..<520 { queue.add(fix(Double(600 - i)), now: now) }
    XCTAssertEqual(queue.fixes.count, LocationQueue.maxCount)
    XCTAssertEqual(queue.fixes.first.flatMap(LocationQueue.time), LocationQueue.time(fix(580)))
  }

  func testMergeSkipsDuplicatesAndSorts() {
    var queue = LocationQueue()
    queue.add(fix(10), now: now)
    queue.merge([fix(30), fix(10)], now: now)
    XCTAssertEqual(times(queue), [fix(30), fix(10)].compactMap(LocationQueue.time))
  }

  func testSealedFileNeedsTheKey() throws {
    let key = SymmetricKey(size: .bits256)
    let data = try XCTUnwrap(LocationQueue.seal([fix(10)], key: key))
    XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("52.5") ? $0 : nil })
    let restored = try XCTUnwrap(LocationQueue.open(data, key: key))
    XCTAssertEqual(restored.compactMap(LocationQueue.time), [LocationQueue.time(fix(10))!])
    XCTAssertNil(LocationQueue.open(data, key: SymmetricKey(size: .bits256)))
  }
}

class ShareInboxTests: XCTestCase {
  private let manager = FileManager.default

  func testKeepsInProgressFoldersAndReadsPublishedSharesInOrder() throws {
    let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: temp) }
    let inbox = temp.appendingPathComponent("Share")
    let unfinished = inbox.appendingPathComponent("00-legacy-in-progress")
    let staged = inbox.appendingPathComponent(".staging").appendingPathComponent("02")
    try manager.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try manifest("second", at: staged)
    try manifest("first", at: inbox.appendingPathComponent("01"))

    XCTAssertEqual(ShareInbox.take(from: inbox, temporary: temp)?["text"] as? String, "first")
    XCTAssertNil(ShareInbox.take(from: inbox, temporary: temp))
    XCTAssertTrue(manager.fileExists(atPath: unfinished.path))
    XCTAssertTrue(manager.fileExists(atPath: staged.path))

    try manager.moveItem(at: staged, to: inbox.appendingPathComponent("02"))
    XCTAssertEqual(ShareInbox.take(from: inbox, temporary: temp)?["text"] as? String, "second")
    XCTAssertNil(ShareInbox.take(from: inbox, temporary: temp))
  }

  func testExpiresAbandonedFoldersAndKeepsFilesTogetherOnCopyFailure() throws {
    let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: temp) }
    let inbox = temp.appendingPathComponent("Share")
    let abandoned = inbox.appendingPathComponent(".staging").appendingPathComponent("old")
    try manager.createDirectory(at: abandoned, withIntermediateDirectories: true)
    let old = Date(timeIntervalSinceNow: -25 * 60 * 60)
    try manager.setAttributes([.creationDate: old], ofItemAtPath: abandoned.path)
    let share = inbox.appendingPathComponent("01")
    try manifest("two files", at: share, files: ["one.txt", "two.txt"])
    try Data([1]).write(to: share.appendingPathComponent("one.txt"))

    XCTAssertNil(ShareInbox.take(from: inbox, temporary: temp))
    XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
    XCTAssertTrue(manager.fileExists(atPath: share.appendingPathComponent("one.txt").path))
    try Data([2]).write(to: share.appendingPathComponent("two.txt"))

    let result = try XCTUnwrap(ShareInbox.take(from: inbox, temporary: temp))
    let files = try XCTUnwrap(result["files"] as? [[String: String]])
    XCTAssertEqual(files.map { $0["name"] }, ["one.txt", "two.txt"])
    let second = try XCTUnwrap(files.last?["path"])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second)), Data([2]))
    XCTAssertFalse(manager.fileExists(atPath: share.path))
  }

  func testKeepsTheInboxOutOfBackups() throws {
    let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: temp) }
    let inbox = temp.appendingPathComponent("Share")
    try manifest("text", at: inbox.appendingPathComponent("01"))

    XCTAssertEqual(ShareInbox.take(from: inbox, temporary: temp)?["text"] as? String, "text")
    let values = try inbox.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  private func manifest(_ text: String, at folder: URL, files: [String] = []) throws {
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let payload: [String: Any] = ["text": text, "files": files.map { ["file": $0] }]
    let json = try JSONSerialization.data(withJSONObject: payload)
    try json.write(to: folder.appendingPathComponent("share.json"))
  }
}

class OpenedFilesTests: XCTestCase {
  private let manager = FileManager.default

  func testCalendarFilesAreMeasuredBeforeReading() throws {
    let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temp) }
    let small = temp.appendingPathComponent("small.ics")
    try Data(repeating: 65, count: 64).write(to: small)
    let large = temp.appendingPathComponent("large.ics")
    try Data(repeating: 65, count: 65).write(to: large)

    XCTAssertEqual(OpenedFiles.calendarFile(at: small, limit: 64)?.count, 64)
    XCTAssertNil(OpenedFiles.calendarFile(at: large, limit: 64))
    XCTAssertNil(OpenedFiles.calendarFile(at: temp, limit: 64))
    XCTAssertNil(OpenedFiles.calendarFile(at: temp.appendingPathComponent("gone.ics")))
  }
}

class PrivacyCoverTests: XCTestCase {
  func testPickersStayWhenFamioComesBackLocked() {
    XCTAssertTrue(PrivacyCover.isPicker(UIImagePickerController()))
    // Simulators without a camera refuse to create the document camera.
    if VNDocumentCameraViewController.isSupported {
      XCTAssertTrue(PrivacyCover.isPicker(VNDocumentCameraViewController()))
    }
    XCTAssertTrue(PrivacyCover.isPicker(PHPickerViewController(configuration: .init())))
    XCTAssertTrue(
      PrivacyCover.isPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])))
    // A document's preview and the share sheet show Famio's data: they close.
    XCTAssertFalse(PrivacyCover.isPicker(QLPreviewController()))
    XCTAssertFalse(
      PrivacyCover.isPicker(UIActivityViewController(activityItems: [], applicationActivities: nil)))
  }
}
