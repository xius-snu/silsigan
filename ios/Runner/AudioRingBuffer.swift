import Foundation
import Darwin

/// Shared state between the app and the ScreenAudio broadcast extension.
/// Everything the two sides must agree on right now (ring positions, stop,
/// running, liveness) lives in the mmap'd ring header, which both processes
/// see instantly. App Group UserDefaults lagged 1–3 s between them, long
/// enough to reuse a dead broadcast or present the picker over a live one.
/// Darwin notifications only nudge.
enum BroadcastIPC {
  static let groupId = "group.com.silsigan.app"
  static let ringFileName = "loopback.ring"
  static let startedNotification = "com.silsigan.app.broadcast.started" as CFString
  static let stoppedNotification = "com.silsigan.app.broadcast.stopped" as CFString
  static let stopNotification = "com.silsigan.app.broadcast.stop" as CFString

  static let sampleRate = 24_000
  /// 8 s of PCM16 mono. The app drains it every 100 ms; the slack covers a
  /// busy or briefly suspended reader.
  static let dataCapacity = sampleRate * 2 * 8
  static let headerSize = 64
  /// Bumped with the header layout, so a ring file written by an older build
  /// is re-initialised instead of misread.
  static let magic: UInt32 = 0x53494C43 // "SILC"

  static func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)
  }

  static func post(_ name: CFString) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name),
      nil,
      nil,
      true
    )
  }

  /// Monotonic milliseconds, the same clock in both processes. The wall
  /// clock could jump and trip a staleness check. A beat that is ahead of
  /// "now" can only come from before a reboot, so it counts as stale.
  static func nowMs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000
  }
}

/// PCM ring in the App Group container: the extension writes 24 kHz mono
/// PCM16, the app drains it through readLoopback.
///
/// Single producer, single consumer. The producer only ever moves writePos
/// and the consumer only readPos. When the ring is full, new audio is
/// dropped instead of the producer moving the reader's position under it.
/// Memory barriers order the sample bytes against the positions that
/// publish them, since the two processes run on different cores.
final class AudioRingBuffer {
  // Header layout (all little-endian, 8-byte fields 8-byte aligned).
  private static let writeOffset = 4 // UInt32
  private static let readOffset = 8 // UInt32
  private static let capacityOffset = 12 // UInt32
  private static let stopOffset = 16 // UInt32: app asked the extension to stop
  private static let runningOffset = 20 // UInt32: extension is broadcasting
  private static let producerBeatOffset = 24 // UInt64 ms: extension alive
  private static let consumerBeatOffset = 32 // UInt64 ms: app still reading
  private static let pausedOffset = 40 // UInt32: broadcast paused (locked)

  /// A paused broadcast (screen locked) may not beat while it waits. It
  /// still counts as live for this long, so a lock doesn't read as "the
  /// broadcast ended".
  private static let pausedLiveMs: UInt64 = 15 * 60 * 1000
  private static let resumeGraceMs: UInt64 = 10_000

  private var map: UnsafeMutableRawPointer?
  private var mapSize = 0
  private var fd: Int32 = -1

  deinit { close() }

  private func u32(_ offset: Int) -> UnsafeMutablePointer<UInt32>? {
    map?.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
  }

  private func u64(_ offset: Int) -> UnsafeMutablePointer<UInt64>? {
    map?.advanced(by: offset).assumingMemoryBound(to: UInt64.self)
  }

  private var dataRegion: UnsafeMutableRawPointer? {
    map?.advanced(by: BroadcastIPC.headerSize)
  }

