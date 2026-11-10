// Writes out the frames this pass is arguing about, so questions get settled by measurement.
//
// Every comparison so far has been two separate video captures: different camera paths, different
// exposure, and H.264 in between throwing away exactly the high-frequency temporal detail the argument
// is about. Normalising for all that leaves conclusions that need hedging.
//
// This captures the same frames twice instead. The pass already holds the frame as the upscaler produced
// it and the frame after the model's edit, so both are written for the same run of consecutive frames --
// a perfect control, with nothing varying but the thing under test. Flicker in one against flicker in
// the other is then a direct answer rather than an inference.
//
// Raw, because a codec is the confound. A manifest alongside says how to read them.

#pragma once

#include <windows.h>
#include <d3d12.h>
#include "../../../shared/NrGpuLifetime.h"

#include <cstdio>
#include <atomic>
#include <filesystem>
#include <string>
#include <vector>

namespace capture
{
// Bounded on purpose: this writes hundreds of megabytes and must not be able to fill a drive. Each run
// overwrites the last.
constexpr unsigned int kMaxFrames = 8;
// Bound diagnostic readback memory independently from frame count. At 4K,
// eight RGBA16F before/after pairs can exceed 1 GiB; reject the batch before
// creating any readback resources when its exact footprints exceed this cap.
constexpr uint64_t kMaxReadbackBytes = 512ull * 1024ull * 1024ull;
// Output-owned capture instances share this process-wide budget. Multiple
// swapchains must not each reserve the full per-batch allowance at once.
constexpr uint64_t kMaxProcessReadbackBytes = 512ull * 1024ull * 1024ull;

class ReadbackBudget
{
  public:
    explicit ReadbackBudget(uint64_t limit) : limit_(limit) {}

    bool tryReserve(uint64_t bytes)
    {
        if (!bytes || bytes > limit_)
            return false;
        auto used = used_.load(std::memory_order_relaxed);
        while (used <= limit_ - bytes)
        {
            if (used_.compare_exchange_weak(used, used + bytes, std::memory_order_acq_rel,
                                            std::memory_order_relaxed))
                return true;
        }
        return false;
    }

    void release(uint64_t bytes)
    {
        if (!bytes)
            return;
        auto used = used_.load(std::memory_order_relaxed);
        while (used >= bytes)
        {
            if (used_.compare_exchange_weak(used, used - bytes, std::memory_order_acq_rel,
                                            std::memory_order_relaxed))
                return;
        }
    }

    uint64_t used() const { return used_.load(std::memory_order_acquire); }

  private:
    const uint64_t limit_;
    std::atomic<uint64_t> used_ { 0 };
};

inline ReadbackBudget& ProcessReadbackBudget()
{
    static ReadbackBudget budget { kMaxProcessReadbackBytes };
    return budget;
}

struct Shot
{
    ID3D12Resource* readback = nullptr;
    ID3D12Resource* source = nullptr;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout = {};
    unsigned long long bytes = 0;
};

struct Identity {
    uint64_t owner=0,generation=0,view=0,frame=0,ticket=0;
};

// A bounded batch of matched image pairs. The existing NR recording leases own
// completion and retirement; CPU frame counts never establish either condition.
class FrameCapture
{
  public:
    ~FrameCapture() { release(); }
    FrameCapture() = default;
    FrameCapture(const FrameCapture&) = delete;
    FrameCapture& operator=(const FrameCapture&) = delete;

    // Pending copies remain owned until their exact generations retire. A new
    // request cannot overwrite or grow a batch that still has GPU consumers.
    void request(unsigned int frames)
    {
        if (active_ || !release()) return;
        wanted_ = frames > kMaxFrames ? kMaxFrames : frames;
        active_ = wanted_ > 0;
    }

    bool isActive() const { return active_; }
    unsigned int progress() const { return captured_; }

    bool readyToRelease() const {
        for (const auto& use : uses_) if (use && !use->Ready()) return false;
        return true;
    }
    bool readyToWrite() const {
        if (!ready_ || cancelled_ || !captured_ || !readyToRelease()) return false;
        for (unsigned i=0;i<captured_;++i) if (!uses_[i] || !uses_[i]->Completed()) return false;
        return true;
    }

