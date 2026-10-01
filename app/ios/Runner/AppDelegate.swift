import CoreLocation
import CryptoKit
import Flutter
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Also when iOS relaunches the app in the background for a location
    // event: sharing continues without the Flutter UI.
    LocationReporter.shared.resumeIfEnabled()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    LocationReporter.shared.applicationDidBecomeActive()
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    LocationReporter.shared.applicationDidEnterBackground()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamioLocation") {
      LocationReporter.shared.register(with: registrar)
    }
  }
}

/// Shares the iPhone's position with the family while enabled, like the
/// Android LocationService: it reports to the Famio server itself with a
/// token that can only report positions, also while the app is in the
/// background. In the background it uses significant changes and visits,
/// plus a small "moving fence" around the last position: significant changes
/// only fire after roughly 500 m, the fence already after ~150 m. Continuous
/// location updates run only while the app is visible. iOS relaunches the
/// app after it was closed when the phone moves noticeably.
final class LocationReporter: NSObject, CLLocationManagerDelegate, URLSessionDelegate {
  static let shared = LocationReporter()

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard
  private var pending: [[String: Any]] = []
  private var paused = false
  private var requestingRegionFix = false
  /// Keeps the app running while a region-triggered fix is measured.
  private var fixTask: UIBackgroundTaskIdentifier = .invalid
  private var lastFixUpload = Date.distantPast
  private var permissionWaiters: [FlutterResult] = []
  private static let diagnosticKeys = [
    "lastFixAt", "lastSuccessfulUploadAt", "lastServerResponseAt",
    "lastServerStatus", "lastErrorAt", "lastError",
  ]
  private lazy var session = URLSession(
    configuration: .ephemeral, delegate: self, delegateQueue: nil)

  private static let maxPending = 500
  private static let regionPrefix = "famio.place."
  /// The moving fence around the last position (see the class comment).
  private static let hereRegionId = "famio.here"
  private static let hereRadius: CLLocationDistance = 150
  /// iOS monitors at most 20 regions per app; one is the moving fence.
  private static let maxRegions = 19
  private static let secretNames = ["url", "token", "pin", "device"]

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 50
    // iOS may pause foreground updates when they are not useful. Background
    // tracking is event based, so it never needs a permanently active GPS.
    manager.pausesLocationUpdatesAutomatically = true
    manager.activityType = .other
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  private func key(_ name: String) -> String { "famio.location.\(name)" }
  private var enabled: Bool { defaults.bool(forKey: key("enabled")) }

  /// Background location needs these values before Flutter is running. Keep
  /// them in the Keychain, available after the first unlock but never synced.
  private func secret(_ name: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "de.status403.famio.location",
      kSecAttrAccount as String: name,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, let value = String(data: data, encoding: .utf8) {
      return value
    }
    // One-time migration from versions that used UserDefaults.
    guard let legacy = defaults.string(forKey: key(name)) else { return nil }
    setSecret(legacy, name: name)
    defaults.removeObject(forKey: key(name))
    return legacy
  }

