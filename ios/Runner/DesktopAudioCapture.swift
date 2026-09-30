import AVFoundation
import Flutter
import ReplayKit
import UIKit

private let kChannelName = "com.silsigan.app/desktop_audio"
private let kSystemAudioId = "system"
private let kSystemAudioLabel = "System / screen audio"
private let kExtensionBundleId = "com.silsigan.app.ScreenAudio"
private let kStartTimeout: TimeInterval = 90
/// A restart (resume, capture-failure recovery) stops and starts capture back
/// to back. Holding the stop this long lets the restart reuse the live
/// broadcast instead of ending it and putting the Start Broadcast sheet in
/// front of the user again. Android's playback capture uses the same grace.
private let kStopGrace: TimeInterval = 1.5
/// After the picker sheet closes, Start Broadcast's countdown and the
/// extension launch post `started` within a few seconds. A sheet that was
/// cancelled never does.
private let kPickerDismissGrace: TimeInterval = 8
/// No producer beat for this long: the extension is gone (the red pill was
/// tapped, or iOS killed it). One threshold for reuse and for
/// BROADCAST_ENDED, so the two can never disagree about the same broadcast.
private let kBroadcastStaleMs: UInt64 = 5000
/// A broadcast that comes up this soon after its start already failed (the
/// sheet was dismissed mid-countdown, or the timeout fired) has nobody
/// waiting for it. Its extension cleared our stop flag on start, so stop it
/// again rather than leave the red pill up until the orphan timeout.
private let kLateStartWindow: TimeInterval = 30

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
  private var pickerWatch: Timer?
  // watchPicker state. Instance properties, not captured locals: the Timer
  // block is @Sendable in recent SDKs, where mutating captured vars is
  // diagnosed.
  private var pickerSeen = false
  private var pickerClosedAt: CFTimeInterval?
  private var lastFailedStartAt: CFTimeInterval?
  /// When the device was last unlocked (or the app became active), in
  /// BroadcastIPC.nowMs(). Ends a paused broadcast's lock allowance.
  private var unlockedAtMs: UInt64?
  private var pendingStop: DispatchWorkItem?
  private var keepAlivePlayer: AVAudioPlayer?
  /// A recording session is reading the broadcast: startLoopback succeeded
  /// and no stopLoopback has come since.
  private var loopbackWanted = false
  private var startedObserver: UnsafeRawPointer?
  private var stoppedObserver: UnsafeRawPointer?
  private var sessionObservers: [NSObjectProtocol] = []

  // A broadcast already live at launch is left alone: it may be one the user
  // started from Control Center, and startLoopback will reuse it. A leftover
  // whose app died is ended by the extension once nobody reads it for a
  // minute, and a swipe-kill ends it at terminate (observeAudioSession).
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
    observeAudioSession()
    embedPicker(on: controller)
  }

  func shutdown() {
    startTimeout?.cancel()
    pickerWatch?.invalidate()
    pickerWatch = nil
    cancelPendingStop()
    if loopbackWanted {
      requestStopNow()
    }
    loopbackWanted = false
    stopKeepAlive()
    failPending(
      code: "CANCELLED",
      message: "Screen audio wasn’t started. Choose Silsigan in the broadcast picker and tap Start Broadcast."
    )
    removeObservers()
    for observer in sessionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    sessionObservers.removeAll()
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
      let args = call.arguments as? [String: Any]
      startLoopback(restart: (args?["restart"] as? Bool) ?? false, result: result)
    case "stopLoopback":
      scheduleStop()
      result(nil)
    case "readLoopback":
      readLoopback(result)
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

  /// `restart`: Dart is replacing a capture in the middle of a session
  /// (resume, capture recovery). Those never put the Start Broadcast sheet
  /// up: a broadcast that is gone by then is reported as BROADCAST_ENDED,
  /// the same as if the chunk loop had found it.
  private func startLoopback(restart: Bool, result: @escaping FlutterResult) {
    // A restart inside the stop grace lands here with the broadcast still
    // up: keep it instead of asking the user to start another.
    cancelPendingStop()
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
    // Reuse a live broadcast that isn't being stopped (a restart, or one the
    // user started from Control Center).
    if broadcastLive() {
      claimBroadcast()
      result(nil)
      return
    }
    if restart {
      loopbackWanted = false
      result(
        FlutterError(
          code: "BROADCAST_ENDED",
          message: "Screen broadcast ended",
          details: nil
        )
      )
      return
    }
    // Keep the app alive through the sheet and its countdown too: a
    // speaker-only user who switches away the moment it closes must not be
    // suspended before `started` arrives.
    startKeepAlive()
    ring.reset()
    ring.consumerBeat()
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
      guard let self, self.pendingStart != nil else { return }
      if self.tapPicker() {
        self.watchPicker()
      } else {
        self.failPending(
          code: "CANCELLED",
          message: "Screen audio couldn’t be started: the broadcast picker didn’t open."
        )
      }
    }
  }

  /// A session is reading the broadcast from here on.
  private func claimBroadcast() {
    loopbackWanted = true
    ring.consumerBeat()
    startKeepAlive()
  }

  /// Stop after a short grace, so a restart that follows straight away can
  /// cancel it and keep the broadcast (see kStopGrace).
  private func scheduleStop() {
    loopbackWanted = false
    cancelPendingStop()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingStop = nil
      self.requestStopNow()
    }
    pendingStop = work
    DispatchQueue.main.asyncAfter(deadline: .now() + kStopGrace, execute: work)
  }

  private func cancelPendingStop() {
    pendingStop?.cancel()
    pendingStop = nil
  }

  /// The mmap flag is seen by the extension's next 100 ms tick; the Darwin
  /// ping gets there sooner when it's awake.
  private func requestStopNow() {
    ring.setStopRequested(true)
    BroadcastIPC.post(BroadcastIPC.stopNotification)
    stopKeepAlive()
  }

  private func readLoopback(_ result: @escaping FlutterResult) {
    let data = ring.take()
    // The broadcast ended under a live session: the red status-bar pill was
    // tapped, or iOS killed the extension. Tell Dart once so it can end the
    // session (speaker only) or carry on with the mic (Both) instead of
    // "recording" silence.
    // The keep-alive stays up: a speaker-only session is about to wind down
    // (finalize, disconnect, save) and must not be suspended halfway. The
    // stopLoopback that follows ends it.
    if data.isEmpty, loopbackWanted, pendingStart == nil, !broadcastLive() {
      loopbackWanted = false
      result(
        FlutterError(
          code: "BROADCAST_ENDED",
          message: "Screen broadcast ended",
          details: nil
        )
      )
      return
    }
    result(FlutterStandardTypedData(bytes: data))
  }

  /// RPSystemBroadcastPickerView has no callbacks. Watch the sheet it
  /// presents: once it has been seen and gone for kPickerDismissGrace with
  /// no `started`, the user cancelled. Otherwise Dart would wait out the
  /// whole 90 s timeout with the record button stuck on "starting". If the
  /// sheet is never seen on this controller, the timeout still applies.
  private func watchPicker() {
    pickerWatch?.invalidate()
    pickerSeen = false
    pickerClosedAt = nil
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] tick in
      guard let self, self.pendingStart != nil else {
        tick.invalidate()
        return
      }
      self.checkPicker()
    }
    RunLoop.main.add(timer, forMode: .common)
    pickerWatch = timer
  }

  /// The one liveness question every path asks, with one threshold, so reuse
  /// and BROADCAST_ENDED can never disagree about the same broadcast.
  private func broadcastLive() -> Bool {
    ring.isBroadcastLive(staleAfterMs: kBroadcastStaleMs, unlockedAtMs: unlockedAtMs)
  }

  private func checkPicker() {
    // The broadcast is up even though `started` hasn't landed (the Darwin
    // ping can trail the sheet): that's a start, not a cancel.
    if broadcastLive() {
      onBroadcastStarted()
      return
    }
    if controller?.presentedViewController != nil {
      pickerSeen = true
      pickerClosedAt = nil
      return
    }
    guard pickerSeen else { return }
    let now = CACurrentMediaTime()
    guard let closed = pickerClosedAt else {
      pickerClosedAt = now
      return
    }
    if now - closed > kPickerDismissGrace {
      failPending(code: "CANCELLED", message: "Screen audio wasn’t started.")
    }
  }

  /// Speaker-only never opens the mic, so iOS would suspend us a few seconds
  /// after the user jumps to YouTube/TikTok — the isolate would stop polling
  /// the ring and Soniox would see silence. A muted looping player +
  /// `UIBackgroundModes: audio` keeps Flutter alive. mixWithOthers so we
  /// don't duck the video the user is trying to transcribe.
  private func startKeepAlive() {
    enableMixWithOthers()
    if keepAlivePlayer == nil {
      guard let player = try? AVAudioPlayer(data: Self.silentWav()) else { return }
      player.numberOfLoops = -1
      player.volume = 0.001
      keepAlivePlayer = player
    }
    keepAlivePlayer?.play()
  }

  private func stopKeepAlive() {
    keepAlivePlayer?.stop()
    keepAlivePlayer = nil
  }

  /// Only touches the category when mixWithOthers is missing. In Both mode
  /// MicCapture's session already has it, and rewriting the category under
  /// a live capture engine can change the hardware format and stop it.
  private func enableMixWithOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
      if !session.categoryOptions.contains(.mixWithOthers) {
        var options = session.categoryOptions
        options.insert(.mixWithOthers)
        let category: AVAudioSession.Category =
          session.category == .playAndRecord ? .playAndRecord : .playback
        try session.setCategory(category, mode: session.mode, options: options)
      }
      try session.setActive(true)
    } catch {}
  }

  /// A call or Siri stops the keep-alive player and it doesn't resume on its
  /// own; without it a speaker-only session is suspended in the background.
  /// Observers run on the posting thread and hop to main (see MicCapture).
  private func observeAudioSession() {
    let center = NotificationCenter.default
    sessionObservers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: nil
    ) { [weak self] note in
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      DispatchQueue.main.async {
        guard let self, let raw,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              self.keepAlivePlayer != nil
        else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        self.keepAlivePlayer?.play()
      }
    })
    sessionObservers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      DispatchQueue.main.async {
        // Every player is invalid after a media-services reset.
        guard let self, self.keepAlivePlayer != nil else { return }
        self.keepAlivePlayer = nil
        self.startKeepAlive()
      }
    })
    // Swipe-kill of a recording app (it runs in the background, so it gets
    // this): end the broadcast now instead of leaving the red pill up until
    // the extension's orphan timeout. Posted on main and handled inline,
    // since an async hop would never run during termination.
    sessionObservers.append(center.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      // pendingStop: a session that just stopped is still inside the stop
      // grace, and the broadcast is still up.
      guard let self,
            self.loopbackWanted || self.pendingStart != nil || self.pendingStop != nil
      else { return }
      self.ring.setStopRequested(true)
      BroadcastIPC.post(BroadcastIPC.stopNotification)
    })
    // Unlock (or the app coming forward, which implies it) ends a paused
    // broadcast's lock allowance: see AudioRingBuffer.isBroadcastLive. Both
    // are posted on main, so they're handled inline.
    for name in [
      UIApplication.protectedDataDidBecomeAvailableNotification,
      UIApplication.didBecomeActiveNotification,
    ] {
      sessionObservers.append(center.addObserver(
        forName: name,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.unlockedAtMs = BroadcastIPC.nowMs()
      })
    }
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

  /// Returns false when the picker's button couldn't be found.
  private func tapPicker() -> Bool {
    if picker == nil, let controller {
      embedPicker(on: controller)
    }
    guard let picker else { return false }
    // RPSystemBroadcastPickerView only presents from an internal UIButton.
    // Sending the control event is the supported-in-practice way to show
    // Start Broadcast from Flutter (Zoom / Meet / LiveKit do the same).
    for sub in picker.subviews {
      if let button = sub as? UIButton {
        button.sendActions(for: .touchUpInside)
        return true
      }
      for inner in sub.subviews {
        if let button = inner as? UIButton {
          button.sendActions(for: .touchUpInside)
          return true
        }
      }
    }
    return false
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
    pickerWatch?.invalidate()
    pickerWatch = nil
    guard let pending = pendingStart else { return }
    pendingStart = nil
    lastFailedStartAt = CACurrentMediaTime()
    if !loopbackWanted {
      stopKeepAlive()
    }
    pending(
      FlutterError(
        code: code,
        message: message,
        details: nil
      )
    )
  }

  private func onBroadcastStarted() {
    guard let pending = pendingStart else {
      // Its start already failed (sheet dismissed mid-countdown, or the
      // timeout): nobody is waiting, and the extension cleared our stop flag
      // as it came up. End it now. A broadcast started from Control Center
      // with no failed start behind it is left for the next startLoopback
      // to reuse (the extension ends it if nobody reads it for a minute).
      if !loopbackWanted, let failedAt = lastFailedStartAt,
         CACurrentMediaTime() - failedAt < kLateStartWindow {
        requestStopNow()
      }
      return
    }
    pendingStart = nil
    lastFailedStartAt = nil
    startTimeout?.cancel()
    startTimeout = nil
    pickerWatch?.invalidate()
    pickerWatch = nil
    claimBroadcast()
    pending(nil)
  }

  private func onBroadcastStopped() {
    // Deliberately doesn't fail a pending start: a `stopped` trailing from
    // the previous, still-dying broadcast would cancel the sheet that was
    // just shown. The picker watcher and the timeout cover real cancels, and
    // a session still reading hears about it from readLoopback.
    if !loopbackWanted, pendingStart == nil {
      stopKeepAlive()
    }
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
