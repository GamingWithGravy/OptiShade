#pragma once
#include <d3d12.h>
namespace optishade::taa {
inline D3D12_RESOURCE_DESC BaseMipDescription(ID3D12Resource* source,bool writable){
 auto d=source->GetDesc();d.Alignment=0;d.MipLevels=1;d.Layout=D3D12_TEXTURE_LAYOUT_UNKNOWN;
 d.Flags=writable?D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS:D3D12_RESOURCE_FLAG_NONE;return d;
}
inline bool BaseMipCopyMatches(ID3D12Resource* copy,ID3D12Resource* source,bool writable){
 if(!copy)return false;auto a=copy->GetDesc(),b=BaseMipDescription(source,writable);
 ID3D12Device *ad=nullptr,*bd=nullptr;copy->GetDevice(IID_PPV_ARGS(&ad));source->GetDevice(IID_PPV_ARGS(&bd));bool same=ad&&ad==bd;if(ad)ad->Release();if(bd)bd->Release();
 return same&&a.Width==b.Width&&a.Height==b.Height&&a.Format==b.Format&&a.Flags==b.Flags&&a.MipLevels==1;
}
inline HRESULT CreateBaseMipCopy(ID3D12Device* device,ID3D12Resource* source,bool writable,ID3D12Resource** output){
 auto d=BaseMipDescription(source,writable);D3D12_HEAP_PROPERTIES h{};h.Type=D3D12_HEAP_TYPE_DEFAULT;
 return device->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(output));
}
inline void MipZeroBarrier(ID3D12GraphicsCommandList* cmd,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){
 if(before==after)return;D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,0,before,after};cmd->ResourceBarrier(1,&b);
}
inline void CopyBaseMip(ID3D12GraphicsCommandList* cmd,ID3D12Resource* source,ID3D12Resource* copy,D3D12_RESOURCE_STATES arrival){
 MipZeroBarrier(cmd,source,arrival,D3D12_RESOURCE_STATE_COPY_SOURCE);
 D3D12_TEXTURE_COPY_LOCATION s{},d{};s.pResource=source;d.pResource=copy;s.Type=d.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;s.SubresourceIndex=d.SubresourceIndex=0;
 cmd->CopyTextureRegion(&d,0,0,0,&s,nullptr);
 MipZeroBarrier(cmd,source,D3D12_RESOURCE_STATE_COPY_SOURCE,arrival);MipZeroBarrier(cmd,copy,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
}
inline void ReturnBaseMip(ID3D12GraphicsCommandList* cmd,ID3D12Resource* copy,ID3D12Resource* original,D3D12_RESOURCE_STATES arrival){
 MipZeroBarrier(cmd,copy,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);MipZeroBarrier(cmd,original,arrival,D3D12_RESOURCE_STATE_COPY_DEST);
 D3D12_TEXTURE_COPY_LOCATION s{},d{};s.pResource=copy;d.pResource=original;s.Type=d.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;s.SubresourceIndex=d.SubresourceIndex=0;
 cmd->CopyTextureRegion(&d,0,0,0,&s,nullptr);MipZeroBarrier(cmd,original,D3D12_RESOURCE_STATE_COPY_DEST,arrival);MipZeroBarrier(cmd,copy,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
}
}
