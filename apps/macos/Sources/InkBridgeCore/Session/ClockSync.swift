import Foundation

/// Estimates the offset between the device's monotonic clock and ours from
/// ping/pong exchanges, NTP-style.
///
/// For a ping sent at host time t0, answered at device time td, received
/// back at t3: offset ≈ td − (t0 + t3) / 2. The estimate is only as good as
/// the path is symmetric, so we keep the sample with the smallest round trip
/// among recent ones; it has the least room for asymmetric queueing.
///
/// With an offset, a sample's input-to-host latency is
/// `hostNow − (sample.t − offset)`.
public struct ClockSync: Sendable {
  public struct Sample: Sendable {
    public var rttNs: Int64
    public var offsetNs: Int64
  }

  private var samples: [Sample] = []
  private let window: Int

  public init(window: Int = 16) {
    self.window = window
  }

  public mutating func addPong(hostSentNs t0: Int64, deviceNs td: Int64, hostReceivedNs t3: Int64) {
    let rtt = t3 - t0
    guard rtt >= 0 else { return }
    samples.append(Sample(rttNs: rtt, offsetNs: td - (t0 + rtt / 2)))
    if samples.count > window { samples.removeFirst(samples.count - window) }
  }

  /// The most recent round-trip time.
  public var lastRTTNs: Int64? { samples.last?.rttNs }

  /// Offset from the lowest-RTT sample in the window.
  public var offsetNs: Int64? { samples.min(by: { $0.rttNs < $1.rttNs })?.offsetNs }

  /// Host-clock time at which a device timestamp occurred.
  public func hostTime(forDeviceNs t: Int64) -> Int64? {
    offsetNs.map { t - $0 }
  }

  public mutating func reset() { samples.removeAll() }
}

/// Monotonic host clock in nanoseconds.
public func monotonicNowNs() -> Int64 {
  Int64(clamping: DispatchTime.now().uptimeNanoseconds)
}

/// Rolling statistics for a latency series.
public struct LatencyStats: Sendable {
  private var values: [Double] = []
  private let capacity: Int

  public init(capacity: Int = 512) {
    self.capacity = capacity
  }

  public mutating func add(_ ms: Double) {
    values.append(ms)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }

  public var count: Int { values.count }
  public var mean: Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

  public func percentile(_ q: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let idx = Int((Double(sorted.count - 1) * q).rounded())
    return sorted[min(max(idx, 0), sorted.count - 1)]
  }

  public mutating func reset() { values.removeAll() }
}
