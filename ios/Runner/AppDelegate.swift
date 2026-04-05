import Flutter
import UIKit
import Security

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private let HARDWARE_ID_CHANNEL = "com.silsigan.app/hardware_id"
  private let KEYCHAIN_SERVICE = "com.silsigan.app.deviceid"
  private let KEYCHAIN_ACCOUNT = "device_uuid"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: HARDWARE_ID_CHANNEL,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        switch call.method {
        case "getKeychainId":
          result(self.getOrCreateKeychainId())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Reads a UUID from keychain. If none exists, generates one and stores it.
  /// Keychain items persist across app uninstall/reinstall on iOS, which lets
  /// us track a stable per-device identifier even if the user deletes the app.
  private func getOrCreateKeychainId() -> String? {
    if let existing = readKeychainId() {
      return existing
    }
    let newId = UUID().uuidString
    if writeKeychainId(newId) {
      return newId
    }
    return nil
  }

  private func readKeychainId() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: KEYCHAIN_SERVICE,
      kSecAttrAccount as String: KEYCHAIN_ACCOUNT,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let data = item as? Data,
          let str = String(data: data, encoding: .utf8),
          !str.isEmpty else {
      return nil
    }
    return str
  }

  private func writeKeychainId(_ id: String) -> Bool {
    guard let data = id.data(using: .utf8) else { return false }
    // Delete any stale entry first (idempotent)
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: KEYCHAIN_SERVICE,
      kSecAttrAccount as String: KEYCHAIN_ACCOUNT
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: KEYCHAIN_SERVICE,
      kSecAttrAccount as String: KEYCHAIN_ACCOUNT,
      kSecValueData as String: data,
      // Survives uninstall, does NOT sync via iCloud Keychain, bound to this device only
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    return status == errSecSuccess
  }
}
