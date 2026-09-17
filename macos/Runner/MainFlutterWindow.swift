import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    RegisterDesktopAudioCapture(messenger: flutterViewController.engine.binaryMessenger)

    let push = FlutterMethodChannel(
      name: "com.silsigan.app/push",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    push.setMethodCallHandler { call, result in
      if call.method == "setBadge" {
        let n = call.arguments as? Int ?? 0
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
        NSApp.dockTile.display()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  deinit {
    UnregisterDesktopAudioCapture()
  }
}