import Foundation

/// One change of the account carrying new requests, with the reason the router had.
public struct RotationEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { at }
    public var at: Date
    public var from: String?
    public var to: String
    /// Text recorded by builds before `cause` existed, in whatever language was active then.
    public var reason: String?
    public var cause: RotationCause?
    /// Switched from this app (or the CLI's `switch`), not by rotation.
    public var manual: Bool

    public init(at: Date, from: String?, to: String, reason: String? = nil, cause: RotationCause? = nil, manual: Bool) {
        self.at = at; self.from = from; self.to = to; self.reason = reason; self.cause = cause; self.manual = manual
    }

    /// The reason in the active language; countdowns are as of the event, not of now.
    public var reasonText: String? {
        cause.map { Derived.rotationText($0, from: from ?? "—", to: to, now: at) } ?? reason
    }
}

/// The last fifty rotations, newest last.
public struct RotationLog: Codable, Sendable, Equatable {
    public static let capacity = 50
    public var events: [RotationEvent] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([RotationEvent].self, forKey: .events) ?? []
    }

    public mutating func append(_ e: RotationEvent) {
        events.append(e)
        if events.count > RotationLog.capacity { events.removeFirst(events.count - RotationLog.capacity) }
    }

    public var latest: [RotationEvent] { events.reversed() }

    /// Rotations in the last `window` seconds.
    public func count(within window: TimeInterval, now: Date = Date()) -> Int {
        events.filter { now.timeIntervalSince($0.at) <= window }.count
    }
}
