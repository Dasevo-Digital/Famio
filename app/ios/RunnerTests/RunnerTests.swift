import CryptoKit
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
