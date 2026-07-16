#pragma once

// ---- Build profile ----
#ifndef AICLOCK_WIRED_ONLY
#define AICLOCK_WIRED_ONLY 0
#endif

// ---- Firmware version (shown on the first-time WiFi setup screen & /api/info) ----
#define FW_VERSION "0.5.5"

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

// ---- Backlight ----
#define BRIGHTNESS_FILE "/brightness.txt"
#define BRIGHTNESS_DEFAULT 100
#define BRIGHTNESS_PWM_FREQ 2000 // Hz; high enough to avoid visible flicker when dim

// ---- Display layout (240x240 ST7789) ----
#define SCREEN_W 240
#define SCREEN_H 240
