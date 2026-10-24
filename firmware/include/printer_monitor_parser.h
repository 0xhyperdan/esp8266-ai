#pragma once

// Small, testable Bambu report parser. This header is intentionally independent
// of Arduino APIs, networking, filesystems, and the ESP32 SDK.

#include "printer_monitor.h"

#include <ArduinoJson.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace PrinterMonitor {

struct ParserState {
  char taskId[33] = {};
  char jobName[128] = {};
  bool layerKnown = false;
  bool totalLayersKnown = false;
};

inline void resetParserState(ParserState &state) { state = ParserState{}; }

inline void copyText(char *destination, size_t capacity, const char *source) {
  if (destination == nullptr || capacity == 0) return;
  if (source == nullptr) {
    destination[0] = '\0';
    return;
  }

  size_t input = 0, output = 0;
  while (source[input] && output + 1 < capacity) {
    const uint8_t lead = static_cast<uint8_t>(source[input]);
    size_t width = lead < 0x80 ? 1 : lead >= 0xc2 && lead <= 0xdf ? 2
        : lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
    bool valid = width != 0;
    for (size_t offset = 1; valid && offset < width; ++offset) {
      const uint8_t next = static_cast<uint8_t>(source[input + offset]);
      if ((next & 0xc0) != 0x80) valid = false;
    }
    if (valid && width >= 3) {
      const uint8_t next = static_cast<uint8_t>(source[input + 1]);
      if ((lead == 0xe0 && next < 0xa0) || (lead == 0xed && next >= 0xa0) ||
          (lead == 0xf0 && next < 0x90) || (lead == 0xf4 && next >= 0x90)) valid = false;
    }
    if (!valid) {
      destination[output++] = '?';
      ++input;
      continue;
    }
    if (output + width >= capacity) break;
    memcpy(destination + output, source + input, width);
    output += width;
    input += width;
  }
  destination[output] = '\0';
}

inline int clampInt(long value, long minimum, long maximum) {
  if (value < minimum) return static_cast<int>(minimum);
  if (value > maximum) return static_cast<int>(maximum);
  return static_cast<int>(value);
}

inline float clampFloat(double value, float minimum, float maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return static_cast<float>(value);
}

inline bool readInt(JsonVariantConst value, long &result) {
  if (value.is<int>()) {
    result = value.as<int>();
    return true;
  }
  if (value.is<long>()) {
    result = value.as<long>();
    return true;
  }
  if (value.is<long long>()) {
    result = static_cast<long>(value.as<long long>());
    return true;
  }
  return false;
}

inline bool readFloat(JsonVariantConst value, double &result) {
  if (value.is<float>()) {
    result = value.as<float>();
    return true;
  }
  if (value.is<double>()) {
    result = value.as<double>();
    return true;
  }

  long integer = 0;
  if (readInt(value, integer)) {
    result = static_cast<double>(integer);
    return true;
  }
  return false;
}

inline void clearJobCounters(Snapshot &snapshot) {
  snapshot.progressKnown = false;
  snapshot.remainingKnown = false;
  snapshot.layersKnown = false;
  snapshot.progress = 0;
  snapshot.remainingMinutes = 0;
  snapshot.layer = 0;
  snapshot.totalLayers = 0;
}

