#pragma once

#include "printer_monitor_parser.h"
#include <cmath>

namespace PrinterMonitor {

constexpr size_t kBridgePayloadLimit = 2048;
constexpr uint32_t kBridgeStaleMs = 60000;

inline bool bridgeText(JsonVariantConst value, char *output, size_t capacity) {
  if (!value.is<const char *>()) return false;
  const JsonString text = value.as<JsonString>();
  if (text.size() >= capacity || text.size() != strlen(text.c_str())) return false;
  copyText(output, capacity, text.c_str());
  // Reject malformed UTF-8 instead of silently modifying the bridge snapshot.
  return strcmp(output, text.c_str()) == 0;
}

inline bool bridgeInteger(JsonObjectConst object, const char *key, int &output,
                          int minimum, int maximum, bool &known) {
  known = false;
  if (!object[key].isUnbound()) {
    JsonVariantConst value = object[key];
    if (!value.is<int>() || value.is<bool>()) return false;
    output = value.as<int>();
    if (output < minimum || output > maximum) return false;
    known = true;
  }
  return true;
}

inline bool bridgeTemperature(JsonObjectConst object, const char *key,
                              float &output, bool &known, float maximum) {
  known = false;
  if (!object[key].isUnbound()) {
    JsonVariantConst value = object[key];
    if (value.is<bool>() || !value.is<double>()) return false;
    const double number = value.as<double>();
    if (!std::isfinite(number) || number < 0 || number > maximum) return false;
    output = static_cast<float>(number);
    known = true;
  }
  return true;
}

inline bool parseBridgeSnapshot(const char *payload, size_t length, Snapshot &result) {
  if (!payload || !length || length > kBridgePayloadLimit) return false;
  JsonDocument document;
  if (deserializeJson(document, payload, length, DeserializationOption::NestingLimit(2)))
    return false;
  if (!document.is<JsonObject>()) return false;
  const JsonObjectConst object = document.as<JsonObjectConst>();
  for (const char *key : {"supported", "configured", "enabled", "connected", "stale", "dual_nozzle"}) {
    if (!object[key].is<bool>()) return false;
  }
  Snapshot next{};
  next.supported = true;
  next.configured = object["configured"].as<bool>();
  next.enabled = object["enabled"].as<bool>();
  next.stale = object["stale"].as<bool>();
  next.connected = object["connected"].as<bool>() && object["supported"].as<bool>() &&
      next.configured && next.enabled && !next.stale;
  next.dualNozzle = object["dual_nozzle"].as<bool>();
  next.activeNozzle = -1;
  if (!bridgeText(object["state"], next.state, sizeof(next.state)) ||
      !bridgeText(object["job"], next.job, sizeof(next.job)) ||
      !bridgeText(object["error"], next.error, sizeof(next.error))) return false;
  bool layerKnown = false, totalKnown = false;
  if (!bridgeInteger(object, "progress", next.progress, 0, 100, next.progressKnown) ||
      !bridgeInteger(object, "remaining_min", next.remainingMinutes, 0, 100000, next.remainingKnown) ||
      !bridgeInteger(object, "layer", next.layer, 0, 100000, layerKnown) ||
      !bridgeInteger(object, "total_layers", next.totalLayers, 0, 100000, totalKnown) ||
      !bridgeTemperature(object, "nozzle_c", next.nozzle, next.nozzleKnown, 500) ||
      !bridgeTemperature(object, "bed_c", next.bed, next.bedKnown, 200) ||
      !bridgeTemperature(object, "nozzle_left_c", next.nozzleN[1], next.nozzleKnownN[1], 500) ||
      !bridgeTemperature(object, "nozzle_right_c", next.nozzleN[0], next.nozzleKnownN[0], 500)) return false;
  if (layerKnown != totalKnown || (layerKnown && next.layer > next.totalLayers)) return false;
  next.layersKnown = layerKnown && totalKnown;
  result = next;
  return true;
}

inline Snapshot bridgeSnapshotAt(const Snapshot &stored, bool received,
                                 uint32_t lastPacketMs, uint32_t nowMs) {
  Snapshot result = stored;
  result.supported = true;
  if (!received || static_cast<uint32_t>(nowMs - lastPacketMs) >= kBridgeStaleMs) {
    result.connected = false;
    result.stale = true;
  }
  return result;
}

}  // namespace PrinterMonitor
