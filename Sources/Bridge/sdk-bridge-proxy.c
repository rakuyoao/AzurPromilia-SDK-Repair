#include "sdk-bridge.h"
#include <stdbool.h>
#include <wctype.h>

typedef struct CallbackItem { uint32_t index, bytes; WCHAR text[]; } CallbackItem;
static HMODULE self;
static HANDLE command_pipe, event_pipe, value_ready, host_process;
static CRITICAL_SECTION command_lock, value_lock;
static INIT_ONCE initialized=INIT_ONCE_STATIC_INIT;
static SdkCallback callbacks[8];
static WCHAR *last_value;
static _Thread_local WCHAR *returned_value;
static HWND callback_window;
static HANDLE login_ready;
static LONG authenticated;

static BOOL login_succeeded(const WCHAR *text,int length)
{
    int depth=0;
    for(int i=0;i<length;i++) {
        if(text[i]==L'{'){depth++;continue;}
        if(text[i]==L'}'){depth--;continue;}
        if(text[i]!=L'"')continue;
        int start=++i;
        while(i<length && text[i]!=L'"') {if(text[i]==L'\\')i++;i++;}
        if(depth!=1 || i-start!=4 || wmemcmp(text+start,L"code",4))continue;
        i++;while(i<length && iswspace(text[i]))i++;
        if(i>=length || text[i++]!=L':')continue;
        while(i<length && iswspace(text[i]))i++;
        if(i>=length || text[i++]!=L'0')return FALSE;
        while(i<length && iswspace(text[i]))i++;
        return i<length && (text[i]==L',' || text[i]==L'}');
    }
    return FALSE;
}

static BOOL CALLBACK manage_game_window(HWND window,LPARAM unused)
{
    DWORD pid;GetWindowThreadProcessId(window,&pid);
    if(pid!=GetCurrentProcessId())return TRUE;
    WCHAR cls[128];GetClassNameW(window,cls,128);
    if(wcscmp(cls,L"UnityWndClass"))return TRUE;
    if(InterlockedCompareExchange(&authenticated,0,0)) {
        ShowWindow(window,SW_SHOW);SetForegroundWindow(window);
    } else if(IsWindowVisible(window)) {
        WCHAR name[128];swprintf(name,128,L"Local\\AzurPromiliaInvisibleReady-%lu",GetCurrentProcessId());
        HANDLE invisible=OpenEventW(SYNCHRONIZE,FALSE,name);
        BOOL bootstrapped=invisible && WaitForSingleObject(invisible,0)==WAIT_OBJECT_0;
        if(invisible)CloseHandle(invisible);
        if(!bootstrapped)ShowWindow(window,SW_HIDE);
    }
    return TRUE;
}

static DWORD WINAPI guard_game_window(void *unused)
{
    WCHAR preview[4];
    if(GetEnvironmentVariableW(L"FINEWINE_AZUR_PREVIEW",preview,4) && !wcscmp(preview,L"1"))return 0;
    while(!InterlockedCompareExchange(&authenticated,0,0)) {
        EnumWindows(manage_game_window,0);Sleep(10);
    }
    EnumWindows(manage_game_window,0);
    return 0;
}

static BOOL enable_background_loading(void)
{
    HMODULE assembly=GetModuleHandleW(L"GameAssembly.dll");if(!assembly)return FALSE;
    void *(*domain_get)(void)=(void *)GetProcAddress(assembly,"il2cpp_domain_get");
    const void **(*assemblies)(void *,size_t *)=(void *)GetProcAddress(assembly,"il2cpp_domain_get_assemblies");
    const void *(*get_image)(const void *)=(void *)GetProcAddress(assembly,"il2cpp_assembly_get_image");
    const char *(*image_name)(const void *)=(void *)GetProcAddress(assembly,"il2cpp_image_get_name");
    void *(*get_class)(const void *,const char *,const char *)=(void *)GetProcAddress(assembly,"il2cpp_class_from_name");
    const void *(*next_property)(void *,void **)=(void *)GetProcAddress(assembly,"il2cpp_class_get_properties");
    const char *(*property_name)(const void *)=(void *)GetProcAddress(assembly,"il2cpp_property_get_name");
    const void *(*setter)(const void *)=(void *)GetProcAddress(assembly,"il2cpp_property_get_set_method");
    void *(*invoke_method)(const void *,void *,void **,void **)=(void *)GetProcAddress(assembly,"il2cpp_runtime_invoke");
    if(!domain_get || !assemblies || !get_image || !image_name || !get_class || !next_property ||
       !property_name || !setter || !invoke_method)return FALSE;
    size_t count=0;const void **items=assemblies(domain_get(),&count);
    for(size_t i=0;i<count;i++) {
        const void *image=get_image(items[i]);
        if(strcmp(image_name(image),"UnityEngine.CoreModule.dll"))continue;
        void *klass=get_class(image,"UnityEngine","Application"),*iterator=NULL;
        if(!klass)return FALSE;
        const void *property;
        while((property=next_property(klass,&iterator))) {
            if(strcmp(property_name(property),"runInBackground"))continue;
            const void *method=setter(property);if(!method)return FALSE;
            bool enabled=true;void *args[]={&enabled},*exception=NULL;
            invoke_method(method,NULL,args,&exception);
            return !exception;
        }
    }
    return FALSE;
}

