#include "printer_monitor.h"
#include "printer_monitor_parser.h"
#include "printer_monitor_recovery.h"
#include "printer_bridge_parser.h"

#include <ArduinoJson.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(ARDUINO_ARCH_ESP32)
#include <LittleFS.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#endif

namespace PrinterMonitor {
namespace {

Config globalConfig;
Snapshot globalSnapshot;

void initializeSnapshot(Snapshot &value) {
  value = Snapshot{};
  value.supported = false;
  value.configured = false;
  value.enabled = false;
  value.connected = false;
  value.stale = false;
  value.progressKnown = false;
  value.remainingKnown = false;
  value.nozzleKnown = false;
  value.bedKnown = false;
  value.layersKnown = false;
  value.progress = 0;
  value.remainingMinutes = 0;
  value.layer = 0;
  value.totalLayers = 0;
  value.nozzle = 0.0f;
  value.nozzleTarget = 0.0f;
  value.bed = 0.0f;
  value.bedTarget = 0.0f;
  value.state[0] = '\0';
  value.job[0] = '\0';
  value.error[0] = '\0';
}

#if defined(ARDUINO_ARCH_ESP32)

constexpr const char *kConfigPath = "/printer.json";
constexpr const char *kConfigTempPath = "/printer.json.tmp";
constexpr const char *kConfigBackupPath = "/printer.json.bak";
constexpr ConfigPaths kConfigPaths{kConfigPath, kConfigTempPath, kConfigBackupPath};
constexpr uint32_t kStaleTimeoutMs = 60000;
constexpr uint32_t kMinimumReconnectMs = 5000;
constexpr uint16_t kMqttPort = 8883;
constexpr uint16_t kMqttBufferSize = 40960;
constexpr uint16_t kNetworkTimeoutSeconds = 10;
bool filesystemReady = false;

bool isComplete(const Config &config) {
  return config.host[0] != '\0' && config.serial[0] != '\0' &&
         config.accessCode[0] != '\0';
}

void copyConfig(Config &destination, const Config &source) {
  destination.enabled = source.enabled;
  destination.allowSelfSigned = source.allowSelfSigned;
  copyText(destination.host, sizeof(destination.host), source.host);
  copyText(destination.serial, sizeof(destination.serial), source.serial);
  copyText(destination.accessCode, sizeof(destination.accessCode), source.accessCode);
}

bool validAsciiWord(const char *text, size_t minimum, size_t maximum, bool allowDash) {
  if (text == nullptr) return false;
  size_t length = 0;
  for (; text[length] != '\0'; ++length) {
    const unsigned char value = static_cast<unsigned char>(text[length]);
    const bool valid = (value >= '0' && value <= '9') ||
                       (value >= 'A' && value <= 'Z') ||
                       (value >= 'a' && value <= 'z') ||
                       (allowDash && value == '-');
    if (!valid) return false;
  }
  return length >= minimum && length <= maximum;
}

bool isPrivateLanIPv4(const char *text) {
  if (text == nullptr) return false;

  int octets[4] = {};
  int octetCount = 0;
  int digitCount = 0;
  int value = 0;

  for (size_t index = 0;; ++index) {
    const char character = text[index];
    if (character >= '0' && character <= '9') {
      if (digitCount == 0 && character == '0' && text[index + 1] >= '0' &&
          text[index + 1] <= '9') {
        return false;
      }
      value = value * 10 + (character - '0');
      if (value > 255) return false;
      ++digitCount;
      continue;
    }

    const bool separatorOrEnd = character == '.' || character == '\0';
    if (!separatorOrEnd || digitCount == 0 || digitCount > 3) return false;
    octets[octetCount++] = value;
    value = 0;
    digitCount = 0;
    if (character == '\0') break;
    if (octetCount == 4) return false;
  }
  if (octetCount != 4) return false;

  return (octets[0] == 10) ||
         (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
         (octets[0] == 192 && octets[1] == 168);
}

bool validAccessCode(const char *text) {
  if (text == nullptr) return false;
  size_t length = 0;
  for (; text[length] != '\0'; ++length) {
    const unsigned char value = static_cast<unsigned char>(text[length]);
    if (value <= 0x20 || value >= 0x7f) return false;
  }
  return length >= 8 && length <= 64;
}

bool validateConfig(const Config &config, String &error, bool activeConfig) {
  const bool blank = config.host[0] == '\0' && config.serial[0] == '\0' &&
                     config.accessCode[0] == '\0';
  if (blank && !config.enabled) return true;

  if (config.host[0] != '\0' && !isPrivateLanIPv4(config.host)) {
    error = F("Printer host must be a private LAN IPv4 address");
    return false;
  }
  if (config.serial[0] != '\0' &&
      !validAsciiWord(config.serial, 1, 32, true)) {
    error = F("Printer serial must contain 1-32 letters, digits, or dashes");
    return false;
  }
  if (config.accessCode[0] != '\0' && !validAccessCode(config.accessCode)) {
    error = F("Access code must contain 8-64 non-space ASCII characters");
    return false;
  }

  if (!activeConfig) return true;
  if (config.host[0] == '\0' || config.serial[0] == '\0' ||
      config.accessCode[0] == '\0') {
    error = F("Printer host, serial, and access code are required");
    return false;
  }
  if (!config.allowSelfSigned) {
    error = F("Explicit consent is required for the printer's self-signed certificate");
    return false;
  }
  return true;
}

SemaphoreHandle_t stateMutex = nullptr;
TaskHandle_t workerTask = nullptr;
volatile uint32_t configVersion = 0;

WiFiClientSecure tlsClient;
PubSubClient mqttClient;
ParserState workerParser;
Config activeConfig;
uint32_t activeConfigVersion = 0;
uint32_t lastDataMs = 0;
uint32_t nextReconnectMs = 0;
uint8_t reconnectFailures = 0;
StatusRequestSchedule requestSchedule;
bool activeConfigInitialized = false;
bool workerConnected = false;

void lockState() {
  if (stateMutex != nullptr) xSemaphoreTake(stateMutex, portMAX_DELAY);
}

void unlockState() {
  if (stateMutex != nullptr) xSemaphoreGive(stateMutex);
}

bool elapsed(uint32_t now, uint32_t since, uint32_t interval) {
  return static_cast<uint32_t>(now - since) >= interval;
}

void readConfigFromJson(const JsonDocument &document, Config &config) {
  JsonVariantConst host = document["host"];
  JsonVariantConst serial = document["serial"];
  JsonVariantConst accessCode = document["access_code"];
  if (host.is<const char *>()) {
    copyText(config.host, sizeof(config.host), host.as<const char *>());
  }
  if (serial.is<const char *>()) {
    copyText(config.serial, sizeof(config.serial), serial.as<const char *>());
  }
  if (accessCode.is<const char *>()) {
    copyText(config.accessCode, sizeof(config.accessCode),
             accessCode.as<const char *>());
  }
  config.enabled = document["enabled"].is<bool>() &&
                   document["enabled"].as<bool>();
  config.allowSelfSigned = document["allow_self_signed"].is<bool>() &&
                           document["allow_self_signed"].as<bool>();
}

bool loadConfig(Config &config) {
  config = Config{};
  if (!filesystemReady) return false;
  if (!recoverPrimary(LittleFS, kConfigPaths)) {
    removeArtifact(LittleFS, kConfigTempPath);
    return false;
  }

  File file = LittleFS.open(kConfigPath, "r");
  if (!file) return false;

  JsonDocument document;
  const DeserializationError result = deserializeJson(document, file);
  file.close();
  if (result != DeserializationError::Ok) return false;

  readConfigFromJson(document, config);
  String validationError;
  return validateConfig(config, validationError, config.enabled) &&
      cleanJournal(LittleFS, kConfigPaths);
}

bool saveConfig(const Config &config) {
  if (!filesystemReady) return false;
  if (!prepareConfigSave(LittleFS, kConfigPaths)) return false;

  File file = LittleFS.open(kConfigTempPath, "w");
  if (!file) return false;

  JsonDocument document;
  document["enabled"] = config.enabled;
  document["allow_self_signed"] = config.allowSelfSigned;
  document["host"] = config.host;
  document["serial"] = config.serial;
  document["access_code"] = config.accessCode;
  const size_t written = serializeJson(document, file);
  file.flush();
  const bool complete = written == measureJson(document) && file.size() == written;
  file.close();
  if (!complete) {
    LittleFS.remove(kConfigTempPath);
    return false;
  }

  return commitConfigSave(LittleFS, kConfigPaths);
}

void setDisconnected(const char *error) {
  if (mqttClient.connected()) mqttClient.disconnect();
  tlsClient.stop();
  workerConnected = false;

  lockState();
  globalSnapshot.connected = false;
  if (error != nullptr) copyText(globalSnapshot.error,
                                 sizeof(globalSnapshot.error), error);
  unlockState();
}

void publishPushall(const Config &config, uint32_t now) {
  if (!mqttClient.connected()) return;
  if (!requestSchedule.due(now)) return;

  char topic[64] = {};
  snprintf(topic, sizeof(topic), "device/%s/request", config.serial);
  char payload[128] = {};
  static uint32_t sequence = 0;
  snprintf(payload, sizeof(payload),
           "{\"pushing\":{\"sequence_id\":\"%lu\",\"command\":\"pushall\","
           "\"version\":1,\"push_target\":1}}",
           static_cast<unsigned long>(sequence++));

  const bool sent = mqttClient.publish(topic, payload);
  requestSchedule.record(now, sent);
  if (!sent) {
    setDisconnected("Status request failed");
    nextReconnectMs = now + kMinimumReconnectMs;
    reconnectFailures = nextFailure(reconnectFailures);
  }
}

void mqttCallback(char *topic, byte *payload, unsigned int length) {
  if (length == 0 || length > kMqttBufferSize) return;
  char expected[64];
  snprintf(expected, sizeof(expected), "device/%s/report", activeConfig.serial);
  if (!topic || strcmp(topic, expected)) return;

  Snapshot candidate;
  uint32_t version = 0;
  lockState();
  if (configVersion != activeConfigVersion) {
    unlockState();
    return;
  }
  candidate = globalSnapshot;
  version = configVersion;
  unlockState();

  if (!parseReport(reinterpret_cast<const char *>(payload), length, candidate,
                   workerParser)) {
    return;
  }

  candidate.connected = true;
  candidate.stale = false;

  lockState();
  if (version != configVersion) {
    unlockState();
    return;
  }
  const uint32_t now = millis();
  lastDataMs = now;
  globalSnapshot = candidate;
  globalSnapshot.connected = true;
  globalSnapshot.stale = false;
  unlockState();
}

uint32_t reconnectDelay() {
  return reconnectDelayMs(reconnectFailures);
}

bool deadlineReached(uint32_t now, uint32_t deadline) {
  return static_cast<int32_t>(now - deadline) >= 0;
}

bool connectPrinter(const Config &config) {
  if (!config.allowSelfSigned) {
    setDisconnected("TLS certificate consent required");
    return false;
  }

  tlsClient.stop();
  tlsClient.setInsecure();
  tlsClient.setTimeout(kNetworkTimeoutSeconds);
  tlsClient.setHandshakeTimeout(5);

  mqttClient.setClient(tlsClient);
  mqttClient.setServer(config.host, kMqttPort);
  mqttClient.setCallback(mqttCallback);
  mqttClient.setKeepAlive(kNetworkTimeoutSeconds);
  mqttClient.setSocketTimeout(kNetworkTimeoutSeconds);
  if (!mqttClient.setBufferSize(kMqttBufferSize)) {
    setDisconnected("Insufficient memory for MQTT");
    return false;
  }

  char clientId[48] = {};
  snprintf(clientId, sizeof(clientId), "ai-clock-%012llx",
           static_cast<unsigned long long>(ESP.getEfuseMac() & 0x0000ffffffffffffULL));
  if (!mqttClient.connect(clientId, "bblp", config.accessCode)) {
    setDisconnected("MQTT connection failed");
    return false;
  }

  char reportTopic[64] = {};
  snprintf(reportTopic, sizeof(reportTopic), "device/%s/report", config.serial);
  if (!mqttClient.subscribe(reportTopic)) {
    setDisconnected("MQTT subscription failed");
    if (mqttClient.connected()) mqttClient.disconnect();
    tlsClient.stop();
    return false;
  }

  workerConnected = true;
  lockState();
  if (activeConfigVersion != configVersion || !globalConfig.enabled) {
    unlockState();
    setDisconnected(nullptr);
    return false;
  }
  globalSnapshot.connected = true;
  globalSnapshot.error[0] = '\0';
  unlockState();
  return true;
}

void resetDataState() {
  lockState();
  lastDataMs = 0;
  unlockState();
  resetParserState(workerParser);
}

void handleConfigChange(const Config &config, uint32_t version) {
  setDisconnected(nullptr);
  mqttClient.setBufferSize(512);
  activeConfig = config;
  activeConfigVersion = version;
  activeConfigInitialized = true;
  reconnectFailures = 0;
  nextReconnectMs = millis() + kMinimumReconnectMs;
  requestSchedule = StatusRequestSchedule{};
  resetDataState();
}

void workerTaskFunction(void *argument) {
  (void)argument;

  for (;;) {
    Config config;
    uint32_t version = 0;
    lockState();
    copyConfig(config, globalConfig);
    version = configVersion;
    unlockState();

    if (!activeConfigInitialized || version != activeConfigVersion) {
      handleConfigChange(config, version);
    }

    if (!config.enabled || !isComplete(config)) {
      if (workerConnected) setDisconnected(nullptr);
      vTaskDelay(pdMS_TO_TICKS(250));
      continue;
    }

    const uint32_t now = millis();
    if (WiFi.status() != WL_CONNECTED) {
      setDisconnected("Wi-Fi unavailable");
      nextReconnectMs = now + reconnectDelay();
      reconnectFailures = nextFailure(reconnectFailures);
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }

    if (!mqttClient.connected()) {
      if (workerConnected) {
        setDisconnected("Printer connection lost");
      }
      if (!deadlineReached(now, nextReconnectMs)) {
        vTaskDelay(pdMS_TO_TICKS(50));
        continue;
      }

      if (connectPrinter(config)) {
        reconnectFailures = 0;
        publishPushall(config, millis());
      } else {
        nextReconnectMs = millis() + reconnectDelay();
        reconnectFailures = nextFailure(reconnectFailures);
      }
      continue;
    }

    mqttClient.loop();
    if (!mqttClient.connected()) {
      setDisconnected("Printer connection lost");
      nextReconnectMs = millis() + reconnectDelay();
      reconnectFailures = nextFailure(reconnectFailures);
      continue;
    }

    publishPushall(config, millis());
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

void ensureState() {
  if (stateMutex == nullptr) stateMutex = xSemaphoreCreateMutex();
}

void startWorker() {
  ensureState();
  if (workerTask != nullptr) return;
  if (stateMutex == nullptr) return;
  if (xTaskCreate(workerTaskFunction, "printer-monitor", 12288, nullptr, 1,
                  &workerTask) != pdPASS) {
    workerTask = nullptr;
    lockState();
    copyText(globalSnapshot.error, sizeof(globalSnapshot.error),
             "Unable to start monitor task");
    unlockState();
  }
}

#endif

}  // namespace

#if defined(ARDUINO_ARCH_ESP32)

void begin(bool ready) {
  ensureState();
  filesystemReady = ready;

  Config loadedConfig;
  if (loadConfig(loadedConfig)) {
    lockState();
    copyConfig(globalConfig, loadedConfig);
    initializeSnapshot(globalSnapshot);
    globalSnapshot.supported = true;
    globalSnapshot.configured = isComplete(globalConfig);
    globalSnapshot.enabled = globalConfig.enabled;
    ++configVersion;
    unlockState();
    if (globalConfig.enabled) startWorker();
  } else {
    lockState();
    initializeSnapshot(globalSnapshot);
    globalSnapshot.supported = true;
    unlockState();
  }
}

Snapshot snapshot() {
  ensureState();

  Config config;
  Snapshot result;
  uint32_t dataMs = 0;
  lockState();
  copyConfig(config, globalConfig);
  result = globalSnapshot;
  dataMs = lastDataMs;
  unlockState();

  const uint32_t now = millis();
  result.supported = true;
  result.configured = isComplete(config);
  result.enabled = config.enabled;
  result.connected = result.connected && result.enabled && result.configured;
  result.stale = dataMs != 0 && elapsed(now, dataMs, kStaleTimeoutMs);

  if (!result.configured) {
    copyText(result.error, sizeof(result.error), "Not configured");
  } else if (!result.enabled) {
    copyText(result.error, sizeof(result.error), "Disabled");
  } else if (!result.connected) {
    if (result.error[0] == '\0') {
      copyText(result.error, sizeof(result.error), "Disconnected");
    }
  } else if (dataMs == 0) {
    copyText(result.error, sizeof(result.error), "Waiting for printer data");
  } else if (result.stale) {
    copyText(result.error, sizeof(result.error), "Printer data is stale");
  }

  return result;
}

Config configuration() {
  ensureState();
  Config result;
  lockState();
  copyConfig(result, globalConfig);
  unlockState();
  return result;
}

bool configure(const Config &config, String &error) {
  ensureState();

  Config candidate;
  copyConfig(candidate, config);
  if (!validateConfig(candidate, error, candidate.enabled)) return false;
  if (!filesystemReady || !saveConfig(candidate)) {
    error = F("Unable to save printer configuration");
    return false;
  }

  lockState();
  copyConfig(globalConfig, candidate);
  initializeSnapshot(globalSnapshot);
  globalSnapshot.supported = true;
  globalSnapshot.configured = isComplete(candidate);
  globalSnapshot.enabled = candidate.enabled;
  lastDataMs = 0;
  ++configVersion;
  unlockState();

  if (candidate.enabled) startWorker();
  return true;
}

bool clear(String &error) {
  ensureState();

  const Config emptyConfig = Config{};
  if (!filesystemReady || !saveConfig(emptyConfig)) {
    error = F("Unable to clear persisted printer configuration");
    return false;
  }

  lockState();
  copyConfig(globalConfig, emptyConfig);
  initializeSnapshot(globalSnapshot);
  globalSnapshot.supported = true;
  lastDataMs = 0;
  ++configVersion;
  unlockState();
  return true;
}

void poll() {
  // Networking is paced by the dedicated task, not the display loop.
}

bool ingestBridge(const char *, size_t) { return false; }

#else

uint32_t lastBridgePacketMs = 0;
bool bridgeReceived = false;

void begin(bool ready) {
  (void)ready;
  globalConfig = Config{};
  initializeSnapshot(globalSnapshot);
  globalSnapshot.supported = true;
  bridgeReceived = false;
}

Snapshot snapshot() {
  return bridgeSnapshotAt(globalSnapshot, bridgeReceived, lastBridgePacketMs, millis());
}

Config configuration() { return Config{}; }

bool configure(const Config &config, String &error) {
  (void)config;
  error = F("Configure printer credentials in the Mac bridge");
  return false;
}

bool clear(String &error) {
  (void)error;
  globalConfig = Config{};
  initializeSnapshot(globalSnapshot);
  return true;
}

void poll() {}

bool ingestBridge(const char *payload, size_t length) {
#if defined(ARDUINO_ARCH_ESP8266)
  Snapshot candidate;
  if (!parseBridgeSnapshot(payload, length, candidate)) return false;
  globalSnapshot = candidate;
  lastBridgePacketMs = millis();
  bridgeReceived = true;
  return true;
#else
  (void)payload;
  (void)length;
  return false;
#endif
}

#endif

}  // namespace PrinterMonitor
