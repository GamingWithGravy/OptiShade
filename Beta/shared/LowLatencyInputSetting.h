#pragma once

#include <cstdint>
#include <optional>

enum class LowLatencyInput : uint32_t
{
    None,
    Auto,
    AntiLag2,
    Reflex,
    XeLL,
    UeLowLatency,
    _
};

namespace optishade::config {

constexpr std::optional<LowLatencyInput> ParseLowLatencyInput(uint32_t value) noexcept
{
    if (value >= static_cast<uint32_t>(LowLatencyInput::_))
        return std::nullopt;
    return static_cast<LowLatencyInput>(value);
}

constexpr std::optional<uint32_t> SerializeLowLatencyInput(LowLatencyInput value) noexcept
{
    const auto raw = static_cast<uint32_t>(value);
    if (raw >= static_cast<uint32_t>(LowLatencyInput::_))
        return std::nullopt;
    return raw;
}

constexpr std::optional<uint32_t> SerializeLowLatencyInput(std::optional<LowLatencyInput> value) noexcept
{
    if (!value)
        return std::nullopt;
    return SerializeLowLatencyInput(*value);
}

} // namespace optishade::config
