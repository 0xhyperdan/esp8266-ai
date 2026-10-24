#pragma once
#include <cstdint>

namespace PrinterMonitor {
struct ConfigPaths {
  const char *primary;
  const char *temporary;
  const char *backup;
};

template <typename FS>
bool removeArtifact(FS &fs, const char *path) {
  return !fs.exists(path) || fs.remove(path);
}

template <typename FS>
bool recoverPrimary(FS &fs, const ConfigPaths &paths) {
  if (fs.exists(paths.primary)) return true;
  return fs.exists(paths.backup) && fs.rename(paths.backup, paths.primary);
}

// Only call this after validating the authoritative primary. Both artifacts
// may contain credentials; failed cleanup must not be reported as success.
template <typename FS>
bool cleanJournal(FS &fs, const ConfigPaths &paths) {
  const bool temporaryRemoved = removeArtifact(fs, paths.temporary);
  const bool backupRemoved = removeArtifact(fs, paths.backup);
  return temporaryRemoved && backupRemoved;
}

template <typename FS>
bool prepareConfigSave(FS &fs, const ConfigPaths &paths) {
  if (!fs.exists(paths.primary) && fs.exists(paths.backup) &&
      !recoverPrimary(fs, paths)) return false;
  return cleanJournal(fs, paths);
}

template <typename FS>
bool commitConfigSave(FS &fs, const ConfigPaths &paths) {
  const bool previous = fs.exists(paths.primary);
  if (previous && !fs.rename(paths.primary, paths.backup)) {
    removeArtifact(fs, paths.temporary);
    return false;
  }
  if (fs.rename(paths.temporary, paths.primary)) return cleanJournal(fs, paths);
  if (previous) fs.rename(paths.backup, paths.primary);
  removeArtifact(fs, paths.temporary);
  return false;
}

inline uint8_t nextFailure(uint8_t failures) {
  return failures >= 4 ? 4 : failures + 1;
}

inline uint32_t reconnectDelayMs(uint8_t failures) {
  const uint8_t exponent = failures > 4 ? 4 : failures;
  const uint32_t delay = 5000UL << exponent;
  return delay > 60000UL ? 60000UL : delay;
}

struct StatusRequestSchedule {
  bool published = false;
  bool attempted = false;
  uint32_t lastSuccess = 0;
  uint32_t lastAttempt = 0;

  bool due(uint32_t now) const {
    return (!published || uint32_t(now - lastSuccess) >= 60000UL) &&
        (!attempted || uint32_t(now - lastAttempt) >= 5000UL);
  }

  void record(uint32_t now, bool success) {
    attempted = true;
    lastAttempt = now;
    if (success) {
      published = true;
      lastSuccess = now;
    }
  }
};
}  // namespace PrinterMonitor
