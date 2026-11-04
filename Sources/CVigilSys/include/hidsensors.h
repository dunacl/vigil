// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// IOHIDEventSystemClient temperature sensors (undocumented; SPEC §11). Declared
// as function-pointer types and resolved with dlsym, so their absence disables
// temperature reading instead of preventing launch.

#ifndef CVIGILSYS_HIDSENSORS_H
#define CVIGILSYS_HIDSENSORS_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef CFTypeRef _Nullable (*VigilHIDClientCreateFn)(CFAllocatorRef _Nullable allocator);
typedef int32_t (*VigilHIDClientSetMatchingFn)(CFTypeRef _Nonnull client, CFDictionaryRef _Nonnull matching);
typedef CFArrayRef _Nullable (*VigilHIDClientCopyServicesFn)(CFTypeRef _Nonnull client);
typedef CFTypeRef _Nullable (*VigilHIDServiceCopyPropertyFn)(CFTypeRef _Nonnull service, CFStringRef _Nonnull key);
typedef CFTypeRef _Nullable (*VigilHIDServiceCopyEventFn)(
    CFTypeRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp);
typedef double (*VigilHIDEventGetFloatValueFn)(CFTypeRef _Nonnull event, int32_t field);

enum {
    /// HID usage page/usage that marks temperature sensors.
    VigilHIDTemperatureUsagePage = 0xff00,
    VigilHIDTemperatureUsage = 5,
    /// kIOHIDEventTypeTemperature, and its value field (type << 16).
    VigilHIDEventTypeTemperature = 15,
    VigilHIDTemperatureLevelField = 15 << 16,
};

#endif
