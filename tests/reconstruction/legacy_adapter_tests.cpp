#include "../../Beta/legacy-nr/upstream/src/feed_ipc.h"
#include <cstddef>
#include <iostream>
#include <stdexcept>
#include <vector>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)

int main() {
    static_assert(sizeof(FeedHelloAck) == 16, "old peers need the fixed version response");
    static_assert(offsetof(FeedHello, adapter) == 24, "retain the v4-v11 prefix");
    static_assert(sizeof(FeedHello) == 68 && sizeof(FeedAdapterAck) == 32);
    try {
        const FeedAdapterIdentity render{0x123456789abcdef0ull, 0x10de, 0x2684, 1};
        auto second = render; ++second.luid; // two identical GPUs are not interchangeable
        CHECK(FeedSameAdapter(render, render));
        CHECK(!FeedSameAdapter(render, second));
        auto unknown = render; unknown.valid = 0;
        CHECK(!FeedSameAdapter(render, unknown));
        auto invalid = render; invalid.valid = 2;
        CHECK(!FeedAdapterValid(invalid));
        FeedHello hello{FEED_IPC_MAGIC, FEED_IPC_VERSION, 42, FEED_CLIENT_D3D11, 0, render, 100, 1, 99};
        std::vector<int> events;
        bool deviceAvailable = true, modelAvailable = true, useWrongDevice = false;
        auto create = [&](const FeedAdapterIdentity &requested, FeedAdapterIdentity &actual) {
            events.push_back(1); CHECK(FeedSameAdapter(requested, render));
            actual = useWrongDevice ? second : render; return deviceAvailable;
        };
        auto model = [&] { events.push_back(2); return modelAvailable; };
        auto run = [&](FeedHello request, unsigned expected = 42, unsigned pipe = 42) {
            events.clear(); return FeedInitializeAdapter(request, expected, pipe, create, model);
        };
        CHECK(run(hello).status == FEED_ADAPTER_READY);
        CHECK(events == std::vector<int>({1, 2}));
        CHECK(FeedSameAdapter(run(hello).adapter, render));
        for (auto kind : {FEED_CLIENT_D3D11, FEED_CLIENT_GL, FEED_CLIENT_VULKAN}) {
            hello.client_kind = kind; CHECK(run(hello).status == FEED_ADAPTER_READY);
        }
        auto bad = hello; bad.adapter = unknown;
        CHECK(run(bad).status == FEED_ADAPTER_INVALID_IDENTITY && events.empty());
        bad = hello; bad.version = 11;
        CHECK(run(bad).status == FEED_ADAPTER_INVALID_IDENTITY && events.empty());
        bad = hello; bad.version = FEED_IPC_VERSION + 1;
        CHECK(run(bad).status == FEED_ADAPTER_INVALID_IDENTITY && events.empty());
        bad = hello; bad.magic = 0;
        CHECK(run(bad).status == FEED_ADAPTER_INVALID_IDENTITY && events.empty());
        bad = hello; bad.client_kind = 99;
        CHECK(run(bad).status == FEED_ADAPTER_INVALID_IDENTITY && events.empty());
        CHECK(run(hello, 43).status == FEED_ADAPTER_WRONG_PROCESS && events.empty());
        CHECK(run(hello, 42, 43).status == FEED_ADAPTER_WRONG_PROCESS && events.empty());
        CHECK(run(hello, 0, 0).status == FEED_ADAPTER_WRONG_PROCESS && events.empty());
        useWrongDevice = true;
        CHECK(run(hello).status == FEED_ADAPTER_DEVICE_UNAVAILABLE && events == std::vector<int>({1}));
        useWrongDevice = false; deviceAvailable = false;
        CHECK(run(hello).status == FEED_ADAPTER_DEVICE_UNAVAILABLE && events == std::vector<int>({1}));
        deviceAvailable = true; modelAvailable = false;
        CHECK(run(hello).status == FEED_ADAPTER_NGX_UNAVAILABLE && events == std::vector<int>({1, 2}));
        std::cout << "Legacy v13 adapter gate: peer/identity rejection, same-name GPUs, device-before-model ordering passed; no GPU execution.\n";
        return 0;
    } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
