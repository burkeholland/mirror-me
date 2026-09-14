//go:build windows && amd64 && !legacy_receiver

// SPDX-License-Identifier: GPL-3.0-or-later
#include "native/include/mirrorme.h"

extern void mmGoReceiverEvent(uintptr_t handle, int kind, char *message);

static void forward_event(void *context, int kind, const char *message) {
    mmGoReceiverEvent((uintptr_t)context, kind, (char *)message);
}

mm_receiver *mm_go_receiver_create(const mm_receiver_config *config, uintptr_t handle, char *error, size_t capacity) {
    return mm_receiver_create(config, forward_event, (void *)handle, error, capacity);
}
