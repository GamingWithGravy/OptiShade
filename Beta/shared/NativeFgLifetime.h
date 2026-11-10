#pragma once
namespace optishade::taa {
// A returned Present, an NR fence, or logical retirement alone does not prove
// that the provider has finished consuming its tagged input resources.
inline bool InputsReleased(bool retagged,bool postPresentQueueComplete,bool providerInputsComplete){
    return !retagged||postPresentQueueComplete||providerInputsComplete;
}
}
