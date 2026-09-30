#pragma once
#include <algorithm>
#include <string>
#include <vector>

namespace optishade::preset {
enum class State : unsigned { Unknown, Applied, Partial, Failed, Edited, Disabled };
struct Technique { std::string effect, name; bool enabled = false; };
struct Result {
    State state = State::Unknown;
    unsigned requested = 0, applied = 0;
    std::vector<std::string> missing;
};
// Compiled identities, not filenames, decide whether a requested technique is
// active. No alias is inferred from a basename: CAS and ContrastAdaptiveSharpen
// are distinct until an exact source and uniform-compatible mapping is verified.
inline Result audit(const std::vector<std::string>& requested,
                    const std::vector<Technique>& compiled, bool compileOK,
                    bool truncated = false, bool enabled = true, bool dirty = false) {
    Result out;
    std::vector<std::string> seen;
    for (const auto& identity : requested) {
        if (identity.empty() || std::find(seen.begin(), seen.end(), identity) != seen.end()) continue;
        seen.push_back(identity); ++out.requested;
        const auto separator = identity.find('@');
        const auto name = identity.substr(0, separator);
        const auto effect = separator == std::string::npos ? std::string{} : identity.substr(separator + 1);
        unsigned matches = 0; bool active = false;
        if (!name.empty() && (separator == std::string::npos || !effect.empty()))
            for (const auto& technique : compiled)
                if (technique.name == name && (separator == std::string::npos || technique.effect == effect)) {
                    ++matches; active = technique.enabled;
                }
        if (matches == 1 && active) ++out.applied;
        else out.missing.push_back(identity + (matches > 1 ? " (ambiguous)" : matches == 1 ? " (not enabled)" : " (not compiled)"));
    }
    if (dirty) out.state = State::Edited;
    else if (!enabled) out.state = State::Disabled;
    else if (out.missing.empty() && compileOK && !truncated) out.state = State::Applied;
    else out.state = out.applied ? State::Partial : State::Failed;
    return out;
}
}
