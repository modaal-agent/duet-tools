// Mini-tree source: the Kotlin twin of the greeter feature. The Android app
// runs this core.
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