static LRESULT CALLBACK callback_proc(HWND window,UINT message,WPARAM wparam,LPARAM lparam)
{
    if(message==WM_APP+42) {
        CallbackItem *item=(CallbackItem *)lparam;
        SdkText data={item->text,(int32_t)(item->bytes/2)};
        if(callbacks[item->index])callbacks[item->index](&data);
        if(item->index==1 && login_succeeded(item->text,(int)(item->bytes/2))) {
            InterlockedExchange(&authenticated,1);SetEvent(login_ready);
        }
        SecureZeroMemory(item->text,item->bytes);free(item);return 0;
    }
    return DefWindowProcW(window,message,wparam,lparam);
}

static DWORD WINAPI read_events(void *unused)
{
    Packet packet;
    void *data;
    while((data=receive_packet(event_pipe,&packet))) {
        if(packet.kind==REPLY_VALUE) {
            free(last_value);last_value=data;SetEvent(value_ready);continue;
        }
        if(packet.kind>=EVENT_BASE && packet.kind<EVENT_BASE+8 && !(packet.bytes%2)) {
            CallbackItem *item=calloc(1,sizeof(*item)+packet.bytes+2);
            item->index=packet.kind-EVENT_BASE;item->bytes=packet.bytes;
            memcpy(item->text,data,packet.bytes);
            if(!PostMessageW(callback_window,WM_APP+42,0,(LPARAM)item))free(item);
        }
        SecureZeroMemory(data,packet.bytes);free(data);
    }
    SetEvent(value_ready);
    return 0;
}

static BOOL CALLBACK start_host(PINIT_ONCE once, void *parameter, void **context)
{
    InitializeCriticalSection(&command_lock);InitializeCriticalSection(&value_lock);
    value_ready=CreateEventW(NULL,FALSE,FALSE,NULL);
    WCHAR command[128],events[128];make_names(GetCurrentProcessId(),command,events);
    command_pipe=CreateNamedPipeW(command,PIPE_ACCESS_OUTBOUND,PIPE_TYPE_BYTE|PIPE_WAIT,1,1024*1024,0,0,NULL);
    event_pipe=CreateNamedPipeW(events,PIPE_ACCESS_INBOUND,PIPE_TYPE_BYTE|PIPE_WAIT,1,0,1024*1024,0,NULL);
    if(command_pipe==INVALID_HANDLE_VALUE || event_pipe==INVALID_HANDLE_VALUE)return FALSE;
    WCHAR path[32768],line[33000];GetModuleFileNameW(self,path,32768);
    WCHAR *slash=wcsrchr(path,L'\\');if(!slash)return FALSE;*slash=0;
    for(int i=0;i<3;i++){slash=wcsrchr(path,L'\\');if(!slash)return FALSE;*slash=0;}
    wcscat(path,L"\\azur-sdk-host.exe");
    swprintf(line,33000,L"\"%ls\" %lu",path,GetCurrentProcessId());
    STARTUPINFOW startup={.cb=sizeof(startup)};PROCESS_INFORMATION process={0};
    if(!CreateProcessW(path,line,NULL,NULL,FALSE,0,NULL,NULL,&startup,&process))return FALSE;
    host_process=process.hProcess;CloseHandle(process.hThread);
    BOOL connected=ConnectNamedPipe(command_pipe,NULL) || GetLastError()==ERROR_PIPE_CONNECTED;
    if(!connected)return FALSE;
    connected=ConnectNamedPipe(event_pipe,NULL) || GetLastError()==ERROR_PIPE_CONNECTED;
    if(!connected)return FALSE;
    CloseHandle(CreateThread(NULL,0,read_events,NULL,0,NULL));
    return TRUE;
}

static BOOL ready(void)
{
    if(!callback_window) {
        WNDCLASSW cls={.lpfnWndProc=callback_proc,.hInstance=self,.lpszClassName=L"AzurPromiliaSdkCallbackBridge"};
        RegisterClassW(&cls);
        callback_window=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,NULL,self,NULL);
        if(!callback_window)return FALSE;
    }
    if(InitOnceExecuteOnce(&initialized,start_host,NULL,NULL))return TRUE;
    MessageBoxW(NULL,L"外部登录进程未能启动。请关闭游戏后重新启动。",L"蓝原 · 外部登录",MB_OK|MB_ICONERROR);
    return FALSE;
}

static void invoke(uint32_t kind,const SdkContext *context)
{
    if(!ready())return;
    const WCHAR *text=context?context->argument.text:NULL;
    int length=context?context->argument.length:0;
    if(length<0 || length>500000 || (!text && length))return;
    send_packet(command_pipe,&command_lock,kind,0,text,(uint32_t)length*2);
}

