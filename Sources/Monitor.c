#include "Monitor.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

static int info(int pid, struct proc_bsdinfo *b) {
    errno=0;
    int n=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,b,sizeof(*b));
    return n==(int)sizeof(*b) ? 0 : (errno ? errno : ESRCH);
}
int cwm_list(CWMProcess **out,int *count,int *skipped) {
    *out=NULL; *count=0; *skipped=0;
    int capacity=proc_listallpids(NULL,0);
    if(capacity<=0) return errno ? errno : EIO;
    capacity+=256;
    if(capacity>131072) return EOVERFLOW;
    pid_t *pids=calloc(capacity,sizeof(pid_t));
    CWMProcess *items=calloc(capacity,sizeof(CWMProcess));
    if(!pids||!items) { free(pids); free(items); return ENOMEM; }
    int n=proc_listallpids(pids,capacity*sizeof(pid_t));
    if(n<=0||n>=capacity) { free(pids);free(items);return n>=capacity?EAGAIN:(errno?errno:EIO); }
    for(int i=0;i<n;i++) {
        if(pids[i]<=0) continue;
        struct proc_bsdinfo b;
        if(info(pids[i],&b)) { (*skipped)++;continue; }
        CWMProcess *p=&items[*count];
        p->pid=pids[i];p->ppid=b.pbi_ppid;p->seconds=b.pbi_start_tvsec;p->micros=b.pbi_start_tvusec;
        strlcpy(p->name,b.pbi_name[0]?b.pbi_name:b.pbi_comm,sizeof(p->name));
        if(proc_pidpath(pids[i],p->path,sizeof(p->path))<=0) p->path[0]=0;
        (*count)++;
    }
    free(pids);*out=items;return 0;
}
void cwm_free(CWMProcess *p) { free(p); }
const char *cwm_path(const CWMProcess *p) { return p->path; }
const char *cwm_name(const CWMProcess *p) { return p->name; }
int cwm_identity(int pid,uint64_t sec,uint64_t us) {
    struct proc_bsdinfo b;int e=info(pid,&b);if(e)return e;
    return (b.pbi_start_tvsec==sec&&b.pbi_start_tvusec==us)?0:EAGAIN;
}
int cwm_footprint(int pid,uint64_t sec,uint64_t us,uint64_t *bytes) {
    *bytes=0;int e=cwm_identity(pid,sec,us);if(e)return e;
    struct rusage_info_v4 r;memset(&r,0,sizeof(r));errno=0;
    if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&r)!=0)return errno?errno:EIO;
    e=cwm_identity(pid,sec,us);if(e)return e;
    *bytes=r.ri_phys_footprint;return 0;
}
int cwm_pressure(int *level) {
    *level=-1;size_t n=sizeof(*level);
    if(sysctlbyname("kern.memorystatus_vm_pressure_level",level,&n,NULL,0)!=0)return errno?errno:EIO;
    return n==sizeof(*level)?0:EIO;
}
int cwm_swap(uint64_t *used,uint64_t *total) {
    struct xsw_usage x;size_t n=sizeof(x);*used=0;*total=0;
    if(sysctlbyname("vm.swapusage",&x,&n,NULL,0)!=0)return errno?errno:EIO;
    if(n!=sizeof(x))return EIO;
    *used=x.xsu_used;*total=x.xsu_total;return 0;
}

static const char *chatcut_executable = "/Applications/ChatCut.app/Contents/MacOS/ChatCut";
static const char *chatcut_script = "/Applications/ChatCut.app/Contents/Resources/app.asar/out/main/mcp/server.js";

int cwm_validate_process(int pid,uint64_t sec,uint64_t us,int parent,const char *path) {
    struct proc_bsdinfo b; int e=info(pid,&b); if(e)return e;
    if(b.pbi_start_tvsec!=sec||b.pbi_start_tvusec!=us||b.pbi_ppid!=(uint32_t)parent)return EAGAIN;
    char actual[PROC_PIDPATHINFO_MAXSIZE];
    if(proc_pidpath(pid,actual,sizeof(actual))<=0)return errno?errno:ESRCH;
    if(!path||strcmp(actual,path))return EINVAL;
    return cwm_identity(pid,sec,us);
}

