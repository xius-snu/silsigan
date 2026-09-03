import Foundation
import Darwin

/// Shared PCM ring in the App Group container. The ReplayKit broadcast
/// extension writes 24 kHz mono PCM16; the Runner reads it for readLoopback.
/// Also holds a tiny Darwin + UserDefaults handshake so startLoopback can
/// wait until the user taps Start Broadcast.
enum BroadcastIPC {
  static let groupId = "group.com.silsigan.app"
  static let ringFileName = "loopback.ring"
  static let startedNotification = "com.silsigan.app.broadcast.started" as CFString
  static let stoppedNotification = "com.silsigan.app.broadcast.stopped" as CFString
  static let stopNotification = "com.silsigan.app.broadcast.stop" as CFString
  static let defaultsSuite = groupId
  static let runningKey = "broadcastRunning"
  static let stopKey = "stopRequested"
  static let heartbeatKey = "broadcastHeartbeatMs"

  static let sampleRate = 24_000
  static let dataCapacity = sampleRate * 2 * 2 // 2s of PCM16 mono
  static let headerSize = 32
  static let magic: UInt32 = 0x53494C42 // "SILB"

  static func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)
  }

  static func defaults() -> UserDefaults? {
    UserDefaults(suiteName: defaultsSuite)
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

  static func isBroadcastRunning() -> Bool {
    guard let d = defaults() else { return false }
    if d.bool(forKey: stopKey) { return false }
    guard d.bool(forKey: runningKey) else { return false }
    let hb = d.double(forKey: heartbeatKey)
    if hb <= 0 { return true }
    return (Date().timeIntervalSince1970 * 1000) - hb < 2500
  }

  static func setRunning(_ running: Bool) {
    guard let d = defaults() else { return }
    d.set(running, forKey: runningKey)
    if running {
      d.set(false, forKey: stopKey)
      beat()
    }
    d.synchronize()
  }

  static func beat() {
    defaults()?.set(Date().timeIntervalSince1970 * 1000, forKey: heartbeatKey)
  }

  static func requestStop() {
    if let d = defaults() {
      d.set(true, forKey: stopKey)
      d.synchronize()
    }
    post(stopNotification)
  }

  static func clearStop() {
    guard let d = defaults() else { return }
    d.set(false, forKey: stopKey)
    d.synchronize()
  }

  static func stopRequested() -> Bool {
    defaults()?.bool(forKey: stopKey) ?? false
  }
}

final class AudioRingBuffer {
  private var map: UnsafeMutableRawPointer?
  private var mapSize = 0
  private var fd: Int32 = -1

  private var writePos: UnsafeMutablePointer<UInt32>? {
    guard let map else { return nil }
    return map.advanced(by: 4).assumingMemoryBound(to: UInt32.self)
  }

  private var readPos: UnsafeMutablePointer<UInt32>? {
    guard let map else { return nil }
    return map.advanced(by: 8).assumingMemoryBound(to: UInt32.self)
  }

  private var dataRegion: UnsafeMutableRawPointer? {
    guard let map else { return nil }
    return map.advanced(by: BroadcastIPC.headerSize)
  }

  /// Instant cross-process stop (offset 16). UserDefaults can lag 1–3s
  /// between the app and the ReplayKit extension.
  private var stopFlag: UnsafeMutablePointer<UInt32>? {
    guard let map else { return nil }
    return map.advanced(by: 16).assumingMemoryBound(to: UInt32.self)
  }

  deinit { close() }

  @discardableResult
  func open(create: Bool) -> Bool {
    if map != nil { return true }
    guard let dir = BroadcastIPC.containerURL() else { return false }
    let url = dir.appendingPathComponent(BroadcastIPC.ringFileName)
    let path = url.path
    let flags = create ? (O_RDWR | O_CREAT) : O_RDWR
    fd = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return false }
    let total = BroadcastIPC.headerSize + BroadcastIPC.dataCapacity
    if create {
      var stat = Darwin.stat()
      if fstat(fd, &stat) == 0, stat.st_size < total {
        _ = ftruncate(fd, off_t(total))
      }
    }
    map = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    if map == MAP_FAILED {
      map = nil
      Darwin.close(fd)
      fd = -1
      return false
    }
    mapSize = total
    if create {
      let magicPtr = map!.assumingMemoryBound(to: UInt32.self)
      if magicPtr.pointee != BroadcastIPC.magic {
        memset(map, 0, total)
        magicPtr.pointee = BroadcastIPC.magic
        map!.advanced(by: 12).assumingMemoryBound(to: UInt32.self).pointee =
          UInt32(BroadcastIPC.dataCapacity)
      }
    }
    return true
  }

  func reset() {
    writePos?.pointee = 0
    readPos?.pointee = 0
    stopFlag?.pointee = 0
  }

  func setStopRequested(_ value: Bool) {
    _ = open(create: true)
    stopFlag?.pointee = value ? 1 : 0
  }

  func isStopRequested() -> Bool {
    if map == nil { _ = open(create: false) }
    return (stopFlag?.pointee ?? 0) != 0
  }

  func write(_ data: Data) {
    guard open(create: true), let dataRegion, let writePos, let readPos else { return }
    if data.isEmpty { return }
    let cap = UInt32(BroadcastIPC.dataCapacity)
    data.withUnsafeBytes { raw in
      guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var remaining = data.count
      var offset = 0
      while remaining > 0 {
        var w = writePos.pointee
        var r = readPos.pointee
        let used = usedBytes(write: w, read: r, cap: cap)
        let free = cap - used - 1
        if free == 0 {
          r = (r + UInt32(min(remaining, Int(cap / 2)))) % cap
          readPos.pointee = r
          continue
        }
        let chunk = min(remaining, Int(free), Int(cap - (w % cap)))
        memcpy(dataRegion.advanced(by: Int(w % cap)), src.advanced(by: offset), chunk)
        w = (w + UInt32(chunk)) % cap
        writePos.pointee = w
        remaining -= chunk
        offset += chunk
      }
    }
  }

  func take() -> Data {
    guard open(create: false), let dataRegion, let writePos, let readPos else {
      return Data()
    }
    let cap = UInt32(BroadcastIPC.dataCapacity)
    let w = writePos.pointee
    var r = readPos.pointee
    let avail = Int(usedBytes(write: w, read: r, cap: cap))
    if avail <= 0 { return Data() }
    var out = Data(count: avail)
    out.withUnsafeMutableBytes { raw in
      guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var written = 0
      var remaining = avail
      while remaining > 0 {
        let chunk = min(remaining, Int(cap - (r % cap)))
        memcpy(dst.advanced(by: written), dataRegion.advanced(by: Int(r % cap)), chunk)
        r = (r + UInt32(chunk)) % cap
        written += chunk
        remaining -= chunk
      }
    }
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

  private func usedBytes(write: UInt32, read: UInt32, cap: UInt32) -> UInt32 {
    if write >= read { return write - read }
    return cap - read + write
  }
}
