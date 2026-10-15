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
    registerBackupExclusion(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // Encrypted chat keeps its sealed snapshot, the photo cache and unsent uploads in three folders of the app
  // support directory (lib/core/chat/chat_local_data.dart: chat_state, chat_blobs, chat_outbox). The keys that
  // open them are this-device-only, so a restored copy would be unreadable anyway, but ciphertext has no
  // business in an iCloud or iTunes backup. The Dart side calls this after it creates the folders (they are
  // created again after every sign-out wipe) and the flag is set on the folder, which covers what is inside.
  private func registerBackupExclusion(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.hiyall/backup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup", let paths = call.arguments as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      var failed: [String] = []
      for path in paths {
        // Only folders inside the app support directory are ever touched.
        guard let support = support, path.hasPrefix(support.path + "/") else {
          failed.append(path)
          continue
        }
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
        } catch {
          failed.append(path)
        }
      }
      result(failed.isEmpty ? nil : FlutterError(code: "BACKUP_EXCLUSION_FAILED", message: "\(failed.count) folder(s)", details: nil))
    }
  }
}
