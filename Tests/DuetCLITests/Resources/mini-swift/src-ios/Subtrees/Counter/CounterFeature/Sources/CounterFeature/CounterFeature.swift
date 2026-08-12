// Mini-tree source: the Swift-only counter feature (single implementation —
// no declaration parity applies; existence and geometry are what the lint pins).

public struct CounterState: Equatable {
  public var count: Int
}

public enum CounterAction: Equatable {
  case increment
  case reset
}

public enum CounterEffectPayload: Equatable {
  case announce(Int)
}
