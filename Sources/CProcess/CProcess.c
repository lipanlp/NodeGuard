#include "CProcess.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <string.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <mach/mach.h>
#include <pthread.h>
static pthread_once_t ng_host_once = PTHREAD_ONCE_INIT;
static mach_port_t ng_host_port = MACH_PORT_NULL;
static void ng_initialize_host(void) { ng_host_port = mach_host_self(); }
int ng_cpu_ticks(uint64_t *busy, uint64_t *total) {
    pthread_once(&ng_host_once, ng_initialize_host);
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(ng_host_port, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return 0;
    *busy = (uint64_t)info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_SYSTEM] + info.cpu_ticks[CPU_STATE_NICE];
    *total = *busy + info.cpu_ticks[CPU_STATE_IDLE];
    return 1;
}
int ng_network_bytes(uint64_t *up, uint64_t *down) {
    struct ifaddrs *interfaces = NULL; *up = 0; *down = 0; int count = 0;
    if (getifaddrs(&interfaces) != 0) return 0;
    for (struct ifaddrs *p = interfaces; p != NULL; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data || !(p->ifa_flags & IFF_UP) || strncmp(p->ifa_name, "en", 2) != 0) continue;
        struct if_data *data = p->ifa_data;
        *up += data->ifi_obytes; *down += data->ifi_ibytes; count++;
    }
    freeifaddrs(interfaces); return count;
}
int ng_process_ids(int32_t *ids, int capacity) { return proc_listallpids(ids, capacity * sizeof(int32_t)); }
int ng_process_path(int32_t pid, char *buffer, int capacity) { return proc_pidpath(pid, buffer, (uint32_t)capacity); }
int ng_owned_process(int32_t pid) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return n == sizeof(info) && info.pbi_uid == getuid();
}
int ng_process_arguments(int32_t pid, char *buffer, int capacity) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t n = (size_t)capacity;
    if (sysctl(mib, 3, buffer, &n, NULL, 0) != 0 || n <= sizeof(int)) return 0;
    int argc = 0; memcpy(&argc, buffer, sizeof(int));
    // Return argv only; never expose the environment section that can contain tokens.
    size_t i = sizeof(int);
    while (i < n && buffer[i]) i++;
    while (i < n && !buffer[i]) i++;
    size_t start = i;
    for (int j = 0; j < argc && i < n; j++) {
        while (i < n && buffer[i]) i++;
        if (i < n) i++;
    }
    size_t count = i - start; memmove(buffer, buffer + start, count);
    return (int)count;
}
