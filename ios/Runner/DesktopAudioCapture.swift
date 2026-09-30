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
      runOnMain {
        result(self.listDevices())
      }
    case "applyCaptureRoute":
      let args = call.arguments as? [String: Any]
      runOnMain {
        CaptureAudioRoute.apply(args: args)
        result(nil)
      }
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

  private func runOnMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread {
      body()
    } else {
      DispatchQueue.main.async(execute: body)
    }
  }

  private func listDevices() -> [String: Any] {
    [
      "inputs": CaptureAudioRoute.listInputs(),
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

/// Split audio route: capture stays on the selected (usually built-in) mic
/// while playback — TTS, history audio — can use Bluetooth A2DP headphones.
/// `allowBluetooth` (HFP) is only enabled when the user picks a BT mic;
/// otherwise HFP would steal input from the phone mic.
///
/// Also used by MicCapture (MicCapture.swift), which configures the session
/// through `prepareForCapture` right before it builds each engine.
enum CaptureAudioRoute {
  static var preferredMicId: String?
  static var hasApplied = false
  private static var wantHfp = false
  private static var applying = false
  private static var observer: NSObjectProtocol?
  private static var resetObserver: NSObjectProtocol?
  private static var pendingReapply: DispatchWorkItem?
  /// The options we last set and what the session reported right after.
  /// iOS may hand back a normalized set, and comparing against the raw
  /// request would then never match: every route change would rewrite the
  /// category again under a live capture engine.
  private static var lastOptions: (
    requested: AVAudioSession.CategoryOptions,
    reported: AVAudioSession.CategoryOptions
  )?
  /// The input we last pinned. An observer pass must not re-send a pin that
  /// iOS already holds, or declined.
  private static var pinnedInputId: String?
  /// Observer passes that had to change something, for the circuit breaker
  /// in `scheduleReapply`.
  private static var reapplyTimes: [CFTimeInterval] = []
  private static var reapplyPausedUntil: CFTimeInterval = 0

  /// A headset connect posts several route changes in a row; collapse the
  /// burst into one apply instead of reconfiguring the session per event.
  private static let reapplyDebounce: TimeInterval = 0.3

  static func apply(args: [String: Any]?) {
    updatePreferences(args)
    hasApplied = true
    // Explicit request from Dart (TTS init, Android parity): make sure the
    // session is active and capture sits on the wanted mic.
    _ = try? configure(activate: true, checkRoute: true)
    startObserving()
  }

  static func updatePreferences(_ args: [String: Any]?) {
    if let args {
      if args.keys.contains("micDeviceId") {
        let id = args["micDeviceId"] as? String
        preferredMicId = (id?.isEmpty ?? true) ? nil : id
      }
      if let bluetoothMic = args["bluetoothMic"] as? Bool {
        wantHfp = bluetoothMic && !(preferredMicId?.isEmpty ?? true)
      }
    }
    if preferredMicId == nil {
      wantHfp = false
    }
  }

  /// MicCapture calls this right before it builds an engine. It throws when
  /// the session can't be put into playAndRecord or activated, because an
  /// engine started on that session records nothing. `checkRoute` also
  /// re-pins when the live input isn't the wanted mic. In-place rebuilds
  /// skip that, since a re-pin can itself change the hardware format and
  /// post the next configuration change.
  static func prepareForCapture(checkRoute: Bool) throws {
    hasApplied = true
    try configure(activate: true, checkRoute: checkRoute)
    startObserving()
  }

  static func listInputs() -> [[String: Any]] {
    let session = AVAudioSession.sharedInstance()
    let prevCategory = session.category
    let prevMode = session.mode
    let prevOptions = session.categoryOptions
    // HFP must be allowed briefly or AirPods never appear as inputs.
    try? session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
    )
    try? session.setActive(true)
    let mapped = (session.availableInputs ?? []).map { port -> [String: Any] in
      [
        "id": port.uid,
        "label": port.portName,
        "isDefault": port.portType == .builtInMic,
        "isBluetooth": isBluetooth(port.portType),
      ]
    }
    if hasApplied {
      _ = try? configure(activate: true, checkRoute: true)
    } else {
      try? session.setCategory(prevCategory, mode: prevMode, options: prevOptions)
    }
    return mapped
  }

  /// Configure the session for "capture on the pinned mic, playback free to
  /// take A2DP headphones". Returns whether anything had to change.
  ///
  /// setCategory, setActive and setPreferredInput each post
  /// `routeChangeNotification` themselves. Answering those with another apply
  /// is a self-feeding loop that pegs the main thread — which starved the
  /// `applyCaptureRoute` channel reply and froze the record button mid-start
  /// with the mic already live (orange indicator on, button never flipping to
  /// Stop). So an observer pass (`activate: false`) MUST be a true no-op when
  /// the session already holds what we want: it then touches nothing, posts
  /// nothing, and the cycle terminates after one pass.
  ///
  /// Explicit calls also touch only what differs. Any call here can land
  /// under a live capture engine, and a needless setCategory or re-pin can
  /// change the hardware format underneath it, which stops the engine.
  @discardableResult
  private static func configure(activate: Bool, checkRoute: Bool) throws -> Bool {
    if applying { return false }
    applying = true
    defer { applying = false }

    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [
      .mixWithOthers,
      .defaultToSpeaker,
      .allowBluetoothA2DP,
      .allowAirPlay,
    ]
    if wantHfp {
      options.insert(.allowBluetooth)
    }

    var changed = false
    if !categoryMatches(session, options) {
      try session.setCategory(.playAndRecord, mode: .default, options: options)
      lastOptions = (options, session.categoryOptions)
      changed = true
    }
    if activate || changed {
      try session.setActive(true)
    }
    // Only after the category is playAndRecord: under .playback (which
    // audioplayers sets at launch) there are no inputs to choose from.
    if let wanted = desiredInput(session) {
      // An observer pass compares against our own preference, not
      // currentRoute: when iOS declines the preference the live route never
      // converges, and it would re-set it on every notification forever.
      let preferred = session.preferredInput?.uid == wanted.uid
        || (!checkRoute && pinnedInputId == wanted.uid)
      let live = session.currentRoute.inputs.contains { $0.uid == wanted.uid }
      if !preferred || (checkRoute && !live) {
        // Not fatal: capture still works on whatever input iOS chose.
        try? session.setPreferredInput(wanted)
        pinnedInputId = wanted.uid
        changed = true
      }
    }
    return changed
  }

  private static func categoryMatches(
    _ session: AVAudioSession,
    _ options: AVAudioSession.CategoryOptions
  ) -> Bool {
    guard session.category == .playAndRecord, session.mode == .default else {
      return false
    }
    let current = session.categoryOptions
    if current == options { return true }
    if let last = lastOptions, last.requested == options, last.reported == current {
      return true
    }
    return false
  }

  /// The port capture should open on: the user's pick while it is still
  /// present, else the phone's own mic, else any non-Bluetooth input.
  private static func desiredInput(
    _ session: AVAudioSession
  ) -> AVAudioSessionPortDescription? {
    let inputs = session.availableInputs ?? []
    guard !inputs.isEmpty else { return nil }
    if let id = preferredMicId, let match = inputs.first(where: { $0.uid == id }) {
      return match
    }
    return inputs.first(where: { $0.portType == .builtInMic })
      ?? inputs.first(where: { $0.portType == .headsetMic })
      ?? inputs.first(where: { !isBluetooth($0.portType) })
  }

  private static func isBluetooth(_ port: AVAudioSession.Port) -> Bool {
    port == .bluetoothHFP || port == .bluetoothLE
  }

  /// Observers run on the posting thread (`queue: nil`) and hop to main
  /// themselves: with `queue: .main` NotificationCenter would block the
  /// session's notification thread until main got to the block.
  private static func startObserving() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: nil
    ) { note in
      // `.override` is what our own defaultToSpeaker + setPreferredInput
      // produce, so it is never news worth re-applying for: answering it is
      // how this observer used to feed itself.
      if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
         raw == AVAudioSession.RouteChangeReason.override.rawValue {
        return
      }
      DispatchQueue.main.async {
        guard hasApplied else { return }
        scheduleReapply()
      }
    }
    // mediaserverd restarted and the session is back to its defaults, so
    // what we remember about it is stale.
    resetObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil,
      queue: nil
    ) { _ in
      DispatchQueue.main.async {
        lastOptions = nil
        pinnedInputId = nil
      }
    }
  }

  /// Re-apply off the notification callback: a burst coalesces into one pass,
  /// and a slow setActive never runs inside NotificationCenter's own dispatch.
  private static func scheduleReapply() {
    pendingReapply?.cancel()
    let work = DispatchWorkItem {
      pendingReapply = nil
      guard hasApplied else { return }
      let now = CACurrentMediaTime()
      guard now >= reapplyPausedUntil else { return }
      let changed = (try? configure(activate: false, checkRoute: false)) ?? false
      guard changed else { return }
      reapplyTimes = reapplyTimes.filter { now - $0 < 10 } + [now]
      if reapplyTimes.count >= 4 {
        // Still not settled after several passes: something keeps rewriting
        // the session, or iOS keeps reporting it back differently. Stop
        // answering for a while rather than reconfiguring under a live
        // capture engine several times a second.
        reapplyTimes.removeAll()
        reapplyPausedUntil = now + 30
      }
    }
    pendingReapply = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + reapplyDebounce,
      execute: work
    )
  }
}
