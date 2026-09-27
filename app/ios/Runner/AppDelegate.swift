import CoreLocation
import CryptoKit
import Flutter
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
/// background. iOS relaunches the app after it was closed when the phone
/// moves noticeably (significant location changes), and shows the blue
/// location indicator whenever the position is used in the background.
final class LocationReporter: NSObject, CLLocationManagerDelegate, URLSessionDelegate {
  static let shared = LocationReporter()

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard
  private var pending: [[String: Any]] = []
  private var paused = false
  private var lastFixUpload = Date.distantPast
  private var permissionWaiters: [FlutterResult] = []
  private lazy var session = URLSession(
    configuration: .ephemeral, delegate: self, delegateQueue: nil)

  private static let maxPending = 500

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 50
    manager.pausesLocationUpdatesAutomatically = false
    manager.activityType = .other
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  private func key(_ name: String) -> String { "famio.location.\(name)" }
  private var enabled: Bool { defaults.bool(forKey: key("enabled")) }

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
        for name in ["url", "token", "pin", "device"] {
          self.defaults.set(args[name] as? String, forKey: self.key(name))
        }
        self.defaults.set(Date().timeIntervalSince1970 * 1000, forKey: self.key("alertsSince"))
        self.defaults.set(true, forKey: self.key("enabled"))
        self.start()
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      case "token":
        result(self.defaults.string(forKey: self.key("token")))
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
    [
      "enabled": enabled,
      "permission": permission(),
      "precise": manager.accuracyAuthorization == .fullAccuracy,
      "locationOn": CLLocationManager.locationServicesEnabled(),
      "batteryUnrestricted": true,
      "notifications": true,
    ]
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

  private func start() {
    let status = manager.authorizationStatus
    guard status == .authorizedAlways || status == .authorizedWhenInUse else {
      report(state: "denied")
      return
    }
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    if !paused {
      manager.startUpdatingLocation()
    }
    if status == .authorizedAlways {
      // Wakes (and relaunches) the app on bigger moves, even when closed.
      manager.startMonitoringSignificantLocationChanges()
      manager.startMonitoringVisits()
    }
    report(state: state())
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    for name in ["enabled", "url", "token", "pin", "device", "alertsSince", "pausedUntil"] {
      defaults.removeObject(forKey: key(name))
    }
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
    for location in locations where location.horizontalAccuracy >= 0 {
      add(location)
    }
    // At most one upload a minute while moving.
    if Date().timeIntervalSince(lastFixUpload) >= 60 {
      report(state: state())
    }
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard enabled, !paused else { return }
    add(CLLocation(
      coordinate: visit.coordinate, altitude: 0,
      horizontalAccuracy: visit.horizontalAccuracy, verticalAccuracy: -1,
      timestamp: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate))
    report(state: state())
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Temporary (no fix yet); updates continue.
  }

  private func add(_ location: CLLocation) {
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
    guard let base = defaults.string(forKey: key("url")).flatMap(URL.init(string:)),
      let token = defaults.string(forKey: key("token")),
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
    if let device = defaults.string(forKey: key("device")) { body["device"] = device }
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
    session.dataTask(with: request) { [weak self] data, response, _ in
      DispatchQueue.main.async {
        defer { UIApplication.shared.endBackgroundTask(task) }
        guard let self, let http = response as? HTTPURLResponse else { return }
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

  private func apply(_ answer: [String: Any]) {
    let nowPaused = answer["paused"] as? Bool ?? false
    if nowPaused != paused {
      paused = nowPaused
      if paused {
        manager.stopUpdatingLocation()
      } else {
        manager.startUpdatingLocation()
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
    let pin = defaults.string(forKey: key("pin"))?
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
