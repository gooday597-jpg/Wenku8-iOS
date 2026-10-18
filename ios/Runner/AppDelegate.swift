import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "Wenku8BridgePlugin") {
      Wenku8BridgePlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "LocalToolsPlugin") {
      LocalToolsPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "SystemSpeechPlugin") {
      SystemSpeechPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "IOSDocumentsPlugin") {
      IOSDocumentsPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "IOSDevicePlugin") {
      IOSDevicePlugin.register(with: registrar)
    }
  }
}
