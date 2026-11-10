#include "InputHandleFilter.h"
#include <mutex>
#include <thread>
#include <future>
#include <iostream>
#include <stdexcept>
int main(){
    optishade::input::HandleFilter<64> filter;
    std::mutex input;
    auto check=[](bool ok){if(!ok)throw std::runtime_error("HID admission failure");};
    filter.Publish(2,42);
    check(filter.Contains(42));check(!filter.Contains(0));check(!filter.Contains(UINTPTR_MAX));
    // A loader/file worker must finish admission while the window thread owns
    // input state. Joining with that lock held reproduces the old lock cycle.
    std::unique_lock held(input);
    auto worker=std::async(std::launch::async,[&]{for(int i=0;i<100000;++i){if(filter.Contains(99))return false;}return true;});
    auto ready=worker.wait_for(std::chrono::seconds(2));
    held.unlock();check(ready==std::future_status::ready);check(worker.get());
    filter.Publish(2,0);check(!filter.Contains(42));
    filter.Publish(2,99);check(filter.Contains(99));check(!filter.Contains(42));
    std::thread reader([&]{for(int i=0;i<100000;++i)filter.Contains(99);});
    for(int i=0;i<100000;++i)filter.Publish(2,i%2?99:0);
    reader.join();filter.Clear();check(!filter.Contains(99));
    std::cout<<"HID admission concurrency, retirement/reuse and reset passed\n";
}
