#pragma once

// ---- Build profile ----
#ifndef AICLOCK_WIRED_ONLY
#define AICLOCK_WIRED_ONLY 0
#endif

// ---- Firmware identity (shown on the first-time WiFi setup screen & /api/info) ----
#if defined(AICLOCK_BOARD_ESP32_S3_TOUCH_LCD_1_54)
#define FW_VERSION "1.1.1-s3"
#define AICLOCK_BOARD_ID "waveshare-esp32-s3-touch-lcd-1.54"
#else
#define FW_VERSION "1.1.1"
#define AICLOCK_BOARD_ID "esp8266-fubotv-sd2"
#endif

#ifndef AICLOCK_BACKLIGHT_ACTIVE_HIGH
#define AICLOCK_BACKLIGHT_ACTIVE_HIGH 0
#endif

#ifndef AICLOCK_POWER_HOLD_PIN
#define AICLOCK_POWER_HOLD_PIN -1
#endif

#ifndef AICLOCK_POWER_HOLD_ACTIVE_HIGH
#define AICLOCK_POWER_HOLD_ACTIVE_HIGH 1
#endif

// ---- Web OTA ----
// Copy ota_secrets.example.h to ota_secrets.h and set unique credentials.
// The local secrets file is ignored by Git. Builds without it keep OTA disabled.
#if __has_include("ota_secrets.h")
#include "ota_secrets.h"
#define AICLOCK_OTA_ENABLED 1
#else
#define AICLOCK_OTA_ENABLED 0
#define OTA_USERNAME ""
#define OTA_PASSWORD ""
#endif

#define AICLOCK_OTA_AVAILABLE (AICLOCK_OTA_ENABLED && !AICLOCK_WIRED_ONLY)

// ---- Bridge polling ----
#define BRIDGE_DEFAULT_PORT 8765
#define BRIDGE_DEFAULT_PATH "/status"
#define BRIDGE_POLL_INTERVAL_MS 5000
#define BRIDGE_HTTP_TIMEOUT_MS 3000

// ---- WiFiManager ----
#define WIFI_PORTAL_AP_NAME "AI-Clock-Setup"
#define WIFI_CONFIG_FILE "/bridge_host.txt"
#define SALARY_CONFIG_FILE "/salary.txt"
#define ORIENTATION_CONFIG_FILE "/orientation.txt"

// ---- Salary clock ----
// China's statutory average monthly working days used for wage conversion.
#define SALARY_MONTHLY_WORKDAYS 21.75f
#define SALARY_DEFAULT_START_MIN 540
#define SALARY_DEFAULT_END_MIN 1080
#define SALARY_DEFAULT_LUNCH_START_MIN 720
#define SALARY_DEFAULT_LUNCH_END_MIN 780

// ---- Backlight ----
#define BRIGHTNESS_FILE "/brightness.txt"
#define BRIGHTNESS_DEFAULT 100
#define BRIGHTNESS_PWM_FREQ 2000 // Hz; high enough to avoid visible flicker when dim

// ---- Display layout (240x240 ST7789) ----
#define SCREEN_W 240
#define SCREEN_H 240
