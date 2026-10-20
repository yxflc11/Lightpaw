#ifndef CWM_MONITOR_H
#define CWM_MONITOR_H
#include <stdint.h>
#include <stddef.h>
typedef struct { int32_t pid, ppid; uint64_t seconds, micros; char name[256]; char path[4096]; } CWMProcess;
int cwm_list(CWMProcess **out, int *count, int *skipped);
void cwm_free(CWMProcess *items);
const char *cwm_path(const CWMProcess *p);
const char *cwm_name(const CWMProcess *p);
int cwm_identity(int pid, uint64_t seconds, uint64_t micros);
int cwm_footprint(int pid, uint64_t seconds, uint64_t micros, uint64_t *bytes);
int cwm_pressure(int *level);
int cwm_swap(uint64_t *used, uint64_t *total);
/* On-demand tool inspection. No argv or environment bytes cross this API. */
int cwm_validate_process(int pid, uint64_t sec, uint64_t us, int parent, const char *path);
int cwm_tool_kind(int pid, uint64_t sec, uint64_t us, int parent, int *kind);
int cwm_script_path(int pid, uint64_t sec, uint64_t us, int parent, const char *path, int argument_index, char *out, size_t capacity);
int cwm_working_directory(int pid, uint64_t sec, uint64_t us, int parent, const char *path, char *out, size_t capacity);
int cwm_terminate_chatcut(int pid, uint64_t sec, uint64_t us, int parent);
#endif
