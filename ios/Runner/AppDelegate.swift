import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the app's lifetime: the registrar keeps its scene delegate
  /// weakly on some Flutter versions, and the channel must outlive launch.
  private var shareIn: ShareInHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareInHandler") {
      let handler = ShareInHandler(messenger: registrar.messenger())
      registrar.addSceneDelegate(handler)
      shareIn = handler
    }
  }
}

/// Photos and PDFs opened in this app from another one — Files' "Open in",
/// "Copy to Liberated Bread" — handed to Dart to print, over the same
/// share_in channel Android's share intent uses.
///
/// The document types in Info.plist are what put the app in those menus;
/// with LSSupportsOpeningDocumentsInPlace off, iOS copies the file into the
/// app's Inbox first, so it is readable without a security scope (one is
/// still honoured if present).
final class ShareInHandler: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private static let maxBytes = 32 * 1024 * 1024

  private let channel: FlutterMethodChannel
  /// A file the app was launched with, held until Dart asks for it.
  private var pending: [String: Any]?

  static func register(with registrar: FlutterPluginRegistrar) {}

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "ca.pigscanfly.liberatedbread/share_in", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "initialShare":
        result(self?.pending)
        self?.pending = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// A cold launch with a file: hold it for Dart's first ask. The selector is
  /// spelled out because an optional ObjC requirement whose Swift name drifts
  /// is not an error — it is silently never called.
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let url = connectionOptions?.urlContexts.first?.url, let share = read(url) else {
      return false
    }
    pending = share
    return true
  }

  /// A file opened while the app runs: straight to Dart.
  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    guard let url = URLContexts.first?.url, let share = read(url) else { return false }
    channel.invokeMethod("shared", arguments: share)
    return true
  }

  private func read(_ url: URL) -> [String: Any]? {
    guard url.isFileURL else { return nil }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
      data.count <= ShareInHandler.maxBytes
    else { return nil }
    let ext = url.pathExtension.lowercased()
    let mime = ext == "pdf" ? "application/pdf" : "image/\(ext.isEmpty ? "*" : ext)"
    return [
      "bytes": FlutterStandardTypedData(bytes: data),
      "mime": mime,
      "name": url.lastPathComponent,
    ]
  }
}
