#pragma once
#include "D3D12FrameContext.h"
#include <tuple>
#include <type_traits>
#include <array>

namespace optishade::restore {
template<class T> struct Value {
    T value;
    bool Valid() const { return true; }
    T Get() const { return value; }
};
template<class T> struct Object {
    T* requested;
    Microsoft::WRL::ComPtr<T> native;
    bool Valid() const { return !requested || native != nullptr; }
    T* Get() const { return native.Get(); }
};
template<class T> auto NativeValue(T value) {
    if constexpr(std::is_pointer_v<T> && std::is_base_of_v<IUnknown,std::remove_pointer_t<T>>) {
        Object<std::remove_pointer_t<T>> out{value,{}};
        auto identity=ReShadeObjectIdentity(value);
        if(identity)identity.As(&out.native);
        return out;
    } else return Value<T>{value};
}
// A native trampoline must receive native interfaces. The early-only path
// retains the original interface contract. Hold unwrapped COM references until
// the call returns; never infer equivalence from adapter IDs or vtable shapes.
template<class Function,class... Args>
bool Call(Function early,Function late,ID3D12GraphicsCommandList* commands,Args... args) {
    if(!commands)return false;
    if(!late){if(!early)return false;early(commands,args...);return true;}
    auto command=NativeValue(commands);
    auto values=std::tuple{NativeValue(args)...};
    if(!command.Valid())return false;
    return std::apply([&](const auto&... value){
        if(!(value.Valid()&&...))return false;
        late(command.Get(),value.Get()...);return true;
    },values);
}
template<class Function>
bool Heaps(Function early,Function late,ID3D12GraphicsCommandList* commands,
           UINT count,ID3D12DescriptorHeap* const* heaps) {
    if(count>2||(count&&!heaps)||!commands)return false;
    if(!late){if(!early)return false;early(commands,count,heaps);return true;}
    auto command=NativeValue(commands);
    if(!command.Valid())return false;
    std::array<Microsoft::WRL::ComPtr<ID3D12DescriptorHeap>,2> held;
    std::array<ID3D12DescriptorHeap*,2> raw{};
    for(UINT i=0;i<count;++i){
        auto heap=NativeValue(heaps[i]);
        if(!heaps[i]||!heap.Valid())return false;
        held[i]=heap.native;raw[i]=held[i].Get();
    }
    late(command.Get(),count,count?raw.data():nullptr);return true;
}
// Forwarding a hook must preserve the intercepted command interface. Only a
// native entry accepts canonical native heaps; a wrapper entry performs its
// own explicit unwrapping (and must accept already-native heaps too).
template<class Function>
bool InteropHeaps(Function original, ID3D12GraphicsCommandList* commands,
                  UINT count, ID3D12DescriptorHeap* const* heaps) {
    if (!original || !commands || count>2 || (count&&!heaps)) return false;
    auto native=NativeValue(commands);
    if (!native.Valid()) return false;
    if (native.Get()!=commands) { original(commands,count,heaps);return true; }
    return Heaps<Function>(nullptr,original,commands,count,heaps);
}

// Hook installation time does not establish the interface domain. In particular,
// TAA can have only early hooks. Resolve the method from this native command
// list, rather than reusing a trampoline collected from another interface.
// Restoration runs while capture is suppressed by the existing NR scope.
template<class Function> Function NativeMethod(ID3D12GraphicsCommandList* commands,UINT slot) {
    auto native=NativeValue(commands);
    if(!commands||!native.Valid()||slot<25||slot>42)return nullptr;
    return reinterpret_cast<Function>((*reinterpret_cast<void***>(native.Get()))[slot]);
}
template<class Function,class... Args>
bool CallInterface(UINT slot,ID3D12GraphicsCommandList* commands,Args... args) {
    auto method=NativeMethod<Function>(commands,slot);
    return method&&Call<Function>(nullptr,method,commands,args...);
}
template<class Function>
bool HeapsInterface(UINT slot,ID3D12GraphicsCommandList* commands,UINT count,ID3D12DescriptorHeap*const* heaps) {
    auto method=NativeMethod<Function>(commands,slot);
    return method&&Heaps<Function>(nullptr,method,commands,count,heaps);
}

}
