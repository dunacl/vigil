// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// The AppleSMC user-client call layout (undocumented; SPEC §11). The struct must
// be exactly 80 bytes with C natural alignment, which is why it's declared in C.
// Used only when the user turns on sensor reading. Verified on macOS 27.2 (M5 Pro).

#ifndef CVIGILSYS_SMC_H
#define CVIGILSYS_SMC_H

#include <stdint.h>

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} VigilSMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} VigilSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} VigilSMCKeyInfoData;

typedef struct {
    uint32_t key;
    VigilSMCVersion vers;
    VigilSMCPLimitData pLimitData;
    VigilSMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} VigilSMCParamStruct;

enum {
    /// IOConnectCallStructMethod selector for every SMC request.
    VigilSMCHandleYPCEvent = 2,
    /// `data8` commands.
    VigilSMCReadKey = 5,
    VigilSMCGetKeyInfo = 9,
};

_Static_assert(sizeof(VigilSMCParamStruct) == 80, "SMC struct layout changed");

#endif