    void record(ID3D12GraphicsCommandList* cmd, ID3D12Device* device, ID3D12Resource* before,
                D3D12_RESOURCE_STATES beforeState, ID3D12Resource* after, D3D12_RESOURCE_STATES afterState,
                const Identity& identity = {})
    {
        if (!active_ || ready_ || cancelled_ || captured_ >= wanted_ || !cmd || !device || !before || !after) return;
        if (captured_ && (!sameShape(beforeDesc_,before->GetDesc()) || !sameShape(afterDesc_,after->GetDesc()) ||
            identity.owner!=identities_[0].owner || identity.generation!=identities_[0].generation || identity.view!=identities_[0].view)) {
            // A resize/owner change cancels the whole comparison. Old footprints
            // and generation evidence cannot be reused for the new output.
            cancelled_=rearm_=true;
            return;
        }
        if (!ensure(device,before,after)) { cancelled_=true;return; }
        auto use=optishade::nr_lifetime::Capture(cmd);
        if (!use || !optishade::nr_lifetime::Active().Add(use)) { cancelled_=true;return; }
        uses_[captured_]=std::move(use);
        identities_[captured_]=identity;
        copy(cmd,before,beforeState,beforeShots_[captured_]);
        copy(cmd,after,afterState,afterShots_[captured_]);
        ++captured_;
        ready_=captured_>=wanted_;
    }

    // Polling is nonblocking. Map and file writes are reached only after every
    // captured command generation retired and every consumer actually completed.
    std::string write(const std::filesystem::path& directory)
    {
        if (!active_ || (!ready_ && !cancelled_) || !readyToRelease()) return {};
        if (cancelled_ || !readyToWrite()) {
            const unsigned retry=(rearm_ || !cancelled_) ? wanted_ : 0;
            release();
            request(retry);
            return {};
        }
        if (isDark(beforeShots_[0])) {
            const auto frames=wanted_;release();request(frames);return {};
        }
        std::error_code ec;
        std::filesystem::create_directories(directory,ec);
        if (ec) { release();return {}; }
        // The manifest certifies a complete batch. Do not leave a previous
        // manifest certifying partially overwritten files after an I/O failure.
        std::filesystem::remove(directory/"manifest.txt",ec);
        if (ec) { release();return {}; }
        bool written=true;
        for (unsigned i=0;i<captured_ && written;++i)
            written=dump(directory,"before",i,beforeShots_[i]) && dump(directory,"after",i,afterShots_[i]);
        written=written && writeManifest(directory);
        release();
        return written ? directory.string() : std::string{};
    }

    // Returns false and retains all objects on unknown completion, failed Signal
    // or device removal. The owning NR output uses the same leases during shutdown.
    bool release()
    {
        if (!readyToRelease()) return false;
        for (auto& s : beforeShots_) { if (s.readback) s.readback->Release();if (s.source) s.source->Release(); }
        for (auto& s : afterShots_) { if (s.readback) s.readback->Release();if (s.source) s.source->Release(); }
        ProcessReadbackBudget().release(reservedBytes_);
        reservedBytes_ = 0;
        beforeShots_.clear();afterShots_.clear();uses_.clear();identities_.clear();
        active_=ready_=cancelled_=rearm_=false;captured_=wanted_=0;
        return true;
    }

  private:
    static bool sameShape(const D3D12_RESOURCE_DESC& a,const D3D12_RESOURCE_DESC& b) {
        return a.Dimension==b.Dimension && a.Width==b.Width && a.Height==b.Height &&
            a.DepthOrArraySize==b.DepthOrArraySize && a.MipLevels==b.MipLevels &&
            TypedForCopy(a.Format)==TypedForCopy(b.Format) &&
            a.SampleDesc.Count==b.SampleDesc.Count && a.SampleDesc.Quality==b.SampleDesc.Quality;
    }
    bool ensure(ID3D12Device* device, ID3D12Resource* before, ID3D12Resource* after)
    {
        if (!beforeShots_.empty()) return true;
        beforeDesc_=before->GetDesc();afterDesc_=after->GetDesc();
        if (beforeDesc_.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || afterDesc_.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
            beforeDesc_.DepthOrArraySize!=1 || afterDesc_.DepthOrArraySize!=1 ||
            beforeDesc_.SampleDesc.Count!=1 || afterDesc_.SampleDesc.Count!=1) return false;
        beforeDesc_.Format=TypedForCopy(beforeDesc_.Format);afterDesc_.Format=TypedForCopy(afterDesc_.Format);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT beforeLayout{},afterLayout{};
        uint64_t beforeBytes=0,afterBytes=0;
        if(!measure(device,beforeDesc_,beforeLayout,beforeBytes)||!measure(device,afterDesc_,afterLayout,afterBytes)||
            beforeBytes>kMaxReadbackBytes||afterBytes>kMaxReadbackBytes-beforeBytes)return false;
        const uint64_t bytesPerFrame=beforeBytes+afterBytes;
        if(!bytesPerFrame||wanted_>kMaxReadbackBytes/bytesPerFrame)return false;
        const uint64_t batchBytes=bytesPerFrame*wanted_;
        beforeShots_.resize(wanted_);afterShots_.resize(wanted_);uses_.resize(wanted_);identities_.resize(wanted_);
        if (!ProcessReadbackBudget().tryReserve(batchBytes))
            return false;
        reservedBytes_ = batchBytes;
        for (unsigned i=0;i<wanted_;++i)
            if (!alloc(device,beforeDesc_,beforeShots_[i]) || !alloc(device,afterDesc_,afterShots_[i])) return false;
        return true;
    }

