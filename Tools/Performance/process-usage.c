// macOS per-process counters; no injection, entitlement changes or polling in the app.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static double elapsed(struct timespec a, struct timespec b) {
    return (double)(b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char *tail;
    long pid = strtol(argv[1], &tail, 10);
    if (*tail || pid < 2 || pid > INT32_MAX) return 2;
    double seconds = strtod(argv[2], &tail);
    if (*tail || !(seconds >= 1 && seconds <= 60)) return 2;
    struct rusage_info_v6 a = {}, b = {};
    struct timespec start, end, delay = {
        .tv_sec = (time_t)seconds,
        .tv_nsec = (long)((seconds - (time_t)seconds) * 1e9)
    };
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&a)) {
        perror("proc_pid_rusage(start)"); return 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (nanosleep(&delay, &delay)) { if (errno != EINTR) return 1; }
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&b)) {
        perror("proc_pid_rusage(end)"); return 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (a.ri_proc_start_abstime != b.ri_proc_start_abstime) return 1;
    double duration = elapsed(start, end);
    uint64_t cpu = b.ri_user_time + b.ri_system_time - a.ri_user_time - a.ri_system_time;
    uint64_t energy = b.ri_energy_nj - a.ri_energy_nj;
    printf("{\"pid\":%ld,\"seconds\":%.6f,\"cpu_ns\":%" PRIu64
           ",\"cpu_percent_one_core\":%.4f,\"energy_nj\":%" PRIu64
           ",\"attributed_mW\":%.4f,\"footprint_start_bytes\":%" PRIu64
           ",\"footprint_end_bytes\":%" PRIu64 ",\"resident_end_bytes\":%" PRIu64
           ",\"idle_wakeups\":%" PRIu64 ",\"interrupt_wakeups\":%" PRIu64 "}\n",
           pid, duration, cpu, cpu / (duration * 1e7), energy, energy / (duration * 1e6),
           a.ri_phys_footprint, b.ri_phys_footprint, b.ri_resident_size,
           b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups, b.ri_interrupt_wkups - a.ri_interrupt_wkups);
    return 0;
}
