#pragma once
#include <optional>
namespace optishade::overlay {
// Empty ImGui frames must leave the game's original present waits untouched.
// Submitting an empty overlay command buffer adds queue work without producing
// pixels and can unnecessarily stall the game's presentation path.
constexpr bool ShouldSubmitPreparedOverlay(bool hasCommand,bool hasVertices) noexcept {
 return hasCommand&&hasVertices;
}

// A callback may consume only the exact preparation addressed to it. A second
// callback (or another window/queue) must not erase that transaction or revoke
// admission earned by its successful submission.
template<class Prepared,class Queue,class Swap>
std::optional<Prepared> TakePrepared(Prepared& pending,Queue queue,Swap swap,
 unsigned image,unsigned long long owner,bool valid) {
 if(!valid||!pending.owner||pending.owner!=owner||pending.queue!=queue||
    pending.swap!=swap||pending.image!=image||(!pending.command&&!pending.deferred))return {};
 auto result=pending;pending={};return result;
}
}
