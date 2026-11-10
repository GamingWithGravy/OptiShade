#pragma once
#include <cstdint>

namespace optishade::nr_submission {
// A result of this call, not a cumulative dispatch counter or a new owner registry.
// The observation ticket is created by NrObservation's existing bounded tracker.
struct Result {
    uint64_t runtime=0,generation=0,view=0,frame=0,ticket=0;
    bool submitted=false,gpuCompleted=false,gpuUnsafe=false,modelFailed=false;
    bool evaluated=false,composed=false;

    Result Unsafe() const { auto result=*this;result.gpuUnsafe=true;return result; }
    bool SafeToCopy() const { return !gpuUnsafe && (!submitted || gpuCompleted); }
    bool ComposedImage() const {
        return runtime && generation && frame && ticket && submitted && gpuCompleted &&
               !gpuUnsafe && !modelFailed && evaluated && composed;
    }
    template<class Sample> void Observe(const Sample& sample) {
        // A late result from another runtime, generation, eye or frame cannot
        // certify the shared image belonging to this transport transaction.
        evaluated=composed=false;
        if(!sample || !ticket || sample->output.ticket!=ticket ||
           sample->owner.runtime!=runtime || sample->owner.generation!=generation ||
           sample->owner.view!=view || sample->frame!=frame)return;
        evaluated=sample->evaluated;
        composed=sample->evaluated && sample->composed;
    }
    const char* InferenceStatus() const {
        if(gpuUnsafe || (submitted && !gpuCompleted))return "NR GPU completion unverified";
        if(modelFailed)return "NR model unavailable or failed; no composed output verified";
        if(!ticket || !evaluated)return "No NR evaluation observed for this transaction";
        if(!gpuCompleted)return "NR evaluation recorded; GPU completion not observed";
        return composed ? "NR composition completed on GPU" : "NR evaluated; model composition hidden";
    }
};

struct TransportResult {
    Result inference;
    bool completed=false;
    bool ComposedImageCopied() const { return completed && inference.ComposedImage(); }
    const char* TransportStatus() const { return completed ? "Copy-back completed" : "Copy-back incomplete"; }
};

// Used by the actual D3D11 bridge and the callback tests. A provider may safely
// return the unmodified picture while it prepares or refuses a model. Only an
// exact, completed composition ticket is described as copied NR output.
template<class Bridge,class Inputs,class Evaluate>
TransportResult RunTransport(Bridge& bridge,Inputs inputs,Evaluate evaluate) {
    TransportResult result;
    result.completed=bridge.Run(inputs,[&](auto* queue,auto* colour,auto* depth,auto* motion){
        result.inference=evaluate(queue,colour,depth,motion);
        return result.inference.SafeToCopy();
    });
    return result;
}
}
