#include "printer_bridge_parser.h"

#include <cassert>
#include <cstdio>
#include <string>

int main() {
  using namespace PrinterMonitor;
  {
    Snapshot transient{};
    strcpy(transient.state, "RUNNING");
    strcpy(transient.job, "test-job.3mf");
    strcpy(transient.error, "test-error");
    JsonDocument document;
    writeSnapshotText(document.to<JsonObject>(), transient);
    memset(transient.state, 0, sizeof(transient.state));
    memset(transient.job, 0, sizeof(transient.job));
    memset(transient.error, 0, sizeof(transient.error));
    assert(document["state"] == "RUNNING");
    assert(document["job"] == "test-job.3mf");
    assert(document["error"] == "test-error");
  }
  const std::string base = R"({"supported":true,"configured":true,"enabled":true,"connected":true,"stale":false,"dual_nozzle":true,"state":"RUNNING","job":"测试模型.3mf","error":""})";
  auto with = [&](const std::string &extra) {
    return base.substr(0, base.size() - 1) + "," + extra + "}";
  };
  Snapshot value{};
  auto parse = [&](const std::string &text) {
    return parseBridgeSnapshot(text.c_str(), text.size(), value);
  };
  assert(parse(with(R"("progress":42,"remaining_min":81,"layer":12,"total_layers":200,"nozzle_c":220.5,"nozzle_left_c":200,"nozzle_right_c":220,"bed_c":55)")));
  assert(value.supported && value.connected && value.progressKnown && value.progress == 42);
  assert(value.layersKnown && value.nozzleKnownN[1] && value.nozzleN[1] == 200);
  assert(std::string(value.job) == "测试模型.3mf");
  const Snapshot retained = value;
  assert(bridgeSnapshotAt(retained, true, 0, 59999).connected);
  const Snapshot timedOut = bridgeSnapshotAt(retained, true, 0, 60000);
  assert(!timedOut.connected && timedOut.stale && timedOut.progress == 42);
  assert(std::string(timedOut.job) == retained.job && timedOut.nozzle == retained.nozzle);
  assert(!bridgeSnapshotAt(retained, false, 0, 0).connected);
  assert(bridgeSnapshotAt(retained, true, UINT32_MAX - 100, 100).connected);
  assert(parse(with(R"("remaining_min":100000,"layer":100000,"total_layers":100000,"nozzle_c":500,"nozzle_left_c":500,"nozzle_right_c":500,"bed_c":200)")));
  assert(value.remainingMinutes == 100000 && value.layer == 100000 && value.nozzle == 500 && value.bed == 200);
  assert(parse(base));
  assert(!value.progressKnown && !value.remainingKnown && !value.layersKnown &&
         !value.nozzleKnown && !value.bedKnown && !value.nozzleKnownN[0]);
  for (const auto &bad : {R"("progress":"42")", R"("progress":true)",
       R"("progress":42.5)", R"("progress":101)", R"("progress":null)",
       R"("remaining_min":-1)", R"("layer":1)", R"("layer":3,"total_layers":2)",
       R"("remaining_min":100001)", R"("layer":100001,"total_layers":100001)",
       R"("bed_c":201)", R"("nozzle_c":501)", R"("nozzle_left_c":501)",
       R"("nozzle_right_c":501)", R"("nozzle_c":"220")", R"("nozzle_c":false)",
       R"("job":"bad\u0000name")", R"("enabled":1)", R"("state":{})"}) {
    assert(!parse(with(bad)));
    assert(!value.progressKnown && value.connected); // Rejection is atomic.
  }
  assert(!parse(with("\"job\":\"" + std::string(128, 'x') + "\"")));
  assert(!parse(with(std::string("\"job\":\"") + "\xc3(" + "\"")));
  assert(!parse(std::string(2049, ' ')));
  assert(!parse("[]"));
  assert(!parse("{}"));
  assert(!parse(base.substr(0, base.size() - 1)));
  assert(parse(with(R"("connected":true,"stale":true)")) && !value.connected);
#if defined(ARDUINO_ARCH_ESP8266)
  begin(false);
  assert(snapshot().supported && snapshot().stale && !snapshot().connected);
  assert(ingestBridge(base.c_str(), base.size()));
  assert(snapshot().connected && !snapshot().stale);
  assert(!ingestBridge("{}", 2) && snapshot().connected);
  String error;
  assert(!configure(Config{}, error));
#endif
  std::puts("printer bridge parser and timeout tests passed");
}
