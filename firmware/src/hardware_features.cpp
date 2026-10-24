#include "hardware_features.h"

#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
#include <SensorQMI8658.hpp>
#include <Wire.h>
#include <math.h>
#endif

namespace HardwareFeatures {
namespace {

BatteryState batteryState;

#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
SensorQMI8658 imu;
bool imuReady = false;
unsigned long lastOrientationPollMs = 0;
unsigned long lastBatteryPollMs = 0;
int candidateRotation = -1;
uint8_t candidateSamples = 0;

constexpr unsigned long kOrientationPollIntervalMs = 150;
constexpr unsigned long kBatteryPollIntervalMs = 15000;
constexpr float kOrientationThresholdG = 0.58f;
constexpr float kOrientationAxisMarginG = 0.12f;
constexpr uint8_t kStableOrientationSamples = 4;

int batteryLevelFromVoltage(uint32_t voltageMv)
{
  struct CurvePoint {
    uint16_t voltage;
    uint8_t level;
  };
  static constexpr CurvePoint curve[] = {
      {3300, 0}, {3500, 10}, {3620, 20}, {3680, 30}, {3740, 40}, {3790, 50},
      {3850, 60}, {3920, 70}, {4000, 80}, {4100, 90}, {4200, 100},
  };

  if (voltageMv <= curve[0].voltage) return curve[0].level;
  for (size_t index = 1; index < sizeof(curve) / sizeof(curve[0]); index++) {
    if (voltageMv <= curve[index].voltage) {
      const CurvePoint &low = curve[index - 1];
      const CurvePoint &high = curve[index];
      return low.level +
             (voltageMv - low.voltage) * (high.level - low.level) /
                 (high.voltage - low.voltage);
    }
  }
  return 100;
}

uint32_t readBatteryVoltageMv()
{
  constexpr size_t kSamples = 7;
  uint32_t samples[kSamples];
  for (size_t index = 0; index < kSamples; index++) {
    samples[index] = analogReadMilliVolts(AICLOCK_BATTERY_ADC_PIN);
    delay(2);
  }
  for (size_t index = 1; index < kSamples; index++) {
    uint32_t value = samples[index];
    size_t position = index;
    while (position > 0 && samples[position - 1] > value) {
      samples[position] = samples[position - 1];
      position--;
    }
    samples[position] = value;
  }
  return lroundf(samples[kSamples / 2] * AICLOCK_BATTERY_DIVIDER);
}

int rotationFromGravity(float x, float y)
{
  const float absX = fabsf(x);
  const float absY = fabsf(y);
  if (absX >= kOrientationThresholdG && absX >= absY + kOrientationAxisMarginG) {
    return x > 0 ? 3 : 1;
  }
  if (absY >= kOrientationThresholdG && absY >= absX + kOrientationAxisMarginG) {
    return y > 0 ? 0 : 2;
  }
  return -1;
}
#endif

} // namespace

void begin()
{
#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
  batteryState.supported = true;
  pinMode(AICLOCK_BATTERY_CHARGE_PIN, INPUT_PULLUP);
  analogReadResolution(12);
  analogSetPinAttenuation(AICLOCK_BATTERY_ADC_PIN, ADC_11db);
  pollBattery(true);

  imuReady = imu.begin(Wire, QMI8658_L_SLAVE_ADDRESS, AICLOCK_IMU_SDA, AICLOCK_IMU_SCL);
  if (imuReady) {
    imu.configAccelerometer(SensorQMI8658::ACC_RANGE_4G,
                            SensorQMI8658::ACC_ODR_31_25Hz,
                            SensorQMI8658::LPF_MODE_0);
    imu.enableAccelerometer();
    Serial.printf("[hardware] QMI8658 ready, battery=%s %lumV %d%%\n",
                  batteryState.present ? "present" : "absent",
                  (unsigned long)batteryState.voltageMv, batteryState.level);
  } else {
    Serial.println("[hardware] QMI8658 not found; auto rotation unavailable");
  }
#endif
}

bool imuAvailable()
{
#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
  return imuReady;
#else
  return false;
#endif
}

bool pollSuggestedRotation(uint8_t currentRotation, uint8_t &suggestedRotation)
{
#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
  if (!imuReady || millis() - lastOrientationPollMs < kOrientationPollIntervalMs) return false;
  lastOrientationPollMs = millis();
  float x = 0, y = 0, z = 0;
  if (!imu.getAccelerometer(x, y, z)) return false;

  const int rotation = rotationFromGravity(x, y);
  if (rotation < 0 || rotation == currentRotation) {
    candidateRotation = -1;
    candidateSamples = 0;
    return false;
  }
  if (candidateRotation != rotation) {
    candidateRotation = rotation;
    candidateSamples = 1;
    return false;
  }
  if (++candidateSamples < kStableOrientationSamples) return false;

  candidateRotation = -1;
  candidateSamples = 0;
  suggestedRotation = rotation;
  Serial.printf("[hardware] orientation x=%.2f y=%.2f z=%.2f -> rotation=%d\n",
                x, y, z, rotation);
  return true;
#else
  (void)currentRotation;
  (void)suggestedRotation;
  return false;
#endif
}

bool pollBattery(bool force)
{
#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
  if (!force && millis() - lastBatteryPollMs < kBatteryPollIntervalMs) return false;
  lastBatteryPollMs = millis();

  BatteryState next = batteryState;
  next.supported = true;
  next.voltageMv = readBatteryVoltageMv();
  next.present = next.voltageMv >= 2800 && next.voltageMv <= 4600;
  next.charging = next.present && digitalRead(AICLOCK_BATTERY_CHARGE_PIN) == LOW;
  next.level = next.present ? batteryLevelFromVoltage(next.voltageMv) : -1;

  const bool changed = next.present != batteryState.present ||
                       next.charging != batteryState.charging ||
                       next.level != batteryState.level ||
                       abs((long)next.voltageMv - (long)batteryState.voltageMv) >= 30;
  batteryState = next;
  return changed;
#else
  (void)force;
  return false;
#endif
}

const BatteryState &battery() { return batteryState; }

} // namespace HardwareFeatures