// Returns true only when at least one valid field needed by the monitor was
// accepted. Absent fields are preserved. Null and wrongly-typed fields never
// become false or zero.
inline bool parseReport(const char *json,
                        size_t length,
                        Snapshot &snapshot,
                        ParserState &parserState) {
  if (json == nullptr || length == 0) return false;

  JsonDocument filter;
  JsonObject printFilter = filter["print"].to<JsonObject>();
  printFilter["gcode_state"] = true;
  printFilter["mc_percent"] = true;
  printFilter["mc_remaining_time"] = true;
  printFilter["nozzle_temper"] = true;
  printFilter["nozzle_target_temper"] = true;
  printFilter["bed_temper"] = true;
  printFilter["bed_target_temper"] = true;
  printFilter["layer_num"] = true;
  printFilter["total_layer_num"] = true;
  printFilter["subtask_name"] = true;
  for (const char *key : {"extruder", "device"}) {
    JsonObject filterObject = printFilter[key].to<JsonObject>();
    if (strcmp(key, "device") == 0)
      filterObject = filterObject["extruder"].to<JsonObject>();
    filterObject["state"] = true;
    filterObject["info"][0]["id"] = true;
    filterObject["info"][0]["temp"] = true;
  }
  printFilter["task_id"] = true;
  printFilter["print_error"] = true;

  JsonDocument document;
  const DeserializationError result = deserializeJson(
      document, json, length, DeserializationOption::Filter(filter));
  if (result != DeserializationError::Ok) return false;

  JsonObjectConst print = document["print"];
  if (print.isNull()) return false;

  bool accepted = false;
  bool jobChanged = false;

  JsonVariantConst subtaskName = print["subtask_name"];
  if (subtaskName.is<const char *>()) {
    const char *name = subtaskName.as<const char *>();
    if (std::strcmp(name, parserState.jobName) != 0) {
      jobChanged = true;
    }
    copyText(parserState.jobName, sizeof(parserState.jobName), name);
    copyText(snapshot.job, sizeof(snapshot.job), name);
    accepted = true;
  }

  char taskId[sizeof(parserState.taskId)] = {};
  bool haveTaskId = false;
  JsonVariantConst taskIdValue = print["task_id"];
  if (taskIdValue.is<const char *>()) {
    copyText(taskId, sizeof(taskId), taskIdValue.as<const char *>());
    haveTaskId = true;
  } else {
    long numericTaskId = 0;
    if (readInt(taskIdValue, numericTaskId)) {
      constexpr size_t kBufferSize = sizeof(taskId);
      snprintf(taskId, kBufferSize, "%ld", numericTaskId);
      haveTaskId = true;
    }
  }

  if (haveTaskId && std::strcmp(taskId, parserState.taskId) != 0) {
    jobChanged = true;
    copyText(parserState.taskId, sizeof(parserState.taskId), taskId);
    if (!subtaskName.is<const char *>()) {
      snapshot.job[0] = '\0';
      parserState.jobName[0] = '\0';
    }
  }
  if (haveTaskId) accepted = true;

  JsonVariantConst state = print["gcode_state"];
  if (state.is<const char *>()) {
    const char *nextState = state.as<const char *>();
    const bool starting = !strcmp(nextState, "PREPARE") || !strcmp(nextState, "RUNNING");
    const bool wasTerminal = !strcmp(snapshot.state, "FINISH") ||
        !strcmp(snapshot.state, "FAILED") || !strcmp(snapshot.state, "IDLE");
    if (starting && wasTerminal) jobChanged = true;
  }

  if (jobChanged) {
    clearJobCounters(snapshot);
    parserState.layerKnown = false;
    parserState.totalLayersKnown = false;
    snapshot.state[0] = '\0';
    snapshot.error[0] = '\0';
  }

  if (state.is<const char *>()) {
    copyText(snapshot.state, sizeof(snapshot.state), state.as<const char *>());
    accepted = true;
  }

  long number = 0;
  if (readInt(print["mc_percent"], number)) {
    snapshot.progressKnown = true;
    snapshot.progress = clampInt(number, 0, 100);
    accepted = true;
  }

  if (readInt(print["mc_remaining_time"], number)) {
    snapshot.remainingKnown = true;
    snapshot.remainingMinutes = clampInt(number, 0, 10000);
    accepted = true;
  }

  if (readInt(print["layer_num"], number)) {
    parserState.layerKnown = true;
    snapshot.layer = clampInt(number, 0, 10000);
    accepted = true;
  }

  if (readInt(print["total_layer_num"], number)) {
    parserState.totalLayersKnown = true;
    snapshot.totalLayers = clampInt(number, 0, 10000);
    accepted = true;
  }

  snapshot.layersKnown = parserState.layerKnown && parserState.totalLayersKnown;

  double temperature = 0.0;
  if (!snapshot.dualNozzle && readFloat(print["nozzle_temper"], temperature)) {
    snapshot.nozzleKnown = true;
    snapshot.nozzle = clampFloat(temperature, -50.0f, 350.0f);
    accepted = true;
  }

  if (readFloat(print["nozzle_target_temper"], temperature)) {
    snapshot.nozzleTarget = clampFloat(temperature, -50.0f, 350.0f);
    accepted = true;
  }

  if (readFloat(print["bed_temper"], temperature)) {
    snapshot.bedKnown = true;
    snapshot.bed = clampFloat(temperature, -50.0f, 150.0f);
    accepted = true;
  }

  if (readFloat(print["bed_target_temper"], temperature)) {
    snapshot.bedTarget = clampFloat(temperature, -50.0f, 150.0f);
    accepted = true;
  }

  // X2D/H2 dual-nozzle reports encode temperature as target<<16 | current.
  // Keep both tools across delta packets; an active-tool-only update must not
  // accidentally leave the previous tool's temperature on screen.
  JsonObjectConst extruder = print["device"]["extruder"];
  if (extruder.isNull()) extruder = print["extruder"];
  if (!extruder.isNull()) {
    JsonArrayConst tools = extruder["info"];
    if (tools.size() >= 2) snapshot.dualNozzle = true;
    if (readInt(extruder["state"], number)) {
      const int active = (static_cast<uint32_t>(number) >> 4) & 15;
      if (active <= 1) {
        snapshot.activeNozzle = active;
        accepted = true;
      }
    }
    for (JsonObjectConst tool : tools) {
      long index = -1;
      if (!readInt(tool["id"], index) || index < 0 || index > 1 ||
          !tool["temp"].is<uint32_t>()) continue;
      const uint32_t packed = tool["temp"].as<uint32_t>();
      const uint32_t current = packed & 0xffff;
      if (current > 500) continue;
      snapshot.nozzleN[index] = current;
      if (index == 1) snapshot.dualNozzle = true;
      snapshot.nozzleKnownN[index] = true;
      accepted = true;
    }
    if (snapshot.dualNozzle) {
      snapshot.nozzleKnown = snapshot.nozzleKnownN[snapshot.activeNozzle];
      if (snapshot.nozzleKnown)
        snapshot.nozzle = snapshot.nozzleN[snapshot.activeNozzle];
    }
  }

  if (readInt(print["print_error"], number)) {
    accepted = true;
    if (number == 0) {
      snapshot.error[0] = '\0';
    } else {
      snprintf(snapshot.error, sizeof(snapshot.error), "printer error %ld", number);
    }
  }


  return accepted;
}

}  // namespace PrinterMonitor
