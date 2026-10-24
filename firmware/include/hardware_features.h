#pragma once

#include <Arduino.h>

namespace HardwareFeatures {

struct BatteryState {
  bool supported = false;
  bool present = false;
  bool charging = false;
  int level = -1;
  uint32_t voltageMv = 0;
};

void begin();
bool imuAvailable();
bool pollSuggestedRotation(uint8_t currentRotation, uint8_t &suggestedRotation);
bool pollBattery(bool force = false);
const BatteryState &battery();

} // namespace HardwareFeatures