  @discardableResult
  func open(create: Bool) -> Bool {
    if map != nil { return true }
    guard let dir = BroadcastIPC.containerURL() else { return false }
    let path = dir.appendingPathComponent(BroadcastIPC.ringFileName).path
    let flags = create ? (O_RDWR | O_CREAT) : O_RDWR
    fd = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return false }
    let total = BroadcastIPC.headerSize + BroadcastIPC.dataCapacity
    var info = Darwin.stat()
    if fstat(fd, &info) == 0, info.st_size < total {
      guard create else {
        Darwin.close(fd)
        fd = -1
        return false
      }
      _ = ftruncate(fd, off_t(total))
    }
    let mapped = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    if mapped == MAP_FAILED || mapped == nil {
      Darwin.close(fd)
      fd = -1
      return false
    }
    map = mapped
    mapSize = total
    if create, let magic = u32(0), magic.pointee != BroadcastIPC.magic {
      memset(mapped, 0, total)
      u32(Self.capacityOffset)?.pointee = UInt32(BroadcastIPC.dataCapacity)
      OSMemoryBarrier()
      magic.pointee = BroadcastIPC.magic
    }
    return true
  }

  /// Empties the ring and clears a stale stop request. Only called while
  /// nobody is broadcasting: the app before presenting the picker, the
  /// extension as its broadcast starts.
  func reset() {
    guard open(create: true) else { return }
    u32(Self.writeOffset)?.pointee = 0
    u32(Self.readOffset)?.pointee = 0
    u32(Self.stopOffset)?.pointee = 0
    u32(Self.pausedOffset)?.pointee = 0
    OSMemoryBarrier()
  }

  // MARK: - Control

  func setStopRequested(_ value: Bool) {
    guard open(create: true) else { return }
    u32(Self.stopOffset)?.pointee = value ? 1 : 0
    OSMemoryBarrier()
  }

  func isStopRequested() -> Bool {
    guard open(create: false) else { return false }
    OSMemoryBarrier()
    return (u32(Self.stopOffset)?.pointee ?? 0) != 0
  }

  /// Extension side: the broadcast came up or went down.
  func markRunning(_ running: Bool) {
    guard open(create: true) else { return }
    u64(Self.producerBeatOffset)?.pointee = BroadcastIPC.nowMs()
    u32(Self.runningOffset)?.pointee = running ? 1 : 0
    OSMemoryBarrier()
  }

  /// Extension side, on a timer: still alive, even while nothing plays and
  /// the screen doesn't change (no samples at all arrive then).
  func producerBeat() {
    guard open(create: true) else { return }
    u64(Self.producerBeatOffset)?.pointee = BroadcastIPC.nowMs()
  }

  /// Extension side: ReplayKit paused / resumed the broadcast (screen lock).
  func markPaused(_ paused: Bool) {
    guard open(create: true) else { return }
    u64(Self.producerBeatOffset)?.pointee = BroadcastIPC.nowMs()
    u32(Self.pausedOffset)?.pointee = paused ? 1 : 0
    OSMemoryBarrier()
  }

  /// App side: a broadcast is up, not being stopped, and its extension beat
  /// recently. A killed extension never clears `running`; the beat catches
  /// it. A paused broadcast gets the long pausedLiveMs allowance only while
  /// the device may still be locked. Once it has been unlocked
  /// (`unlockedAtMs`, from the app), ReplayKit resumes the broadcast, and an
  /// extension that died while paused must be noticed like any other.
  func isBroadcastLive(staleAfterMs: UInt64, unlockedAtMs: UInt64? = nil) -> Bool {
    guard open(create: false) else { return false }
    OSMemoryBarrier()
    guard (u32(Self.runningOffset)?.pointee ?? 0) == 1,
          (u32(Self.stopOffset)?.pointee ?? 0) == 0
    else { return false }
    let beat = u64(Self.producerBeatOffset)?.pointee ?? 0
    let now = BroadcastIPC.nowMs()
    guard beat <= now else { return false }
    let paused = (u32(Self.pausedOffset)?.pointee ?? 0) == 1
    guard paused else { return now - beat < staleAfterMs }
    if let unlocked = unlockedAtMs, unlocked > beat, unlocked <= now {
      // Give ReplayKit a moment to resume after the unlock.
      return now - unlocked < staleAfterMs + Self.resumeGraceMs
    }
    return now - beat < Self.pausedLiveMs
  }

  /// App side: a session is (about to be) reading.
  func consumerBeat() {
    guard open(create: true) else { return }
    u64(Self.consumerBeatOffset)?.pointee = BroadcastIPC.nowMs()
  }

  /// Extension side: how long since the app last read or claimed the ring.
  func msSinceConsumerBeat() -> UInt64 {
    guard open(create: false) else { return UInt64.max }
    let beat = u64(Self.consumerBeatOffset)?.pointee ?? 0
    let now = BroadcastIPC.nowMs()
    return beat > now ? UInt64.max : now - beat
  }

  // MARK: - Audio

  /// Producer. Whole 16-bit samples only; drops what doesn't fit.
  func write(_ data: Data) {
    guard !data.isEmpty, open(create: true), let region = dataRegion,
          let writePos = u32(Self.writeOffset), let readPos = u32(Self.readOffset)
    else { return }
    let cap = UInt32(BroadcastIPC.dataCapacity)
    OSMemoryBarrier()
    var w = writePos.pointee % cap
    let r = readPos.pointee % cap
    let used = w >= r ? w - r : cap - r + w
    let count = min(data.count, Int(cap - used - 1)) & ~1
    guard count > 0 else { return }
    data.withUnsafeBytes { raw in
      guard let src = raw.baseAddress else { return }
      var offset = 0
      while offset < count {
        let chunk = min(count - offset, Int(cap - w))
        memcpy(region.advanced(by: Int(w)), src.advanced(by: offset), chunk)
        w = (w + UInt32(chunk)) % cap
        offset += chunk
      }
    }
    // Publish the bytes before the position that covers them.
    OSMemoryBarrier()
    writePos.pointee = w
  }

  /// Consumer. Everything written since the last call.
  func take() -> Data {
    guard open(create: false), let region = dataRegion,
          let writePos = u32(Self.writeOffset), let readPos = u32(Self.readOffset)
    else { return Data() }
    consumerBeat()
    let cap = UInt32(BroadcastIPC.dataCapacity)
    let w = writePos.pointee % cap
    // Read the bytes only after the position that published them.
    OSMemoryBarrier()
    var r = readPos.pointee % cap
    let avail = Int(w >= r ? w - r : cap - r + w)
    if avail <= 0 { return Data() }
    var out = Data(count: avail)
    out.withUnsafeMutableBytes { raw in
      guard let dst = raw.baseAddress else { return }
      var copied = 0
      while copied < avail {
        let chunk = min(avail - copied, Int(cap - r))
        memcpy(dst.advanced(by: copied), region.advanced(by: Int(r)), chunk)
        r = (r + UInt32(chunk)) % cap
        copied += chunk
      }
    }
    // Finish reading before handing the space back to the producer.
    OSMemoryBarrier()
    readPos.pointee = r
    return out
  }

  func close() {
    if let map, mapSize > 0 {
      munmap(map, mapSize)
    }
    map = nil
    mapSize = 0
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }
}
