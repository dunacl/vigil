// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
//
// CVigilSys: declarations and tiny inline shims only. No logic lives here.
// Undocumented interfaces are declared as function-pointer typedefs and
// resolved with dlsym at runtime (spaces.h, hidsensors.h; smc.h is a struct layout).

#ifndef CVIGILSYS_H
#define CVIGILSYS_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <net/if.h>
#include <net/route.h>
#include <mach/mach.h>

#include "spaces.h"
#include "smc.h"
#include "hidsensors.h"

#endif
