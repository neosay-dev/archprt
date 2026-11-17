#pragma once

/// 1 when a debugger (StikDebug) attached to us, so QEMU's TCG can map executable memory.
int archprt_jit_enabled(void);

/// Loads the QEMU framework at `dylib` and runs it on its own thread.
/// `on_exit` gets QEMU's status (or -1 if it called exit()) from that thread. Returns 0 or an error string.
const char *archprt_qemu_start(const char *dylib, int argc, const char **argv, void (*on_exit)(int status));

/// Connects to a unix socket QEMU listens on; -1 if it is not there yet.
int archprt_connect(const char *path);
