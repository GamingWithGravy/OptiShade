#include "NeuralModelPolicy.generated.h"
#include <cctype>
#include <iostream>
#include <stdexcept>
#include <string>

int main() {
    using namespace optishade::neural_policy;
    unsigned checks = 0;
    auto check = [&](bool result) { ++checks; if (!result) throw std::runtime_error("Neural model identity/admission failure"); };
    check(FindByHash("") == nullptr);
    check(FindByHash(std::string(64, '0')) == nullptr);
    check(FindByHash(std::string(64, 'G')) == nullptr);
    for (const auto& model : Models) {
        check(FindByHash(model.sha256) == &model);
        auto lower = std::string(model.sha256);
        for (auto& ch : lower) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        check(FindByHash(lower) == &model);
        check(FindByHash(lower + "0") == nullptr);
        check(FindByHash(lower.substr(1)) == nullptr);
        check(!AllowsFamily(model, 0) && !AllowsFamily(model, 60));
        if (model.id == "original-3108") {
            check(AllowsFamily(model, 50) && !AllowsFamily(model, 20) && !AllowsFamily(model, 30) && !AllowsFamily(model, 40));
        } else if (model.id == "official-3109") {
            check(AllowsFamily(model, 50) && !AllowsFamily(model, 20) && !AllowsFamily(model, 30) && !AllowsFamily(model, 40));
        } else if (model.id == "v7-3109") {
            check(AllowsFamily(model, 20) && AllowsFamily(model, 30) && AllowsFamily(model, 50) && !AllowsFamily(model, 40));
        } else if (model.id == "compat-3108") {
            check(AllowsFamily(model, 20) && AllowsFamily(model, 30) && AllowsFamily(model, 40) && !AllowsFamily(model, 50));
        } else if (model.id == "compat-3109") {
            check(AllowsFamily(model, 20) && AllowsFamily(model, 30) && AllowsFamily(model, 40) && AllowsFamily(model, 50));
        } else { check(false); }
    }
    std::cout << checks << " generated neural model identity/admission checks passed; no inference was run.\n";
}
