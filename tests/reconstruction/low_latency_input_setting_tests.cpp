#include "../../Beta/shared/LowLatencyInputSetting.h"

#include <cstdio>

int main()
{
    for (uint32_t raw = 0; raw < static_cast<uint32_t>(LowLatencyInput::_); ++raw)
    {
        const auto parsed = optishade::config::ParseLowLatencyInput(raw);
        if (!parsed || static_cast<uint32_t>(*parsed) != raw)
        {
            std::fprintf(stderr, "valid low-latency input %u did not round-trip\n", raw);
            return 1;
        }
        const auto encoded = optishade::config::SerializeLowLatencyInput(*parsed);
        if (!encoded || *encoded != raw)
        {
            std::fprintf(stderr, "low-latency input %u was not serializable\n", raw);
            return 2;
        }
    }

    for (const auto invalid : {static_cast<uint32_t>(LowLatencyInput::_),
                               static_cast<uint32_t>(LowLatencyInput::_) + 1u,
                               UINT32_MAX})
    {
        if (optishade::config::ParseLowLatencyInput(invalid))
        {
            std::fprintf(stderr, "invalid low-latency input %u was accepted\n", invalid);
            return 3;
        }
    }

    if (optishade::config::SerializeLowLatencyInput(static_cast<LowLatencyInput>(LowLatencyInput::_)))
    {
        std::fprintf(stderr, "sentinel low-latency input was serialized\n");
        return 4;
    }

    if (optishade::config::SerializeLowLatencyInput(std::optional<LowLatencyInput>{}) ||
        optishade::config::SerializeLowLatencyInput(
            std::optional<LowLatencyInput>{static_cast<LowLatencyInput>(LowLatencyInput::_)}))
    {
        std::fprintf(stderr, "absent or invalid optional low-latency input was serialized\n");
        return 5;
    }

    std::puts("PASS: low-latency input values round-trip and invalid enum values fail closed");
    return 0;
}
