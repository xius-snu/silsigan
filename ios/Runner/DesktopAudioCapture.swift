import AVFoundation
import Flutter
import ReplayKit
import UIKit

private let kChannelName = "com.silsigan.app/desktop_audio"
private let kSystemAudioId = "system"
private let kSystemAudioLabel = "System / screen audio"
private let kExtensionBundleId = "com.silsigan.app.ScreenAudio"
private let kStartTimeout: TimeInterval = 90

private var gPlugin: DesktopAudioCapturePlugin?

func RegisterDesktopAudioCapture(messenger: FlutterBinaryMessenger, controller: UIViewController) {
  UnregisterDesktopAudioCapture()
  gPlugin = DesktopAudioCapturePlugin(messenger: messenger, controller: controller)
}

func UnregisterDesktopAudioCapture() {
  gPlugin?.shutdown()
  gPlugin = nil
}

/// MethodChannel `com.silsigan.app/desktop_audio` for iOS screen audio.
/// startLoopback presents RPSystemBroadcastPickerView (Start Broadcast +
/// red status bar). PCM is read from the App Group ring filled by the
/// ScreenAudio broadcast extension.
private final class DesktopAudioCapturePlugin: NSObject {
  private var channel: FlutterMethodChannel?
  private weak var controller: UIViewController?
  private let ring = AudioRingBuffer()
  private var picker: RPSystemBroadcastPickerView?
  private var pendingStart: FlutterResult?
  private var startTimeout: DispatchWorkItem?
  private var keepAlivePlayer: AVAudioPlayer?
  private var startedObserver: UnsafeRawPointer?
  private var stoppedObserver: UnsafeRawPointer?

