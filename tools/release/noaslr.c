// Runs a program with address space layout randomization disabled (as lldb launches programs).
// tools/release/build.sh runs the desktop runtime capture through it: gk stores native pointers in GOAL memory,
// and fixed addresses make the captured arena the same from run to run.
// Build: clang -O2 -o noaslr tools/release/noaslr.c
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

#ifndef _POSIX_SPAWN_DISABLE_ASLR
#define _POSIX_SPAWN_DISABLE_ASLR 0x0100
#endif

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: noaslr program [args...]\n");
        return 2;
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, _POSIX_SPAWN_DISABLE_ASLR);
    pid_t pid;
    int err = posix_spawn(&pid, argv[1], NULL, &attr, argv + 1, environ);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        fprintf(stderr, "noaslr: cannot run %s (error %d)\n", argv[1], err);
        return 2;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("noaslr: waitpid");
        return 2;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
