#pragma once
#include <cstddef>

// Minimal Arduino surface for host-only report parser and unsupported stub tests.
class String {
 public:
  String() {}
  String(const char *value) { (void)value; }
  String &operator=(const char *value) { (void)value; return *this; }
};
#define F(x) x
inline unsigned long millis() { return 0; }
