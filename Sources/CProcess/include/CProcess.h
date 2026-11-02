#ifndef CPROCESS_H
#define CPROCESS_H
#include <stdint.h>
int ng_process_ids(int32_t *ids, int capacity);
int ng_process_path(int32_t pid, char *buffer, int capacity);
int ng_process_arguments(int32_t pid, char *buffer, int capacity);
int ng_owned_process(int32_t pid);
int ng_network_bytes(uint64_t *up, uint64_t *down);
int ng_cpu_ticks(uint64_t *busy, uint64_t *total);
#endif
