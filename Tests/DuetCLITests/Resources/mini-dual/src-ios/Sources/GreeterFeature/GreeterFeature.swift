// Mini-tree source: the Swift half of the dual-declared greeter feature.
// The declaration-parity check extracts these names and compares them with
// the Kotlin twin's — tests break one side and assert the named violation.

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
