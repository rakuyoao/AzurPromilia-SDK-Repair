#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { const WCHAR *text; int32_t length; } SdkText;
typedef struct { HWND window; SdkText argument; } SdkContext;
typedef void (*SdkCallback)(const SdkText *);
typedef struct { uint32_t kind, request, bytes; } Packet;
enum { CMD_INIT=1, CMD_LOGIN, CMD_LOGOUT, CMD_EXIT, CMD_EXTENSIVE, CMD_PURCHASE,
       CMD_QUERY, CMD_LOG, CMD_UNINIT, CMD_SET, CMD_GET, REPLY_VALUE=30, EVENT_BASE=100 };
static const char *commands[] = {NULL,"ManjuuSdk_Init","ManjuuSdk_Login","ManjuuSdk_Logout",
    "ManjuuSdk_Exit","ManjuuSdk_Extensive","ManjuuSdk_Purchase",
    "ManjuuSdk_QueryProductInfoList","ManjuuSdk_LogEvent","ManjuuSdk_UnInit"};
static const char *registrations[] = {"ManjuuSdk_RegisterInitCallback",
    "ManjuuSdk_RegisterLoginCallback","ManjuuSdk_RegisterLogoutCallback",
    "ManjuuSdk_RegisterExitCallback","ManjuuSdk_RegisterExtensiveCallback",
    "ManjuuSdk_RegisterPurchaseCallback","ManjuuSdk_RegisterQueryProductInfoListCallback",
    "ManjuuSdk_RegisterEventCallback"};
_Static_assert(offsetof(SdkContext, argument)==8,"SDK context ABI");
_Static_assert(offsetof(SdkContext, argument.length)==16,"SDK context text ABI");
_Static_assert(offsetof(SdkText, length)==8,"SDK callback ABI");

static BOOL transfer(HANDLE pipe, void *buffer, DWORD bytes, BOOL writing)
{
    BYTE *p=buffer;
    while(bytes) {
        DWORD n=0;
        BOOL ok=writing?WriteFile(pipe,p,bytes,&n,NULL):ReadFile(pipe,p,bytes,&n,NULL);
        if(!ok || !n) return FALSE;
        p+=n; bytes-=n;
    }
    return TRUE;
}

static BOOL send_packet(HANDLE pipe, CRITICAL_SECTION *lock, uint32_t kind, uint32_t request,
                        const void *payload, uint32_t bytes)
{
    if(bytes>1024*1024) return FALSE;
    Packet packet={kind,request,bytes};
    EnterCriticalSection(lock);
    BOOL ok=transfer(pipe,&packet,sizeof(packet),TRUE) && transfer(pipe,(void *)payload,bytes,TRUE);
    LeaveCriticalSection(lock);
    return ok;
}

static void *receive_packet(HANDLE pipe, Packet *packet)
{
    if(!transfer(pipe,packet,sizeof(*packet),FALSE) || packet->bytes>1024*1024) return NULL;
    void *p=calloc(1,packet->bytes+sizeof(WCHAR));
    if(!p || !transfer(pipe,p,packet->bytes,FALSE)) {free(p);return NULL;}
    return p;
}

static void make_names(DWORD pid, WCHAR *command, WCHAR *events)
{
    swprintf(command,128,L"\\\\.\\pipe\\AzurPromiliaSDK-%lu-commands",pid);
    swprintf(events,128,L"\\\\.\\pipe\\AzurPromiliaSDK-%lu-events",pid);
}
