// Mini-tree source: the Swift twin of the greeter feature. The iPhone app runs
// this core; the declaration-parity check compares its names with the Kotlin
// twin's.

public struct GreeterState: Equatable {
  public var message: String
  public var waveCount: Int
}

public enum GreeterAction: Equatable {
  case wave
  case reset(String)
}

public enum GreeterEffectPayload: Equatable {
  case log(String)
}
