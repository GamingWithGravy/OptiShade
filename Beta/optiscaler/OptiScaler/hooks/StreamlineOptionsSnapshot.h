#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sl_dlss_g.h>

namespace optishade::streamline_options {

// Streamline appends versioned fields to this ABI structure. Compute each
// supported prefix from the bundled header so older caller allocations are
// never read past their version's final member.
inline size_t DlssgOptionsPrefixBytes(size_t version) noexcept {
    sl::DLSSGOptions layout{};
    const auto* base = reinterpret_cast<const std::byte*>(&layout);
    const auto offset = [base](const auto& member) noexcept {
        return static_cast<size_t>(reinterpret_cast<const std::byte*>(&member) - base);
    };
    switch (version) {
    case 1: return offset(layout.bReserved15);
    case 2: return offset(layout.queueParallelismMode);
    case 3: return offset(layout.enableUserInterfaceRecomposition);
    case 4: return offset(layout.dynamicTargetFrameRate);
    case 5: return sizeof(layout);
    default: return 0;
    }
}

// Copies only a known, correctly typed prefix. `destination` must be a fresh
// current-version object. The next pointer is retained only for the immediate
// synchronous API call; callers must not cache this copy for later replay.
inline bool CopyKnownDlssgOptions(const sl::DLSSGOptions& source,
                                  sl::DLSSGOptions& destination) noexcept {
    if (source.structType != sl::DLSSGOptions::s_structType) return false;
    const auto bytes = DlssgOptionsPrefixBytes(source.structVersion);
    if (!bytes || bytes > sizeof(destination)) return false;
    std::memcpy(&destination, &source, bytes);
    destination.structVersion = source.structVersion;
    return true;
}

// Streamline's options default to one generated frame, and the DLSS-G plugin
// may forward this value to slSetData even while mode is Off. Some games send
// zero during startup; restore the API default for fixed/legacy modes so an
// inactive viewport does not feed invalid zero-frame data to the provider.
inline bool ApplyObservedMinimumFrameCount(sl::DLSSGOptions& options,
                                           uint32_t maximum) noexcept {
    if ((options.mode != sl::DLSSGMode::eOff && options.mode != sl::DLSSGMode::eAuto &&
         options.mode != sl::DLSSGMode::eOn) || options.numFramesToGenerate != 0)
        return false;

    // Off ignores the multiplier. For active modes, do not enable generation
    // unless this provider has reported that at least the 2x minimum is valid.
    if(options.mode!=sl::DLSSGMode::eOff&&maximum==0)return false;
    options.numFramesToGenerate = 1;
    return true;
}

// Some game menus send an initial OFF packet before exposing provider
// capabilities. When the provider is already known OFF, forwarding it is a
// redundant callback that can fault before the capability query completes.
inline bool IsRedundantDisabledOptions(const sl::DLSSGOptions& options,
                                      sl::DLSSGMode lastProviderMode) noexcept {
    return options.mode == sl::DLSSGMode::eOff && lastProviderMode == sl::DLSSGMode::eOff;
}

} // namespace optishade::streamline_options