    // A copy needs a fully typed format, and the buffer the upscaler writes is occasionally declared
    // typeless. A placed footprint carrying a typeless format makes CopyTextureRegion invalid, and an
    // invalid copy removes the device -- which is what capturing did: it crashed the game every time
    // the output happened to be one of these.
    static DXGI_FORMAT TypedForCopy(DXGI_FORMAT f)
    {
        switch (f)
        {
        case DXGI_FORMAT_R16G16B16A16_TYPELESS:
            return DXGI_FORMAT_R16G16B16A16_FLOAT;
        case DXGI_FORMAT_R32G32B32A32_TYPELESS:
            return DXGI_FORMAT_R32G32B32A32_FLOAT;
        case DXGI_FORMAT_R10G10B10A2_TYPELESS:
            return DXGI_FORMAT_R10G10B10A2_UNORM;
        case DXGI_FORMAT_R8G8B8A8_TYPELESS:
            return DXGI_FORMAT_R8G8B8A8_UNORM;
        case DXGI_FORMAT_B8G8R8A8_TYPELESS:
            return DXGI_FORMAT_B8G8R8A8_UNORM;
        default:
            return f;
        }
    }

    static bool alloc(ID3D12Device* device, const D3D12_RESOURCE_DESC& desc, Shot& shot)
    {
        D3D12_RESOURCE_DESC typed = desc;
        typed.Format = TypedForCopy(desc.Format);

        unsigned long long total = 0;
        device->GetCopyableFootprints(&typed, 0, 1, 0, &shot.layout, nullptr, nullptr, &total);
        shot.bytes = total;

        if (total == 0 || total == UINT64_MAX)
            return false;

        D3D12_HEAP_PROPERTIES heap = {};
        heap.Type = D3D12_HEAP_TYPE_READBACK;

        D3D12_RESOURCE_DESC buf = {};
        buf.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        buf.Width = total;
        buf.Height = 1;
        buf.DepthOrArraySize = 1;
        buf.MipLevels = 1;
        buf.Format = DXGI_FORMAT_UNKNOWN;
        buf.SampleDesc.Count = 1;
        buf.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

        return SUCCEEDED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buf,
                                                         D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                         IID_PPV_ARGS(&shot.readback)));
    }

    static bool measure(ID3D12Device* device,const D3D12_RESOURCE_DESC& desc,
                        D3D12_PLACED_SUBRESOURCE_FOOTPRINT& layout,uint64_t& bytes)
    {
        unsigned long long total=0;
        device->GetCopyableFootprints(&desc,0,1,0,&layout,nullptr,nullptr,&total);
        bytes=total;
        return bytes!=0&&bytes!=UINT64_MAX;
    }

    static void copy(ID3D12GraphicsCommandList* cmd, ID3D12Resource* src, D3D12_RESOURCE_STATES state,
                     Shot& shot)
    {
        if (shot.readback == nullptr)
            return;
        shot.source=src;src->AddRef();

        D3D12_RESOURCE_BARRIER b = {};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition.pResource = src;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = state;
        b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;

        const bool needsTransition = state != D3D12_RESOURCE_STATE_COPY_SOURCE;

        if (needsTransition)
            cmd->ResourceBarrier(1, &b);

        D3D12_TEXTURE_COPY_LOCATION dst = {};
        dst.pResource = shot.readback;
        dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        dst.PlacedFootprint = shot.layout;

        D3D12_TEXTURE_COPY_LOCATION source = {};
        source.pResource = src;
        source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        source.SubresourceIndex = 0;

        cmd->CopyTextureRegion(&dst, 0, 0, 0, &source, nullptr);

        if (needsTransition)
        {
            b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
            b.Transition.StateAfter = state;
            cmd->ResourceBarrier(1, &b);
        }
    }

    // Mean byte value across the image, sampled sparsely. Correct for 8-bit and 10-bit surfaces;
    // float surfaces of dark content read higher, which only means a float capture is never discarded.
    static bool isDark(Shot& shot)
    {
        if (shot.readback == nullptr || shot.bytes == 0)
            return false;

        void* mapped = nullptr;
        D3D12_RANGE range = { 0, (SIZE_T) shot.bytes };

        if (FAILED(shot.readback->Map(0, &range, &mapped)) || mapped == nullptr)
            return false;

        const unsigned char* p = (const unsigned char*) mapped;
        unsigned long long total = 0;
        unsigned long long count = 0;

        for (unsigned long long i = 0; i < shot.bytes; i += 1021)
        {
            total += p[i];
            ++count;
        }

        D3D12_RANGE written = { 0, 0 };
        shot.readback->Unmap(0, &written);
        return count > 0 && total / count < 4;
    }

    static bool dump(const std::filesystem::path& dir, const char* which, unsigned int index, Shot& shot)
    {
        if (shot.readback == nullptr)
            return false;

        void* mapped = nullptr;
        D3D12_RANGE range = { 0, (SIZE_T) shot.bytes };

        if (FAILED(shot.readback->Map(0, &range, &mapped)) || mapped == nullptr)
            return false;

        char name[64];
        std::snprintf(name, sizeof(name), "%s_%02u.raw", which, index);
        const auto path = dir / name;

        bool written=false;
        if (std::FILE* f = _wfopen(path.wstring().c_str(), L"wb"))
        {
            written=std::fwrite(mapped,1,(size_t)shot.bytes,f)==(size_t)shot.bytes;
            if (std::fclose(f)!=0) written=false;
        }

        D3D12_RANGE rangeWritten = { 0, 0 };
        shot.readback->Unmap(0, &rangeWritten);
        return written;
    }

    bool writeManifest(const std::filesystem::path& dir)
    {
        const auto path = dir / "manifest.txt";

        if (std::FILE* f = _wfopen(path.wstring().c_str(), L"wt"))
        {
            std::fprintf(f, "frames %u\n", captured_);
            std::fprintf(f, "before width %llu height %u format %d rowPitch %u\n",
                         (unsigned long long) beforeDesc_.Width, beforeDesc_.Height,
                         (int) beforeDesc_.Format,
                         beforeShots_.empty() ? 0 : beforeShots_[0].layout.Footprint.RowPitch);
            std::fprintf(f, "after width %llu height %u format %d rowPitch %u\n",
                         (unsigned long long) afterDesc_.Width, afterDesc_.Height, (int) afterDesc_.Format,
                         afterShots_.empty() ? 0 : afterShots_[0].layout.Footprint.RowPitch);
            std::fprintf(f, "\nbefore_NN.raw is the captured input image before this NR composition.\n");
            std::fprintf(f, "after_NN.raw is the matched image after the attempted NR composition; settings and model outcome are separate evidence.\n");
            std::fprintf(f, "Matched recorded frames; presentation and visual quality are not verified by this capture.\n");
            std::fprintf(f, "Completion: exact command recordings retired; all observed GPU consumers completed.\n");
            for (unsigned i=0;i<captured_;++i) {
                const auto& id=identities_[i];
                std::fprintf(f, "frame %u owner %llu generation %llu view %llu frameToken %llu ticket %llu recording %llu\n",i,
                    (unsigned long long)id.owner,(unsigned long long)id.generation,(unsigned long long)id.view,
                    (unsigned long long)id.frame,(unsigned long long)id.ticket,(unsigned long long)uses_[i]->Generation());
            }
            const bool written=std::ferror(f)==0;
            return std::fclose(f)==0 && written;
        }
        return false;
    }

    std::vector<Shot> beforeShots_;
    std::vector<Shot> afterShots_;
    std::vector<optishade::nr_lifetime::Use> uses_;
    std::vector<Identity> identities_;
    D3D12_RESOURCE_DESC beforeDesc_ = {};
    D3D12_RESOURCE_DESC afterDesc_ = {};
    unsigned int wanted_ = 0;
    unsigned int captured_ = 0;
    uint64_t reservedBytes_ = 0;
    bool active_ = false;
    bool ready_ = false;
    bool cancelled_=false,rearm_=false;
};
} // namespace capture
