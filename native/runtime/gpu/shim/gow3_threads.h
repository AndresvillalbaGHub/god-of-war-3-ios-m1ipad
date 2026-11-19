// SPDX-License-Identifier: GPL-2.0-or-later
// gow3: helper thread sizing. Counts follow the hardware threads this process may run on
// (the affinity mask, so `taskset` can emulate a Steam Deck), and speculative helpers run as
// SCHED_IDLE: they use cores the game leaves idle and never take time from its threads.

#pragma once

#include <algorithm>
#include <thread>
#ifdef _WIN32
#include <bit>
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
#include <sys/sysctl.h>
#include <TargetConditionals.h>
#else
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

namespace Gow3Threads {
#ifdef _WIN32
/// Hardware threads available to the process (its affinity mask).
inline unsigned Available() {
    DWORD_PTR process = 0, system = 0;
    if (GetProcessAffinityMask(GetCurrentProcess(), &process, &system) && process) {
        return std::max(1, std::popcount(static_cast<unsigned long long>(process)));
    }
    return std::max(1u, std::thread::hardware_concurrency());
}

inline unsigned PerformanceCores() {
    return Available();
}

inline unsigned EfficiencyCores() {
    return 0u;
}

inline void MakeInteractive() {}
inline void MakeInitiated() {}

/// The calling thread only runs when cores are otherwise idle (lowest Windows priority).
inline void MakeBackground() {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_IDLE);
}
#elif defined(__APPLE__)
// gow3 (iOS / M1): use sysctl perflevel topology (4P+4E on M1) and Darwin QoS classes so critical
// rendering/command threads stay on P-cores while speculative helpers run on E-cores at Utility QoS.
inline unsigned Available() {
    return std::max(1u, std::thread::hardware_concurrency());
}

inline unsigned SysctlCpuCount(const char* name) {
    int count = 0;
    size_t size = sizeof(count);
    if (sysctlbyname(name, &count, &size, nullptr, 0) == 0 && count > 0) {
        return static_cast<unsigned>(count);
    }
    return 0;
}

inline unsigned PerformanceCores() {
    static const unsigned p_cores = [] {
        if (const unsigned c = SysctlCpuCount("hw.perflevel0.logicalcpu")) {
            return c;
        }
        return std::max(1u, Available() / 2);
    }();
    return p_cores;
}

inline unsigned EfficiencyCores() {
    static const unsigned e_cores = [] {
        if (const unsigned c = SysctlCpuCount("hw.perflevel1.logicalcpu")) {
            return c;
        }
        const unsigned avail = Available();
        const unsigned perf = PerformanceCores();
        return avail > perf ? avail - perf : 0u;
    }();
    return e_cores;
}

/// Critical rendering/command threads: steer onto Apple Silicon Performance cores.
inline void MakeInteractive() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

/// High-priority worker threads that frames wait on (e.g. copy pool, tex bind helper).
inline void MakeInitiated() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
}

/// Speculative / background helpers: steer onto Apple Silicon Efficiency cores via Utility QoS.
inline void MakeBackground() {
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
}
#else

/// Hardware threads available to the process.
inline unsigned Available() {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        return std::max(1, CPU_COUNT(&set));
    }
    return std::max(1u, std::thread::hardware_concurrency());
}

inline unsigned PerformanceCores() {
    return Available();
}

inline unsigned EfficiencyCores() {
    return 0u;
}

inline void MakeInteractive() {}
inline void MakeInitiated() {}

/// The calling thread only runs on otherwise idle cores (falls back to the lowest nice level).
inline void MakeBackground() {
    sched_param param{};
    if (sched_setscheduler(0, SCHED_IDLE, &param) != 0) {
        setpriority(PRIO_PROCESS, static_cast<id_t>(gettid()), 19);
    }
}
#endif

} // namespace Gow3Threads