  init(messenger: FlutterBinaryMessenger, controller: UIViewController) {
    super.init()
    self.controller = controller
    let channel = FlutterMethodChannel(name: kChannelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    _ = ring.open(create: true)
    installObservers()
    embedPicker(on: controller)
  }

  func shutdown() {
    startTimeout?.cancel()
    stopKeepAlive()
    failPending(
      code: "CANCELLED",
      message: "Screen audio wasn’t started. Choose Silsigan in the broadcast picker and tap Start Broadcast."
    )
    removeObservers()
    picker?.removeFromSuperview()
    picker = nil
    channel?.setMethodCallHandler(nil)
    channel = nil
    controller = nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listDevices":
      result(listDevices())
    case "startLoopback":
      startLoopback(result)
    case "stopLoopback":
      requestStopNow()
      result(nil)
    case "readLoopback":
      result(FlutterStandardTypedData(bytes: ring.take()))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func listDevices() -> [String: Any] {
    [
      "inputs": [],
      "outputs": [
        [
          "id": kSystemAudioId,
          "label": kSystemAudioLabel,
          "isDefault": true,
        ],
      ],
    ]
  }

  private func startLoopback(_ result: @escaping FlutterResult) {
    // Reuse only a live broadcast that is not already stopping. Clearing
    // the stop flag first would make a dying session look running.
    if BroadcastIPC.isBroadcastRunning()
      && !BroadcastIPC.stopRequested()
      && !ring.isStopRequested()
    {
      startKeepAlive()
      result(nil)
      return
    }
    enableMixWithOthers()
    BroadcastIPC.clearStop()
    ring.setStopRequested(false)
    if pendingStart != nil {
      result(
        FlutterError(
          code: "BUSY",
          message: "Broadcast picker is already showing",
          details: nil
        )
      )
      return
    }
    ring.reset()
    pendingStart = result
    let timeout = DispatchWorkItem { [weak self] in
      self?.failPending(
        code: "CANCELLED",
        message:
          "Screen audio wasn’t started. Choose Silsigan in the broadcast picker and tap Start Broadcast."
      )
    }
    startTimeout?.cancel()
    startTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + kStartTimeout, execute: timeout)
    DispatchQueue.main.async { [weak self] in
      self?.tapPicker()
    }
  }

  /// Stop the ReplayKit extension immediately. The 1.5s UserDefaults grace
  /// left the 화면방송 indicator up for ~3s after Stop; the mmap flag +
  /// Darwin ping is visible to the extension on the next sample / 100ms poll.
  private func requestStopNow() {
    ring.setStopRequested(true)
    BroadcastIPC.requestStop()
    stopKeepAlive()
  }

  /// Speaker-only never opens the mic, so iOS would suspend us a few seconds
  /// after the user jumps to YouTube/TikTok — the isolate would stop polling
  /// the ring and Soniox would see silence. A muted looping player +
  /// `UIBackgroundModes: audio` keeps Flutter alive. mixWithOthers so we
  /// don't duck the video the user is trying to transcribe.
  private func startKeepAlive() {
    enableMixWithOthers()
    if keepAlivePlayer != nil { return }
    guard let player = try? AVAudioPlayer(data: Self.silentWav()) else { return }
    player.numberOfLoops = -1
    player.volume = 0.001
    player.play()
    keepAlivePlayer = player
  }

  private func stopKeepAlive() {
    keepAlivePlayer?.stop()
    keepAlivePlayer = nil
  }

  private func enableMixWithOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
      var options = session.categoryOptions
      options.insert(.mixWithOthers)
      let category: AVAudioSession.Category =
        session.category == .playAndRecord ? .playAndRecord : .playback
      try session.setCategory(category, mode: session.mode, options: options)
      try session.setActive(true)
    } catch {}
  }

  private static func silentWav() -> Data {
    let pcmSize = 3200
    var data = Data()
    func appendLE<T: FixedWidthInteger>(_ value: T) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
    appendLE(UInt32(36 + pcmSize))
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
    appendLE(UInt32(16))
    appendLE(UInt16(1)) // PCM
    appendLE(UInt16(1)) // mono
    appendLE(UInt32(16_000))
    appendLE(UInt32(32_000))
    appendLE(UInt16(2))
    appendLE(UInt16(16))
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
    appendLE(UInt32(pcmSize))
    data.append(Data(count: pcmSize))
    return data
  }

  private func embedPicker(on controller: UIViewController) {
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    picker.preferredExtension = kExtensionBundleId
    picker.showsMicrophoneButton = false
    picker.isHidden = true
    picker.isUserInteractionEnabled = false
    controller.view.addSubview(picker)
    self.picker = picker
  }

  private func tapPicker() {
    if picker == nil, let controller {
      embedPicker(on: controller)
    }
    guard let picker else { return }
    // RPSystemBroadcastPickerView only presents from an internal UIButton.
    // Sending the control event is the supported-in-practice way to show
    // Start Broadcast from Flutter (Zoom / Meet / Saydi do the same).
    for sub in picker.subviews {
      if let button = sub as? UIButton {
        button.sendActions(for: .touchUpInside)
        return
      }
      for inner in sub.subviews {
        if let button = inner as? UIButton {
          button.sendActions(for: .touchUpInside)
          return
        }
      }
    }
  }

  private func installObservers() {
    let started: CFNotificationCallback = { _, observer, _, _, _ in
      guard let observer else { return }
      let me = Unmanaged<DesktopAudioCapturePlugin>.fromOpaque(observer).takeUnretainedValue()
      DispatchQueue.main.async {
        me.onBroadcastStarted()
      }
    }
    let stopped: CFNotificationCallback = { _, observer, _, _, _ in
      guard let observer else { return }
      let me = Unmanaged<DesktopAudioCapturePlugin>.fromOpaque(observer).takeUnretainedValue()
      DispatchQueue.main.async {
        me.onBroadcastStopped()
      }
    }
    let startedPtr = Unmanaged.passUnretained(self).toOpaque()
    startedObserver = UnsafeRawPointer(startedPtr)
    stoppedObserver = UnsafeRawPointer(startedPtr)
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      startedPtr,
      started,
      BroadcastIPC.startedNotification,
      nil,
      .deliverImmediately
    )
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      startedPtr,
      stopped,
      BroadcastIPC.stoppedNotification,
      nil,
      .deliverImmediately
    )
  }

  private func removeObservers() {
    let ptr = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      ptr
    )
    startedObserver = nil
    stoppedObserver = nil
  }

  private func failPending(code: String, message: String) {
    startTimeout?.cancel()
    startTimeout = nil
    guard let pending = pendingStart else { return }
    pendingStart = nil
    pending(
      FlutterError(
        code: code,
        message: message,
        details: nil
      )
    )
  }

  private func onBroadcastStarted() {
    startTimeout?.cancel()
    startTimeout = nil
    startKeepAlive()
    if let pending = pendingStart {
      pendingStart = nil
      pending(nil)
    }
  }

  private func onBroadcastStopped() {
    stopKeepAlive()
    failPending(
      code: "CANCELLED",
      message: "Broadcast ended before screen audio started"
    )
  }
}
