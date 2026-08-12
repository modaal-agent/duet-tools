// Mini-tree source: the single-source ticker feature (commonMain).
package com.mini.ticker

data class TickerState(
    val ticks: Int,
)

sealed interface TickerAction {
    data object Tick : TickerAction
}

sealed interface TickerEffectPayload {
    data class Chime(val ticks: Int) : TickerEffectPayload
}
