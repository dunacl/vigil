// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// Undocumented SkyLight (window server) calls used to pin a panel to a specific
// desktop (Space). Declared as function-pointer types only: Vigil resolves them
// with dlsym at runtime and never links SkyLight, so a missing symbol disables
// the "Desktop N" option instead of preventing launch. Verified on macOS 27.2.

#ifndef CVIGILSYS_SPACES_H
#define CVIGILSYS_SPACES_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef int32_t VigilCGSConnectionID;
typedef uint64_t VigilCGSSpaceID;

/// Space masks for SLSCopySpacesForWindows.
enum { VigilCGSSpaceMaskAll = 7 };

/// SLSMainConnectionID: the calling app's connection to the window server.
typedef VigilCGSConnectionID (*VigilSLSMainConnectionIDFn)(void);

/// SLSCopyManagedDisplaySpaces: array of per-display dictionaries with keys
/// "Display Identifier" (display UUID, or "Main" when displays share Spaces),
/// "Current Space" and "Spaces" (each with "ManagedSpaceID" and "type"; 0 = desktop).
typedef CFArrayRef _Nullable (*VigilSLSCopyManagedDisplaySpacesFn)(VigilCGSConnectionID cid);

/// SLSCopySpacesForWindows: space IDs (CFNumber) the given window numbers are on.
typedef CFArrayRef _Nullable (*VigilSLSCopySpacesForWindowsFn)(
    VigilCGSConnectionID cid, int32_t mask, CFArrayRef _Nonnull windowNumbers);

/// SLSMoveWindowsToManagedSpace: moves window numbers onto one space.
typedef void (*VigilSLSMoveWindowsToManagedSpaceFn)(
    VigilCGSConnectionID cid, CFArrayRef _Nonnull windowNumbers, VigilCGSSpaceID space);

#endif
