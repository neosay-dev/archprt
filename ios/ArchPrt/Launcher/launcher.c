// QEMU runs in-process like in UTM (Services/UTMProcess.m): dlopen the framework, qemu_init + qemu_main_loop on a thread.
#include "launcher.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern char **environ;

int archprt_jit_enabled(void) {
    int flags = 0;
    return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED);
}

static int (*qemu_init)(int, const char **, const char **);
static void (*qemu_main_loop)(void);
static void (*qemu_cleanup)(void);
static pthread_t qemu_thread;
static void (*exit_cb)(int);
static int argc_copy;
static const char **argv_copy;

static void *run(void *unused) {
    int status = qemu_init(argc_copy, argv_copy, (const char **)environ);
    if (status == 0) {
        qemu_main_loop();
        qemu_cleanup();
    }
    exit_cb(status);
    return NULL;
}

const char *archprt_qemu_start(const char *dylib, int argc, const char **argv, void (*on_exit)(int)) {
    void *h = dlopen(dylib, RTLD_LOCAL);
    if (!h) return dlerror();
    qemu_init = dlsym(h, "qemu_init");
    qemu_main_loop = dlsym(h, "qemu_main_loop");
    qemu_cleanup = dlsym(h, "qemu_cleanup");
    if (!qemu_init || !qemu_main_loop || !qemu_cleanup) return "qemu_init/qemu_main_loop/qemu_cleanup not found";

    exit_cb = on_exit;
    argc_copy = argc;
    argv_copy = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) argv_copy[i] = strdup(argv[i]);

    // QEMU calls exit() on fatal errors and on guest poweroff: end only its thread, not the whole app.
    if (atexit_b(^{
            if (pthread_equal(pthread_self(), qemu_thread)) {
                exit_cb(-1);
                pthread_exit(NULL);
            }
        }) != 0)
        return "atexit_b failed";

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 8 << 20);
    if (pthread_create(&qemu_thread, &attr, run, NULL) != 0) return "pthread_create failed";
    return NULL;
}

int archprt_connect(const char *path) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof(addr.sun_path)) return -1;
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}