#define INVOKE(name,kind) __declspec(dllexport) void name(const SdkContext *context){invoke(kind,context);}
__declspec(dllexport) void ManjuuSdk_Init(const SdkContext *context)
{
    BOOL background=enable_background_loading();
    FILE *log=_wfopen(L"C:\\FineWine\\sdk-window.log",L"w");
    if(log){fprintf(log,"background loading enabled: %d\n",background);fclose(log);}
    invoke(CMD_INIT,context);
}
INVOKE(ManjuuSdk_Login,CMD_LOGIN)
INVOKE(ManjuuSdk_Logout,CMD_LOGOUT)
INVOKE(ManjuuSdk_Exit,CMD_EXIT)
INVOKE(ManjuuSdk_Purchase,CMD_PURCHASE)
INVOKE(ManjuuSdk_QueryProductInfoList,CMD_QUERY)
__declspec(dllexport) void ManjuuSdk_UnInit(void){invoke(CMD_UNINIT,NULL);}
#define REGISTER(name,index) __declspec(dllexport) void name(SdkCallback callback){callbacks[index]=callback;}
REGISTER(ManjuuSdk_RegisterInitCallback,0)
REGISTER(ManjuuSdk_RegisterLoginCallback,1)
REGISTER(ManjuuSdk_RegisterLogoutCallback,2)
REGISTER(ManjuuSdk_RegisterExitCallback,3)
REGISTER(ManjuuSdk_RegisterExtensiveCallback,4)
REGISTER(ManjuuSdk_RegisterPurchaseCallback,5)
REGISTER(ManjuuSdk_RegisterQueryProductInfoListCallback,6)
REGISTER(ManjuuSdk_RegisterEventCallback,7)

static void send_strings(unsigned int kind,const WCHAR **strings,size_t count)
{
    if(!ready())return;
    size_t size=0;
    for(size_t i=0;i<count;i++) {
        size_t n=strings[i]?wcslen(strings[i]):0;
        if(n>500000 || size+n+1>500000)return;
        size+=n+1;
    }
    WCHAR *payload=calloc(size,2),*current=payload;if(!payload)return;
    for(size_t i=0;i<count;i++) {
        size_t n=strings[i]?wcslen(strings[i]):0;
        if(n)memcpy(current,strings[i],n*2);
        current+=n+1;
    }
    send_packet(command_pipe,&command_lock,kind,0,payload,(uint32_t)size*2);
    SecureZeroMemory(payload,size*2);free(payload);
}

__declspec(dllexport) void ManjuuSdk_LogEvent(void *context,const WCHAR *a,const WCHAR *b,const WCHAR *c,const WCHAR *d)
{
    const WCHAR *strings[]={a,b,c,d};send_strings(CMD_LOG,strings,4);
}

__declspec(dllexport) void ManjuuSdk_Extensive(void *context,const WCHAR *name,const WCHAR *argument)
{
    const WCHAR *strings[]={name,argument};send_strings(CMD_EXTENSIVE,strings,2);
}

__declspec(dllexport) void ManjuuSdk_SetValue(const void *context,const WCHAR *key,const WCHAR *value)
{
    if(!key || !value || !ready())return;
    size_t a=wcslen(key)+1,b=wcslen(value)+1;
    if(a+b>500000)return;
    WCHAR *payload=malloc((a+b)*2);memcpy(payload,key,a*2);memcpy(payload+a,value,b*2);
    send_packet(command_pipe,&command_lock,CMD_SET,0,payload,(uint32_t)(a+b)*2);
    SecureZeroMemory(payload,(a+b)*2);free(payload);
}

__declspec(dllexport) const WCHAR *ManjuuSdk_GetValue(const void *context,const WCHAR *key)
{
    if(!key || !ready())return L"";
    EnterCriticalSection(&value_lock);ResetEvent(value_ready);
    send_packet(command_pipe,&command_lock,CMD_GET,1,key,(uint32_t)(wcslen(key)+1)*2);
    HANDLE waits[]={value_ready,host_process};
    DWORD result=WaitForMultipleObjects(2,waits,FALSE,30000);
    free(returned_value);returned_value=NULL;
    if(result==WAIT_OBJECT_0 && last_value)returned_value=_wcsdup(last_value);
    LeaveCriticalSection(&value_lock);
    return returned_value?returned_value:L"";
}

BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void *reserved)
{
    if(reason==DLL_PROCESS_ATTACH) {
        self=module;
        WCHAR name[128];swprintf(name,128,L"Local\\AzurPromiliaLoginReady-%lu",GetCurrentProcessId());
        login_ready=CreateEventW(NULL,TRUE,FALSE,name);
        CloseHandle(CreateThread(NULL,0,guard_game_window,NULL,0,NULL));
    }
    return TRUE;
}
