// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <cstdint>
namespace optishade::capture {
constexpr uint32_t Version = 1;
enum class Stage : uint32_t { Idle, Accepted, Readback, Encoding, Saved, Failed, Cancelled, TimedOut };
struct Status {
 uint32_t version = Version;
 Stage stage = Stage::Idle;
 uint64_t request = 0, generation = 0, started = 0, updated = 0;
 uint32_t width = 0, height = 0, error = 0, busy = 0;
 char detail[1024]{};
};
using Request = uint64_t(*)();
using Read = bool(*)(Status*, uint32_t);
using Cancel = bool(*)(uint64_t);
// Called under the transport lock. A retired worker keeps its slot until it
// drains, preventing unbounded readbacks/encoders after repeated cancellation.
class Lifecycle {
 uint64_t sequence = 0, worker = 0;
public:
 Status status{};
 static bool terminal(Stage s) { return s >= Stage::Saved; }
 bool active(uint64_t id) const { return id && id == status.request && !terminal(status.stage); }
 uint64_t request(uint64_t generation, uint64_t now) {
  expire(now);
  if (!generation || status.busy) return 0;
  status = {}; status.request = ++sequence; status.generation = generation;
  status.started = status.updated = now; status.stage = Stage::Accepted; status.busy = 1;
  return sequence;
 }
 bool advance(uint64_t id, Stage stage, uint64_t now) {
  expire(now);
  if (!active(id)) return false;
  status.stage = stage; status.updated = now; return true;
 }
 uint64_t take(uint64_t generation, uint64_t now) {
  expire(now);
  if (status.stage != Stage::Accepted || status.generation != generation) return 0;
  worker = status.request; status.stage = Stage::Readback; status.updated = now; return worker;
 }
 bool cancel(uint64_t id, uint64_t now, Stage reason = Stage::Cancelled) {
  if (!active(id)) return false;
  status.stage = reason; status.updated = now; status.busy = worker ? 1 : 0; return true;
 }
 void expire(uint64_t now) {
  if (active(status.request) && now >= status.started && now - status.started >= 60000)
   cancel(status.request, now, Stage::TimedOut);
 }
 bool finish(uint64_t id, bool ok, uint64_t now) {
  expire(now);
  bool accepted = active(id);
  if (accepted) { status.stage = ok ? Stage::Saved : Stage::Failed; status.updated = now; }
  if (worker == id) worker = 0;
  if (status.request == id) status.busy = 0;
  return accepted;
 }
};
}
