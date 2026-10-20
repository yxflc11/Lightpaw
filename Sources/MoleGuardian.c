/*
 * Owns one foreground Mole invocation and its dedicated process group.
 * IMPORTANT: stdin EOF can approve Mole uninstall. Keep the inner writer open
 * until the entire process group has been signalled and the leader reaped.
 * No shell expansion, credential collection, or signals to unrelated groups.
 */
#include <sys/types.h>
#include <sys/wait.h>
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted = 0;
static void request_stop(int signo) { interrupted = signo; }

static uint64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) _exit(125);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static int parse_positive(const char *text, long long maximum, long long *value) {
    char *end = NULL;
    errno = 0;
    long long result = strtoll(text, &end, 10);
    if (errno || !text[0] || !end || *end || result <= 0 || result > maximum) return -1;
    *value = result;
    return 0;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int child_has_exited(pid_t child) {
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    /* WNOWAIT deliberately pins the leader PID until ALL group signals finish. */
    if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) != 0)
        return errno == EINTR ? 0 : -1;
    return info.si_pid == child;
}

static int stop_and_reap_group(pid_t child, int inner_writer, int *status) {
    /* The leader is our unreaped child; its PID/PGID cannot have been reused. */
    if (child <= 1 || child == getpgrp()) _exit(125);
    (void)kill(-child, SIGTERM);
    uint64_t deadline = monotonic_ms() + 3000;
    while (monotonic_ms() < deadline) {
        struct timespec pause = {0, 10000000};
        (void)nanosleep(&pause, NULL);
    }
    (void)kill(-child, SIGKILL);
    pid_t waited;
    do { waited = waitpid(child, status, 0); } while (waited < 0 && errno == EINTR);
    /* Never move this close before the kill/wait sequence above. */
    close(inner_writer);
    return waited == child ? 0 : -1;
}

int main(int argc, char **argv) {
    long long parent_value = 0, timeout_value = 0;
    if (argc < 7 || strcmp(argv[1], "--parent-pid") || strcmp(argv[3], "--timeout-ms") ||
        strcmp(argv[5], "--") || argv[6][0] != '/' ||
        parse_positive(argv[2], INT_MAX, &parent_value) ||
        parse_positive(argv[4], 86400000, &timeout_value)) {
        fputs("MoleGuardian: invalid invocation\n", stderr);
        return 125;
    }
    const pid_t parent = (pid_t)parent_value;
    if (parent <= 1 || getppid() != parent) return 130;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    int input[2];
    if (pipe(input) != 0) return 125;
    fcntl(input[0], F_SETFD, FD_CLOEXEC);
    fcntl(input[1], F_SETFD, FD_CLOEXEC);
    pid_t child = fork();
    if (child < 0) { close(input[0]); close(input[1]); return 125; }
    if (child == 0) {
        if (setpgid(0, 0) != 0) _exit(125);
        close(input[1]);
        if (dup2(input[0], STDIN_FILENO) < 0) _exit(125);
        if (input[0] != STDIN_FILENO) close(input[0]);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        execv(argv[6], &argv[6]);
        fputs("MoleGuardian: cannot execute command\n", stderr);
        _exit(127);
    }
    close(input[0]);
    /* The child also does this before exec; either side can win the race. */
    int grouped = setpgid(child, child);
    if (grouped < 0 && getpgid(child) != child) {
        (void)kill(child, SIGKILL);
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        close(input[1]);
        return 125;
    }

    int reason = 0; /* 0 natural exit, 124 timeout, 130 cancellation, 125 error */
    if (set_nonblocking(STDIN_FILENO) || set_nonblocking(input[1])) reason = 125;
    unsigned char pending[65536];
    size_t count = 0;
    uint64_t deadline = monotonic_ms() + (uint64_t)timeout_value;
    while (!reason) {
        if (interrupted || getppid() != parent) { reason = 130; break; }
        if (monotonic_ms() >= deadline) { reason = 124; break; }
        int exited = child_has_exited(child);
        if (exited > 0) break;
        if (exited < 0) { reason = 125; break; }

        struct pollfd fds[2] = {
            {STDIN_FILENO, count < sizeof(pending) ? POLLIN : 0, 0},
            {input[1], count ? POLLOUT : 0, 0}
        };
        int ready = poll(fds, 2, 25);
        if (ready < 0) { if (errno == EINTR) continue; reason = 125; break; }
        if (interrupted || getppid() != parent) { reason = 130; break; }
        if ((fds[0].revents & (POLLIN | POLLHUP)) && count < sizeof(pending)) {
            ssize_t n = read(STDIN_FILENO, pending + count, sizeof(pending) - count);
            if (n == 0) { reason = 130; break; }
            if (n > 0) count += (size_t)n;
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                reason = 125; break;
            }
        }
        if (fds[0].revents & (POLLERR | POLLNVAL)) { reason = 130; break; }
        if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            /* A closed inner reader is not permission to close our writer. */
            if (child_has_exited(child) <= 0) reason = 125;
            break;
        }
        if (count && (fds[1].revents & POLLOUT)) {
            ssize_t n = write(input[1], pending, count);
            if (n > 0) { count -= (size_t)n; memmove(pending, pending + n, count); }
            else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                /* EPIPE means the reader exited; still clean its remaining group. */
                if (errno == EPIPE) break;
                reason = 125; break;
            }
        }
    }
    int status = 0;
    /* Also finish straggling background children after a natural main exit. */
    if (stop_and_reap_group(child, input[1], &status) != 0) return 125;
    if (reason) return reason;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}
