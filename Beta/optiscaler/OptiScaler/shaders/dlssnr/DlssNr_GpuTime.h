#pragma once
#include "../../../../shared/NrObservation.h"
#include "../../../../shared/D3D12FrameContext.h"

// NR calls are serialized by the NR event gate, including submission/reset notifications.
// Associate every query pair with its actual submitting queue and GPU completion.
class DlssNrGpuTime
{
    using Resource = Microsoft::WRL::ComPtr<ID3D12Resource>;
    struct Sample
    {
        Microsoft::WRL::ComPtr<ID3D12Fence> fence;
        ID3D12CommandList* commands = nullptr; // identity only
        UINT64 value = 0, frequency = 0, sequence = 0;
        ULONGLONG submittedAt = 0;
        uint64_t observation = 0, queue = 0;
        bool occupied = false, ended = false, submitted = false;
    };
    static constexpr unsigned Count = 8;
    Microsoft::WRL::ComPtr<ID3D12QueryHeap> queries;
    Resource readback;
    std::array<Sample, Count> samples;
    int recording = -1;
    UINT64 sequence = 0, lastSequence = 0;
    ULONGLONG lastCompletedAt = 0;
    std::optional<double> last;

    static ID3D12CommandList* SubmissionIdentity(ID3D12CommandList* cmd) {
        ID3D12CommandList* result=cmd;
        IUnknown* real=nullptr;
        if(Util::CheckForRealObject(__FUNCTION__,cmd,&real))result=static_cast<ID3D12CommandList*>(real);
        Microsoft::WRL::ComPtr<IUnknown> native;
        Microsoft::WRL::ComPtr<ID3D12CommandList> list;
        if(SUCCEEDED(cmd->QueryInterface(optishade::ReShadeUnwrappedObject,
            reinterpret_cast<void**>(native.GetAddressOf()))) && native && SUCCEEDED(native.As(&list)))result=list.Get();
        return result; // Borrowed identity; cmd retains its underlying object.
    }

    void Collect()
    {
        for (unsigned i = 0; i < Count; ++i)
        {
            auto& s = samples[i];
            if (!s.occupied || !s.submitted) continue;
            const auto completed = s.fence->GetCompletedValue();
            if (completed == UINT64_MAX || completed < s.value) continue;
            // Completion and a valid duration are separate observations. Age from
            // submission, conservatively: polling an old fence cannot revive old work.
            const bool newest = s.sequence > lastSequence;
            if (newest)
            {
                lastSequence = s.sequence;
                lastCompletedAt = s.submittedAt;
                last.reset();
            }
            UINT64* data = nullptr;
            D3D12_RANGE range { i * 2 * sizeof(UINT64), (i * 2 + 2) * sizeof(UINT64) };
            if (SUCCEEDED(readback->Map(0, &range, (void**) &data)))
            {
                const auto begin = data[i * 2], end = data[i * 2 + 1];
                if (newest && s.frequency && begin && end >= begin)
                {
                    last = double(end - begin) * 1000.0 / double(s.frequency);
                }
                D3D12_RANGE written { 0, 0 };
                readback->Unmap(0, &written);
            }
            if(newest) optishade::nr_observation::State().Completed(s.observation,s.queue,s.frequency,last);
            s.occupied = false;
        }
    }

  public:
    DlssNrGpuTime(ID3D12Device* device, [[maybe_unused]] const char* name)
    {
        D3D12_QUERY_HEAP_DESC queryDesc { D3D12_QUERY_HEAP_TYPE_TIMESTAMP, Count * 2, 0 };
        if (FAILED(device->CreateQueryHeap(&queryDesc, IID_PPV_ARGS(&queries)))) return;
        const auto heap = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_READBACK);
        const auto desc = CD3DX12_RESOURCE_DESC::Buffer(Count * 2 * sizeof(UINT64));
        if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)))) return;
        for (auto& s : samples)
            if (FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&s.fence))))
            { readback.Reset(); return; }
    }

    void Start(ID3D12GraphicsCommandList* cmd, uint64_t observation = 0)
    {
        recording = -1;
        if (!readback) return;
        Collect();
        for (unsigned i = 0; i < Count; ++i)
        {
            auto& s = samples[i];
            if (s.occupied) continue;
            s.commands = SubmissionIdentity(cmd);
            s.observation = observation;
            s.occupied = true;
            s.ended = s.submitted = false;
            s.sequence = ++sequence;
            ++s.value;
            recording = (int) i;
            cmd->EndQuery(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, i * 2);
            break;
        }
    }

    void End(ID3D12GraphicsCommandList* cmd)
    {
        if (recording < 0) return;
        const auto i = (unsigned) recording;
        cmd->EndQuery(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, i * 2 + 1);
        cmd->ResolveQueryData(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, i * 2, 2,
                             readback.Get(), i * 2 * sizeof(UINT64));
        samples[i].ended = true;
        recording = -1;
    }

    void Submitted(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists, uint64_t observedAt)
    {
        for (auto& s : samples)
        {
            if (!s.occupied || !s.ended || s.submitted) continue;
            for (UINT i = 0; i < count; ++i)
                if (SubmissionIdentity(lists[i]) == s.commands)
                {
                    if (FAILED(queue->GetTimestampFrequency(&s.frequency))) s.frequency = 0;
                    // Executed after the real ExecuteCommandLists: protects query readback AND reuse.
                    // A failed signal must quarantine an executed slot, not make it look discarded.
                    s.queue = reinterpret_cast<uintptr_t>(queue);
                    s.submittedAt = observedAt;
                    s.submitted = true;
                    const bool signalled=SUCCEEDED(queue->Signal(s.fence.Get(), s.value));
                    if (!signalled) s.frequency = 0;
                    optishade::nr_observation::State().Submitted(s.observation,s.queue,s.submittedAt,signalled);
                    break;
                }
        }
    }

    void ResetRecording(ID3D12CommandList* cmd)
    {
        for (auto& s : samples)
            if (s.occupied && !s.submitted && s.commands == SubmissionIdentity(cmd)) s.occupied = false;
    }

    void ClearLast()
    {
        last.reset();
        lastCompletedAt = 0;
        lastSequence = sequence; // older, in-flight samples must not repopulate the display
    }

    bool HasRecentCompletion()
    {
        Collect();
        return lastCompletedAt && GetTickCount64() - lastCompletedAt < 1500;
    }

    std::optional<double> ReadGpuTime([[maybe_unused]] ID3D12CommandQueue* queue)
    {
        Collect();
        return lastCompletedAt && GetTickCount64() - lastCompletedAt < 1500 ? last : std::nullopt;
    }
};