  private func setSecret(_ value: String?, name: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "de.status403.famio.location",
      kSecAttrAccount as String: name,
    ]
    guard let value else {
      SecItemDelete(query as CFDictionary)
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
      SecItemAdd((query.merging(attributes) { _, new in new }) as CFDictionary, nil)
    }
  }

  // MARK: - Flutter channel

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "famio/location", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status":
        result(self.status())
      case "requestPermission":
        self.requestPermission(background: args["background"] as? Bool ?? false, result: result)
      case "start":
        let wasEnabled = self.enabled
        for name in Self.secretNames {
          self.setSecret(args[name] as? String, name: name)
        }
        if !wasEnabled { self.clearDiagnostics() }
        self.defaults.set(Date().timeIntervalSince1970 * 1000, forKey: self.key("alertsSince"))
        self.defaults.set(true, forKey: self.key("enabled"))
        self.start()
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      case "token":
        result(self.secret("token"))
      case "setRegions":
        self.setRegions(args["regions"] as? [Any] ?? [])
        result(nil)
      case "openBatterySettings":
        result(nil)  // iOS has no per-app battery optimisation.
      case "openAppSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func permission() -> String {
    switch manager.authorizationStatus {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "foreground"
    default: return "none"
    }
  }

  private func status() -> [String: Any] {
    var result: [String: Any] = [
      "enabled": enabled,
      "permission": permission(),
      "precise": manager.accuracyAuthorization == .fullAccuracy,
      "locationOn": CLLocationManager.locationServicesEnabled(),
      "batteryUnrestricted": true,
      "notifications": true,
    ]
    for name in Self.diagnosticKeys {
      if let value = defaults.object(forKey: key(name)) { result[name] = value }
    }
    return result
  }

  private func clearDiagnostics() {
    for name in Self.diagnosticKeys { defaults.removeObject(forKey: key(name)) }
  }

  /// First "while using the app", then (a second request) "always", which
  /// sharing needs in the background.
  private func requestPermission(background: Bool, result: @escaping FlutterResult) {
    let before = manager.authorizationStatus
    if !background {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    if background ? before == .authorizedAlways || before == .denied : before != .notDetermined {
      result(status())  // Nothing to ask; iOS would not show a prompt.
      return
    }
    permissionWaiters.append(result)
    if background {
      manager.requestAlwaysAuthorization()
    } else {
      manager.requestWhenInUseAuthorization()
    }
    // iOS may decide without asking; do not wait forever.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      self?.answerPermissionWaiters()
    }
  }

  private func answerPermissionWaiters() {
    let waiters = permissionWaiters
    permissionWaiters = []
    let answer = status()
    for waiter in waiters { waiter(answer) }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    answerPermissionWaiters()
    if enabled {
      start()
    }
  }

  // MARK: - Positions

  /// Called at every app launch, also when iOS relaunches the app in the
  /// background for a location event.
  func resumeIfEnabled() {
    if enabled { start() }
  }

  /// Continuous GPS is useful while the map is open, but not while Famio is
  /// in the background. The latter is handled by significant changes/visits.
  func applicationDidBecomeActive() {
    if enabled { start() }
  }

  func applicationDidEnterBackground() {
    manager.stopUpdatingLocation()
    manager.showsBackgroundLocationIndicator = false
  }

  private func start() {
    let status = manager.authorizationStatus
    guard status == .authorizedAlways || status == .authorizedWhenInUse else {
      report(state: "denied")
      return
    }
    manager.allowsBackgroundLocationUpdates = status == .authorizedAlways
    // Do not merely hide a continuously-running GPS request. There is none
    // in the background; significant-change and visit monitoring wake us
    // only when iOS has an event to deliver.
    manager.showsBackgroundLocationIndicator = false
    if !paused && UIApplication.shared.applicationState == .active {
      manager.startUpdatingLocation()
    } else {
      manager.stopUpdatingLocation()
    }
    if status == .authorizedAlways {
      // Wakes (and relaunches) the app on bigger moves, even when closed.
      manager.startMonitoringSignificantLocationChanges()
      manager.startMonitoringVisits()
      restoreRegions()
      if let last = manager.location { moveHereFence(to: last) }
    } else {
      manager.stopMonitoringSignificantLocationChanges()
      manager.stopMonitoringVisits()
      stopHereFence()
    }
    report(state: state())
  }

  /// Registers the family places as low-power wake-up regions. A region
  /// event requests exactly one fix; the server still decides whether the
  /// member actually arrived or left based on its normal accuracy rules.
  private func setRegions(_ rawRegions: [Any]) {
    // Keep the configuration for an iOS relaunch caused by a region event.
    defaults.set(rawRegions, forKey: key("regions"))
    guard manager.authorizationStatus == .authorizedAlways else {
      stopFamioRegions()
      return
    }
    let regions = rawRegions.compactMap { raw -> CLCircularRegion? in
      guard let data = raw as? [String: Any],
        let id = data["id"] as? String,
        let lat = (data["lat"] as? NSNumber)?.doubleValue,
        let lon = (data["lon"] as? NSNumber)?.doubleValue,
        let radius = (data["radius"] as? NSNumber)?.doubleValue
      else { return nil }
      let safeRadius = min(max(100, radius), manager.maximumRegionMonitoringDistance)
      return CLCircularRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        radius: safeRadius,
        identifier: Self.regionPrefix + id)
    }
    let desired = Dictionary(uniqueKeysWithValues: regions.prefix(Self.maxRegions).map {
      ($0.identifier, $0)
    })
    var retainedIds = Set<String>()
    for current in manager.monitoredRegions where current.identifier.hasPrefix(Self.regionPrefix) {
      guard let wanted = desired[current.identifier],
        let existing = current as? CLCircularRegion,
        existing.center.latitude == wanted.center.latitude,
        existing.center.longitude == wanted.center.longitude,
        existing.radius == wanted.radius
      else {
        manager.stopMonitoring(for: current)
        continue
      }
      retainedIds.insert(current.identifier)
    }
    for region in desired.values where !retainedIds.contains(region.identifier) {
      manager.startMonitoring(for: region)
      manager.requestState(for: region)
    }
  }

  private func restoreRegions() {
    setRegions(defaults.array(forKey: key("regions")) ?? [])
  }

  /// Re-centres the moving fence on [location]. Leaving it wakes (or
  /// relaunches) the app for one new fix, which moves the fence again.
  private func moveHereFence(to location: CLLocation) {
    guard manager.authorizationStatus == .authorizedAlways,
      location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 250
    else { return }
    let current = manager.monitoredRegions
      .first { $0.identifier == Self.hereRegionId } as? CLCircularRegion
    if let current,
      CLLocation(latitude: current.center.latitude, longitude: current.center.longitude)
        .distance(from: location) < 30
    {
      return
    }
    let radius = min(Self.hereRadius, manager.maximumRegionMonitoringDistance)
    let region = CLCircularRegion(
      center: location.coordinate, radius: radius, identifier: Self.hereRegionId)
    region.notifyOnEntry = false
    region.notifyOnExit = true
    // Same identifier: replaces the previous fence.
    manager.startMonitoring(for: region)
  }

  private func stopHereFence() {
    for region in manager.monitoredRegions where region.identifier == Self.hereRegionId {
      manager.stopMonitoring(for: region)
    }
  }

  private func stopFamioRegions() {
    for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.regionPrefix) {
      manager.stopMonitoring(for: region)
    }
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    stopFamioRegions()
    stopHereFence()
    for name in ["enabled", "regions", "alertsSince", "pausedUntil"] + Self.diagnosticKeys {
      defaults.removeObject(forKey: key(name))
    }
    for name in Self.secretNames { setSecret(nil, name: name) }
    pending.removeAll()
  }

  private func state() -> String {
    let status = manager.authorizationStatus
    if status != .authorizedAlways && status != .authorizedWhenInUse { return "denied" }
    if !CLLocationManager.locationServicesEnabled() { return "off" }
    return "active"
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard enabled, !paused else { return }
    let regionFix = requestingRegionFix
    requestingRegionFix = false
    for location in locations where location.horizontalAccuracy >= 0 {
      add(location)
    }
    if let last = locations.last { moveHereFence(to: last) }
    // At most one upload a minute while moving; a woken app uploads at once,
    // iOS suspends it again within seconds.
    if regionFix || UIApplication.shared.applicationState != .active
      || Date().timeIntervalSince(lastFixUpload) >= 60
    {
      report(state: state())
    }
    endFixTask()
  }

  private func endFixTask() {
    guard fixTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(fixTask)
    fixTask = .invalid
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard enabled, !paused else { return }
    add(CLLocation(
      coordinate: visit.coordinate, altitude: 0,
      horizontalAccuracy: visit.horizontalAccuracy, verticalAccuracy: -1,
      timestamp: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate))
    if let last = manager.location { moveHereFence(to: last) }
    report(state: state())
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    requestRegionFix(for: region)
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    requestRegionFix(for: region)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didDetermineState state: CLRegionState,
    for region: CLRegion
  ) {
    if region.identifier == Self.hereRegionId {
      // Already outside the fence when it was (re)registered.
      if state == .outside { requestRegionFix(for: region) }
    } else if state == .inside {
      requestRegionFix(for: region)
    }
  }

  private func requestRegionFix(for region: CLRegion) {
    guard enabled, !paused, !requestingRegionFix,
      region.identifier.hasPrefix(Self.regionPrefix)
        || region.identifier == Self.hereRegionId
    else { return }
    // One temporary request is far cheaper than leaving standard updates on.
    requestingRegionFix = true
    if fixTask == .invalid {
      fixTask = UIApplication.shared.beginBackgroundTask(withName: "famio-fix") { [weak self] in
        self?.requestingRegionFix = false
        self?.endFixTask()
      }
    }
    manager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Temporary (no fix yet); updates continue.
    requestingRegionFix = false
    endFixTask()
  }

  private func add(_ location: CLLocation) {
    defaults.set(location.timestamp.timeIntervalSince1970 * 1000, forKey: key("lastFixAt"))
    let level = UIDevice.current.batteryLevel
    var fix: [String: Any] = [
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "acc": location.horizontalAccuracy,
      "at": Int64(location.timestamp.timeIntervalSince1970 * 1000),
    ]
    if level >= 0 { fix["battery"] = Int(level * 100) }
    pending.append(fix)
    if pending.count > Self.maxPending {
      pending.removeFirst(pending.count - Self.maxPending)
    }
  }

  // MARK: - Server

  private func report(state: String) {
    guard let base = secret("url").flatMap(URL.init(string:)),
      let token = secret("token"),
      let url = URL(string: "api/location/report", relativeTo: base)
    else { return }
    let batch = pending
    if !batch.isEmpty { lastFixUpload = Date() }
    var body: [String: Any] = [
      "fixes": batch,
      "state": state,
      "platform": "ios",
      "alertsSince": defaults.double(forKey: key("alertsSince")),
    ]
    if let device = secret("device") { body["device"] = device }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    // Finish the upload even if iOS puts the app to sleep meanwhile.
    var task: UIBackgroundTaskIdentifier = .invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "famio-location") {
      UIApplication.shared.endBackgroundTask(task)
    }
    session.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        defer { UIApplication.shared.endBackgroundTask(task) }
        guard let self else { return }
        guard let http = response as? HTTPURLResponse else {
          self.recordTransferError(error == nil ? "Keine Serverantwort" : "Netzwerkfehler")
          return
        }
        self.recordServerResponse(http.statusCode, uploadedPosition: !batch.isEmpty)
        if (200..<300).contains(http.statusCode) {
          self.pending.removeFirst(min(batch.count, self.pending.count))
          if let data, let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.apply(answer)
          }
        } else if http.statusCode == 401 {
          self.revoked()
        }
      }
    }.resume()
  }

  private func recordServerResponse(_ status: Int, uploadedPosition: Bool) {
    let now = Date().timeIntervalSince1970 * 1000
    defaults.set(now, forKey: key("lastServerResponseAt"))
    defaults.set("HTTP \(status)", forKey: key("lastServerStatus"))
    if uploadedPosition && (200..<300).contains(status) {
      defaults.set(now, forKey: key("lastSuccessfulUploadAt"))
    }
    defaults.removeObject(forKey: key("lastErrorAt"))
    defaults.removeObject(forKey: key("lastError"))
  }

  private func recordTransferError(_ message: String) {
    defaults.set(Date().timeIntervalSince1970 * 1000, forKey: key("lastErrorAt"))
    defaults.set(message, forKey: key("lastError"))
  }

  private func apply(_ answer: [String: Any]) {
    let nowPaused = answer["paused"] as? Bool ?? false
    if nowPaused != paused {
      paused = nowPaused
      if paused {
        manager.stopUpdatingLocation()
      } else {
        start()
      }
    }
    showAlerts(answer["alerts"] as? [[String: Any]] ?? [])
  }

  private func showAlerts(_ alerts: [[String: Any]]) {
    var newest = defaults.double(forKey: key("alertsSince"))
    for alert in alerts {
      guard let id = alert["id"] as? String, let text = alert["text"] as? String else { continue }
      newest = max(newest, (alert["at"] as? NSNumber)?.doubleValue ?? 0)
      let content = UNMutableNotificationContent()
      content.title = "Famio"
      content.body = text
      content.sound = .default
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "place-\(id)", content: content, trigger: nil))
    }
    defaults.set(newest, forKey: key("alertsSince"))
  }

  /// The device was signed out on the server: stop for good.
  private func revoked() {
    stop()
    let content = UNMutableNotificationContent()
    content.title = "Standortfreigabe beendet"
    content.body = "Das Gerät wurde abgemeldet. In Famio neu einschalten."
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "famio-location-revoked", content: content, trigger: nil))
  }

  /// Accepts exactly the server key confirmed in the app (SHA-256 of the
  /// certificate's SubjectPublicKeyInfo, which stays when the server renews
  /// its certificate), as the Android service and the Dart client do.
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let pin = secret("pin")?
      .replacingOccurrences(of: ":", with: "").uppercased()
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust, let pin, !pin.isEmpty
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    guard let spki = subjectPublicKeyInfo(SecCertificateCopyData(leaf) as Data) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    let digest = SHA256.hash(data: spki)
    let actual = digest.map { String(format: "%02X", $0) }.joined()
    if actual == pin {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

/// The DER SubjectPublicKeyInfo inside an X.509 certificate.
func subjectPublicKeyInfo(_ data: Data) -> Data? {
  let der = [UInt8](data)
  func read(_ offset: Int) -> (start: Int, end: Int)? {
    guard offset + 2 <= der.count else { return nil }
    var length = Int(der[offset + 1])
    var start = offset + 2
    if length & 0x80 != 0 {
      let count = length & 0x7f
      guard count > 0, count <= 4, start + count <= der.count else { return nil }
      length = 0
      for i in 0..<count { length = (length << 8) | Int(der[start + i]) }
      start += count
    }
    guard start + length <= der.count else { return nil }
    return (start, start + length)
  }
  guard let cert = read(0), let tbs = read(cert.start) else { return nil }
  var offset = tbs.start
  if der[offset] == 0xA0 {
    guard let version = read(offset) else { return nil }
    offset = version.end
  }
  for _ in 0..<5 {  // serial, algorithm, issuer, validity, subject
    guard let element = read(offset) else { return nil }
    offset = element.end
  }
  guard let spki = read(offset) else { return nil }
  return Data(der[offset..<spki.end])
}
