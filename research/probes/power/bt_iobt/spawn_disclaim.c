// spawn_disclaim.c — posix_spawn a child with responsibility disclaimed (private
// responsibility_spawnattrs_setdisclaim), so TCC attributes the child to itself, not to the terminal.
#include <spawn.h>
#include <stdio.h>
#include <dlfcn.h>
#include <sys/wait.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    posix_spawnattr_t a; posix_spawnattr_init(&a);
    int (*disclaim)(posix_spawnattr_t *, int) = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!disclaim) { printf("responsibility_spawnattrs_setdisclaim not found -> NOT running child (would attribute to terminal)\n"); return 3; }
    printf("disclaim rc=%d\n", disclaim(&a, 1)); fflush(stdout);
    pid_t pid; int rc = posix_spawn(&pid, argv[1], NULL, &a, argv + 1, environ);
    if (rc) { printf("posix_spawn failed %d\n", rc); return 4; }
    int st = 0; waitpid(pid, &st, 0);
    if (WIFSIGNALED(st)) printf("child killed by signal %d\n", WTERMSIG(st));
    else printf("child exit status %d\n", WEXITSTATUS(st));
    return 0;
}
