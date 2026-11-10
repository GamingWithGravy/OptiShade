// Generated from shared/neural-model-policy.json; do not edit.
#pragma once
#include <string_view>
namespace optishade::neural_policy {
struct Model { std::string_view id; std::string_view variant; std::string_view sha256; unsigned familyMask; };
inline constexpr unsigned FamilyBit(unsigned family) { return family == 20 ? 1u : family == 30 ? 2u : family == 40 ? 4u : family == 50 ? 8u : 0u; }
inline constexpr Model Models[] = {
    {"original-3108", "auto", "E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E", 8u},
    {"compat-3108", "auto", "E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A", 7u},
    {"compat-3109", "compat-3109", "CDFA6C1EC784867182164C7836F324F087B5C9F374D0C9FE46F54999FEABF3ED", 15u},
    {"official-3109", "official-3109", "2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F", 8u},
    {"v7-3109", "v7-3109", "30B6B599DBC593E5F9A8A0DDB2EDAC6F2F15AD0EAA967CD6BB0AB6BB224825C3", 11u},
};
inline constexpr bool AllowsFamily(const Model& model, unsigned family) { return (model.familyMask & FamilyBit(family)) != 0; }
inline const Model* FindByHash(std::string_view hash) {
    if (hash.size() != 64) return nullptr;
    for (const auto& model : Models) {
        bool match = true;
        for (unsigned i = 0; i < 64; ++i) {
            char ch = hash[i]; if (ch >= 'a' && ch <= 'f') ch = char(ch - 'a' + 'A');
            if (ch != model.sha256[i]) { match = false; break; }
        }
        if (match) return &model;
    }
    return nullptr;
}
} // namespace optishade::neural_policy
