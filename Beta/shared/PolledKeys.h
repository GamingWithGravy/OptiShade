#pragma once
#include <array>
namespace optishade::input {
class PolledKeys {
 std::array<short,256> keys{};
public:
 // Call before taking the input state lock. The OS or another overlay's key
 // hook can depend on a thread which itself needs that lock (e.g. CloseHandle).
 template<class Read> void Capture(Read read) {
  for(unsigned key=0;key<keys.size();++key)keys[key]=read(static_cast<int>(key));
 }
 short Read(int key) const {return key>=0&&key<256?keys[key]:0;}
};
}
