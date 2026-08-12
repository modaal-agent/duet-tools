// Mini-tree source: the Kotlin half of the dual-declared greeter feature.
package com.mini.greeter

data class GreeterState(
    val message: String,
    val waveCount: Int,
)

sealed interface GreeterAction {
    data object Wave : GreeterAction
    data class Reset(val message: String) : GreeterAction
}

sealed interface GreeterEffectPayload {
    data class Log(val line: String) : GreeterEffectPayload
}
