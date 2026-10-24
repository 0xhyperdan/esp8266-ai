#pragma once

// Platform-neutral read-only monitor: native Bambu LAN on S3, bridge on ESP8266.

#include <Arduino.h>
#include <ArduinoJson.h>

namespace PrinterMonitor {

struct Config {
  bool enabled = false;
  bool allowSelfSigned = false;
  char host[16] = {};
  char serial[33] = {};
  char accessCode[65] = {};
};

struct Snapshot {
  bool supported;
  bool configured;
  bool enabled;
  bool connected;
  bool stale;
  bool progressKnown;
  bool remainingKnown;
  bool nozzleKnown;
  bool bedKnown;
  bool layersKnown;
  bool dualNozzle;
  bool nozzleKnownN[2];
  float nozzleN[2];
  int activeNozzle;
  int progress;
  int remainingMinutes;
  int layer;
  int totalLayers;
  float nozzle;
  float nozzleTarget;
  float bed;
  float bedTarget;
  char state[20];
  char job[128];
  char error[96];
};

inline void writeSnapshotText(JsonObject object, const Snapshot &state) {
  // Snapshot arrays are temporary, not static string literals. Force ownership
  // before the caller returns and its stack memory is reused during serialization.
  object["state"] = JsonString(state.state, false);
  object["job"] = JsonString(state.job, false);
  object["error"] = JsonString(state.error, false);
}

void begin(bool filesystemReady);
Snapshot snapshot();
Config configuration();
bool configure(const Config &config, String &error);
bool clear(String &error);
void poll();
// Accept a complete normalized bridge snapshot only on ESP8266; never credentials.
bool ingestBridge(const char *payload, size_t length);

}  // namespace PrinterMonitor