int cwm_script_path(int pid,uint64_t sec,uint64_t us,int parent,const char *path,int argument_index,char *out,size_t capacity) {
    if(!out||capacity==0||capacity>4096||(argument_index!=1&&argument_index!=2))return EINVAL;
    out[0]=0;
    int e=cwm_validate_process(pid,sec,us,parent,path); if(e)return e;
    int mib[3]={CTL_KERN,KERN_PROCARGS2,pid}; size_t size=0;
    if(sysctl(mib,3,NULL,&size,NULL,0)!=0)return errno?errno:EIO;
    if(size<sizeof(int)||size>1024*1024)return EOVERFLOW;
    const size_t allocated=size;
    unsigned char *buffer=malloc(allocated); if(!buffer)return ENOMEM;
    if(sysctl(mib,3,buffer,&size,NULL,0)!=0)e=errno?errno:EIO;
    else if(size<sizeof(int)||size>allocated)e=EOVERFLOW;
    else {
        int argc=0; memcpy(&argc,buffer,sizeof(argc));
        size_t at=sizeof(argc);
        /* Kernel transport also carries environment. Inspect only executable,
           argv[0] and argv[1]; never parse, copy, return or log environment. */
        while(at<size&&buffer[at])at++;
        while(at<size&&!buffer[at])at++;
        if(argc<=argument_index||at>=size)e=EINVAL;
        else {
            for(int index=0;index<argument_index&&at<size;index++) {
                while(at<size&&buffer[at])at++;
                if(at<size)at++;
            }
            if(at>=size)e=EINVAL;
            else {
                size_t begin=at;
                while(at<size&&buffer[at])at++;
                if(at>=size)e=EINVAL;
                else if(at-begin>=capacity)e=EOVERFLOW;
                else { memcpy(out,buffer+begin,at-begin); out[at-begin]=0; }
            }
        }
    }
    /* Do not leave the kernel transport (which can include secrets) retained. */
    volatile unsigned char *wipe=buffer;
    for(size_t i=0;i<allocated;i++)wipe[i]=0;
    free(buffer);
    if(!e)e=cwm_validate_process(pid,sec,us,parent,path);
    if(e)out[0]=0;
    return e;
}

int cwm_tool_kind(int pid,uint64_t sec,uint64_t us,int parent,int *kind) {
    if(!kind)return EINVAL;
    *kind=0;
    char script[4096];
    int e=cwm_script_path(pid,sec,us,parent,chatcut_executable,1,script,sizeof(script));
    if(e)return e;
    if(!strcmp(script,chatcut_script))*kind=1;
    return 0;
}

int cwm_working_directory(int pid,uint64_t sec,uint64_t us,int parent,const char *path,char *out,size_t capacity) {
    if(!out||capacity==0||capacity>4096)return EINVAL;
    out[0]=0;
    int e=cwm_validate_process(pid,sec,us,parent,path); if(e)return e;
    struct proc_vnodepathinfo vnode;
    memset(&vnode,0,sizeof(vnode)); errno=0;
    int count=proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&vnode,sizeof(vnode));
    if(count!=(int)sizeof(vnode))return errno?errno:ESRCH;
    size_t length=strnlen(vnode.pvi_cdir.vip_path,sizeof(vnode.pvi_cdir.vip_path));
    if(length==0||length>=capacity)return EOVERFLOW;
    e=cwm_validate_process(pid,sec,us,parent,path); if(e)return e;
    memcpy(out,vnode.pvi_cdir.vip_path,length); out[length]=0;
    return 0;
}

int cwm_terminate_chatcut(int pid,uint64_t sec,uint64_t us,int parent) {
    int kind=0; int e=cwm_tool_kind(pid,sec,us,parent,&kind);
    if(e)return e;
    if(kind!=1)return EINVAL;
    /* Repeat birthtime immediately before the only permitted signal. */
    e=cwm_identity(pid,sec,us); if(e)return e;
    return kill(pid,SIGTERM)==0?0:(errno?errno:EIO);
}
