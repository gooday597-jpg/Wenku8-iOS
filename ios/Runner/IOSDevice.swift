// iOS device services added 2026-10-18. GPL-3.0-or-later.
import Flutter
import UIKit
import Network
import Security

final class IOSDevicePlugin: NSObject, FlutterPlugin {
  private var channels: [FlutterMethodChannel] = []
  private var streams: [FlutterEventChannel] = []
  private let network = IOSNetworkEvents()
  private let status = IOSReaderEvents()
  private var brightness: CGFloat?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = IOSDevicePlugin()
    for name in ["cloud_sources", "custom_speech", "reader_controls", "network_status", "frame_rate"] {
      let channel = FlutterMethodChannel(name: "org.mewx.wenku8/" + name, binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [instance] call, result in instance.handle(name, call, result: result) }
      instance.channels.append(channel)
    }
    let network = FlutterEventChannel(name: "org.mewx.wenku8/network_events", binaryMessenger: registrar.messenger())
    network.setStreamHandler(instance.network)
    let status = FlutterEventChannel(name: "org.mewx.wenku8/reader_status", binaryMessenger: registrar.messenger())
    status.setStreamHandler(instance.status)
    instance.streams = [network, status]
  }

  private func handle(_ name: String, _ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch name {
    case "cloud_sources", "custom_speech":
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "wenku8.ios." + name, kSecAttrAccount as String: "configuration"]
      if call.method == "read" {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let code = SecItemCopyMatching(attributes as CFDictionary, &value)
        if code == errSecItemNotFound { result(nil) }
        else if code == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) { result(text) }
        else { result(FlutterError(code: "KEYCHAIN", message: "无法读取本机安全配置，请解锁手机后重试", details: nil)) }
      } else if call.method == "write" {
        if call.arguments == nil || call.arguments is NSNull {
          let code = SecItemDelete(query as CFDictionary)
          if code == errSecSuccess || code == errSecItemNotFound { result(nil) }
          else { result(FlutterError(code: "KEYCHAIN", message: "安全配置删除失败", details: nil)) }
        } else if let text = call.arguments as? String, text.utf8.count <= 100_000, let data = text.data(using: .utf8) {
          var code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
          if code == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            code = SecItemAdd(attributes as CFDictionary, nil)
          }
          if code == errSecSuccess { result(nil) }
          else { result(FlutterError(code: "KEYCHAIN", message: "安全配置保存失败，请重试", details: nil)) }
        } else { result(FlutterError(code: "INPUT", message: "配置数据无效或过大", details: nil)) }
      } else { result(FlutterMethodNotImplemented) }
    case "network_status":
      if call.method == "current" { result(network.current) }
      else { result(FlutterMethodNotImplemented) }
    case "reader_controls":
      if call.method == "brightness" { result(Double(UIScreen.main.brightness)) }
      else if call.method == "apply" {
        let args = call.arguments as? [String: Any] ?? [:]
        if let value = args["brightness"] as? Double, value.isFinite {
          if brightness == nil { brightness = UIScreen.main.brightness }
          UIScreen.main.brightness = CGFloat(max(0.03, min(1, value)))
        } else if let original = brightness {
          UIScreen.main.brightness = original
          brightness = nil
        }
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    case "frame_rate":
      // Flutter owns the display link. iOS chooses its rate from the device,
      // thermal and Low Power Mode policies; don't pretend to force that rate.
      if call.method == "info" || call.method == "set" {
        let maximum = UIScreen.main.maximumFramesPerSecond
        result(["target": 0, "current": maximum, "rates": [maximum]])
      } else { result(FlutterMethodNotImplemented) }
    default: result(FlutterMethodNotImplemented)
    }
  }
}

private final class IOSNetworkEvents: NSObject, FlutterStreamHandler {
  private var monitor: NWPathMonitor?
  private(set) var current = "unknown"
  private var sink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let value = path.status == .satisfied ? "online" : "offline"
      DispatchQueue.main.async {
        guard let self, self.monitor === monitor else { return }
        self.current = value
        self.sink?(value)
      }
    }
    monitor.start(queue: DispatchQueue(label: "wenku8.network"))
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    monitor?.cancel()
    monitor = nil
    sink = nil
    return nil
  }
}

private final class IOSReaderEvents: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    UIDevice.current.isBatteryMonitoringEnabled = true
    for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                 UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.emit() })
    }
    // A minute clock updates only the status line; it runs only while observed.
    observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.emit() })
    startClock()
    emit()
    return nil
  }
  private var timer: Timer?
  private func startClock() {
    let next = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 1) * 60)
    let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.emit() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func emit() {
    let device = UIDevice.current
    sink?(["time": Int64(Date().timeIntervalSince1970 * 1000),
           "battery": device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded()),
           "charging": device.batteryState == .charging || device.batteryState == .full])
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    timer?.invalidate()
    timer = nil
    sink = nil
    UIDevice.current.isBatteryMonitoringEnabled = false
    return nil
  }
}
