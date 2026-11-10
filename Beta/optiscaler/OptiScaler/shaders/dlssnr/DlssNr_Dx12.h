#pragma once

// The composition pass for Neural Rendering.
//
// Neural Rendering is two things, and only one of them is a shader. The model is an NGX feature --
// created and evaluated, not dispatched -- and that stays where it is. This is the other half: the
// pass that builds the tone-mapped proxy the model is shown, and then transfers the model's answer
// back onto the real frame.
//
// It is an ordinary compute shader with a constant struct, so it belongs here alongside RCAS and
// Output Scaling rather than owning a bespoke root signature and descriptor ring of its own.
//
// One shader, three modes, because all three read and write the same set of resources and differ
// only in what they compute:
//
//   Encode   the frame -> a tone-mapped proxy, plus an untouched copy to transfer against later
//   Down     the proxy -> a smaller proxy, when the model is asked to work below full resolution
//   Resolve  proxy + model answer + untouched copy -> the frame, edited

#include "DlssNr_Common.h"
#include "../../../../shared/NrGpuLifetime.h"

#include <d3d12.h>
#include <d3dx/d3dx12.h>
#include <shaders/Shader_Dx12.h>
#include <shaders/Shader_Dx12Utils.h>

// Bounded descriptor/constant capacity. Slots are leased to exact command
// recordings and reused only after retirement plus every consumer's completion.
// Capacity is not a delay or evidence of GPU completion.
//
// A slot returns only when the game resets the command list NR recorded into, and
// engines that keep lists for many frames (deeper FG queues) hold more slots at
// once. A fixed 48 ran dry in steady state and NR skipped every few frames, which
// alternates NR/no-NR frames on screen: flicker. Start at 48 and grow on demand.
#define DLSSNR_NUM_OF_HEAPS 48
#define DLSSNR_MAX_HEAPS 256
#define DLSSNR_HEAP_GROWTH 16

class DlssNr_Dx12 : public Shader_Dx12, public DlssNr_Common
{
  private:
    FrameDescriptorHeap _frameHeaps[DLSSNR_MAX_HEAPS];
    unsigned _heapCount=0;
    bool GrowHeaps(unsigned add);

    // One constant buffer per heap, not one for the class.
    //
    // The shared buffer in the base class suits a shader that dispatches once a frame. Three
    // dispatches recorded onto one command list all map and overwrite the same upload buffer before
    // any of them executes, so every pass ends up reading whichever constants were written last --
    // encode and downsample would run with the resolve's parameters.
    ID3D12Resource* _constantBuffers[DLSSNR_MAX_HEAPS] = {};

    optishade::nr_lifetime::Use _bindingLeases[DLSSNR_MAX_HEAPS];
    std::vector<Microsoft::WRL::ComPtr<IUnknown>> _bindingObjects[DLSSNR_MAX_HEAPS];
    std::array<unsigned,5> _reservedSlots{};
    unsigned _reservedCount=0, _reservedUsed=0;
    bool _batchActive=false;
    bool ReserveBatch(ID3D12GraphicsCommandList* cmd,unsigned count);
    void EndBatch();
    void CollectBindings();
    int AcquireBinding(ID3D12GraphicsCommandList* cmd);
    void RetainBinding(unsigned slot,std::initializer_list<IUnknown*> objects);

    // The shader reads five inputs and writes two, and not every mode uses all of them. Unused slots
    // still need a view bound -- an unbound descriptor is not an empty read, it is a read from
    // nothing -- so a stand-in is written into whichever are spare.
    static constexpr uint32_t kSrvCount = 5;
    static constexpr uint32_t kUavCount = 2;

    uint32_t _numThreadsX = 8;
    uint32_t _numThreadsY = 8;

    // ResidualAcrossRR v2: a second compute PSO built from dlssnr_residual.hlsl's own blob,
    // reusing this class's root signature and descriptor table. Kept separate so the main
    // dlssnr.hlsl blob is never regenerated (a current dxc produces materially different DXIL
    // from the committed one). Null on backends/builds where the residual shader is absent.
    ID3D12PipelineState* _residualPipelineState = nullptr;
    ID3D12PipelineState* _finishedColorPipelineState = nullptr;

  public:
    DlssNr_Dx12(std::string InName, ID3D12Device* InDevice);
    ~DlssNr_Dx12();
    ID3D12Device* Device() const { return _device; }

    // The pass. Resources in, and nothing read from anywhere the caller cannot see.
    //
    // This is the whole filter: it brings the model up if it is not already, builds the feature and
    // rebuilds it when the tuning or the resolution changes, evaluates it, and runs the compute passes
    // that show it the frame and bring its answer back. One call, like any other shader here.
    //
    // Sizes come from the resources. Everything the pass cannot work out for itself is in
    // DlssNrFrameInfo; everything the user chose stays in Config. colour and output may be the same
    // resource. timingQueue is the queue this list will be executed on, when the caller knows it.
    void Dispatch(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* colour, ID3D12Resource* depth,
                  ID3D12Resource* motion, ID3D12Resource* output, const DlssNrFrameInfo& frame,
                  ID3D12CommandQueue* timingQueue = nullptr);

    // Records one pass. Resources that a given mode does not read may be null; a stand-in is bound in
    // their place so every descriptor in the table is valid.
    // One compute pass. The public entry below drives three of these plus the model.
    bool DispatchPass(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                  ID3D12Resource* InSource, ID3D12Resource* InModel, ID3D12Resource* InOriginal,
                  ID3D12Resource* InMotion,
                  // Vestigial. Fed to the slot the removed edit accumulator read its history from;
                  // nothing reads it now and every caller passes nullptr. Kept only so the binding
                  // table keeps its shape -- not evidence that temporal accumulation exists.
                  ID3D12Resource* InPrevEdit, ID3D12Resource* OutTarget,
                  ID3D12Resource* OutKeep);

    // One compute pass of the ResidualAcrossRR v2 shader (dlssnr_residual.hlsl). Same descriptor
    // table shape as DispatchPass; binds _residualPipelineState instead of _pipelineState. t4/u1
    // are bound with a stand-in for parity. Returns false (no-op) if the residual PSO is absent.
    bool DispatchResidualPass(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                              ID3D12Resource* InSource, ID3D12Resource* InModel,
                              ID3D12Resource* InOriginal, ID3D12Resource* InMotion,
                              ID3D12Resource* OutTarget, bool finishedColor = false);
};

