#pragma once

#include <Arduino.h>

inline void platformInitializePowerHold()
{
#if AICLOCK_POWER_HOLD_PIN >= 0
  pinMode(AICLOCK_POWER_HOLD_PIN, OUTPUT);
  digitalWrite(AICLOCK_POWER_HOLD_PIN, AICLOCK_POWER_HOLD_ACTIVE_HIGH ? HIGH : LOW);
#endif
}

#if defined(ESP32)
#include <HTTPClient.h>
#include <LittleFS.h>
#include <WebServer.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <esp_system.h>

using AIClockWebServer = WebServer;
using File = fs::File;

inline String platformResetReason()
{
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:
      return "power_on";
    case ESP_RST_EXT:
      return "external";
    case ESP_RST_SW:
      return "software";
    case ESP_RST_PANIC:
      return "panic";
    case ESP_RST_INT_WDT:
      return "interrupt_watchdog";
    case ESP_RST_TASK_WDT:
      return "task_watchdog";
    case ESP_RST_WDT:
      return "watchdog";
    case ESP_RST_DEEPSLEEP:
      return "deep_sleep";
    case ESP_RST_BROWNOUT:
      return "brownout";
    case ESP_RST_SDIO:
      return "sdio";
    default:
      return "unknown";
  }
}

inline uint32_t platformMaxFreeBlockSize()
{
  return ESP.getMaxAllocHeap();
}

inline String platformUpdateErrorString()
{
  return Update.errorString();
}

inline bool platformMountFileSystemOnStartup()
{
  return LittleFS.begin(true);
}

inline void platformDisableWiFi()
{
  WiFi.persistent(false);
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_OFF);
}

constexpr uint8_t kBacklightLedcChannel = 0;
constexpr uint8_t kBacklightLedcResolution = 10;

inline void platformInitializeBacklight()
{
  ledcSetup(kBacklightLedcChannel, BRIGHTNESS_PWM_FREQ, kBacklightLedcResolution);
  ledcAttachPin(TFT_BL, kBacklightLedcChannel);
}

inline void platformWriteBacklight(int brightness)
{
  const int percentage = AICLOCK_BACKLIGHT_ACTIVE_HIGH ? brightness : 100 - brightness;
  const uint32_t maximum = (1U << kBacklightLedcResolution) - 1U;
  ledcWrite(kBacklightLedcChannel, maximum * constrain(percentage, 0, 100) / 100U);
}

#else

#include <ESP8266HTTPClient.h>
#include <ESP8266WebServer.h>
#include <ESP8266WiFi.h>
#include <LittleFS.h>
#include <WiFiClient.h>

using AIClockWebServer = ESP8266WebServer;

inline String platformResetReason()
{
  return ESP.getResetReason();
}

inline uint32_t platformMaxFreeBlockSize()
{
  return ESP.getMaxFreeBlockSize();
}

inline String platformUpdateErrorString()
{
  return Update.getErrorString();
}

inline bool platformMountFileSystemOnStartup()
{
  return LittleFS.begin();
}

inline void platformDisableWiFi()
{
  WiFi.persistent(false);
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();
}

inline void platformInitializeBacklight()
{
  analogWriteFreq(BRIGHTNESS_PWM_FREQ);
  analogWriteRange(100);
}

inline void platformWriteBacklight(int brightness)
{
  const int percentage = AICLOCK_BACKLIGHT_ACTIVE_HIGH ? brightness : 100 - brightness;
  analogWrite(TFT_BL, constrain(percentage, 0, 100));
}

#endif
