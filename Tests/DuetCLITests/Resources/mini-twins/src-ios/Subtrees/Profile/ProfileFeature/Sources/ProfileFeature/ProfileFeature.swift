// Mini-tree source: a Swift-only feature (no Kotlin twin yet).

public struct ProfileState: Equatable {
  public var name: String
}

public enum ProfileAction: Equatable {
  case rename(String)
}

public enum ProfileEffectPayload: Equatable {
  case save(String)
}
