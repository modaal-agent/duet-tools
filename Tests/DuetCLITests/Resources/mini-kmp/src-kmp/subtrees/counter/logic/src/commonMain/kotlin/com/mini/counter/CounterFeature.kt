// Mini-tree source: the single-source counter feature (commonMain — the ONE
// implementation; existence and subtree geometry are what the lint pins).
package com.mini.counter

data class CounterState(
    val count: Int,
)

sealed interface CounterAction {
    data object Increment : CounterAction
    data object Reset : CounterAction
}

sealed interface CounterEffectPayload {
    data class Announce(val count: Int) : CounterEffectPayload
}
