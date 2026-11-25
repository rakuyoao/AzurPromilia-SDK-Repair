#include <bcrypt.h>

typedef struct {uint32_t magic,revision,kind,width,height,phase,sequence,bytes,generation;} NativeFrame;
typedef struct {uint32_t kind;int32_t x,y;uint32_t button,buttons,modifiers,key,chars,generation;WCHAR text[];} NativeInput;
static CRITICAL_SECTION native_frame_lock;
static BYTE *native_pixels;
static DWORD native_bytes,native_width,native_height,native_sequence,native_phase=2;
static LONG native_visible,native_connected;
static SOCKET native_listener=INVALID_SOCKET;
static char native_token[65];
static BOOL native_mode;
static LONG native_generation;
static char *native_json;
static DWORD native_json_bytes,native_json_sequence;
static BYTE *native_values;
static DWORD native_values_bytes;
static BYTE *native_visual_pixels;
static DWORD native_visual_bytes,native_visual_width,native_visual_height,native_visual_id;
typedef struct NativeBrowserRequest {struct NativeBrowserRequest *next;DWORD bytes;char payload[];} NativeBrowserRequest;
static NativeBrowserRequest *native_browser_head,*native_browser_tail;
static void handle_control_action(NativeInput *input);

static BOOL socket_transfer(SOCKET socket,void *data,int bytes,BOOL writing)
{
    BYTE *current=data;
    while(bytes) {
        int n=writing?send(socket,(char *)current,bytes,0):recv(socket,(char *)current,bytes,0);
        if(n<=0)return FALSE;
        current+=n;bytes-=n;
    }
    return TRUE;
}

static DWORD WINAPI native_browser_requests(void *unused)
{
    WCHAR name[128];swprintf(name,128,L"\\\\.\\pipe\\AzurPromiliaNativeBrowser-%lu",GetCurrentProcessId());
    while(WaitForSingleObject(game_process,0)==WAIT_TIMEOUT) {
        HANDLE pipe=CreateNamedPipeW(name,PIPE_ACCESS_DUPLEX,PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT,1,65536,65536,2000,NULL);
        if(pipe==INVALID_HANDLE_VALUE)break;
        if(ConnectNamedPipe(pipe,NULL) || GetLastError()==ERROR_PIPE_CONNECTED) {
            char token[64];DWORD bytes=0;uint32_t accepted=0;
            if(transfer(pipe,token,64,FALSE) && !memcmp(token,native_token,64) && transfer(pipe,&bytes,4,FALSE) && bytes>0 && bytes<=65536) {
                NativeBrowserRequest *request=calloc(1,sizeof(*request)+(size_t)bytes+1);
                if(request && transfer(pipe,request->payload,bytes,FALSE)) {
                    request->bytes=bytes;
                    EnterCriticalSection(&native_frame_lock);
                    if(native_browser_tail)native_browser_tail->next=request;else native_browser_head=request;
                    native_browser_tail=request;LeaveCriticalSection(&native_frame_lock);accepted=1;
                } else free(request);
            }
            transfer(pipe,&accepted,4,TRUE);FlushFileBuffers(pipe);DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
    return 0;
}

static DWORD WINAPI native_transport(void *unused)
{
    while(TRUE) {
        SOCKET client=accept(native_listener,NULL,NULL);
        if(client==INVALID_SOCKET)break;
        DWORD timeout=2000;setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,(char *)&timeout,sizeof(timeout));
        setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,(char *)&timeout,sizeof(timeout));
        char token[64];
        if(!socket_transfer(client,token,64,FALSE) || memcmp(token,native_token,64)){closesocket(client);continue;}
        InterlockedExchange(&native_connected,1);
        DWORD sent=0;BOOL was_visible=FALSE,ok=TRUE;
        while(ok && WaitForSingleObject(game_process,0)==WAIT_TIMEOUT && IsWindow(main_window)) {
            EnterCriticalSection(&native_frame_lock);
            NativeBrowserRequest *browser=native_browser_head;
            if(browser){native_browser_head=browser->next;if(!native_browser_head)native_browser_tail=NULL;}
            LeaveCriticalSection(&native_frame_lock);
            if(browser) {
                NativeFrame header={0x49555a41,2,6,0,0,0,0,browser->bytes,(uint32_t)native_generation};
                ok=socket_transfer(client,&header,sizeof(header),TRUE) && socket_transfer(client,browser->payload,browser->bytes,TRUE);
                SecureZeroMemory(browser->payload,browser->bytes);free(browser);
                if(!ok)break;
            }
            BOOL visible=InterlockedCompareExchange(&native_visible,0,0)!=0;
            if(visible) {
                EnterCriticalSection(&native_frame_lock);
                DWORD sequence=native_json?native_json_sequence:native_sequence;
                DWORD bytes=native_json?native_json_bytes:native_bytes;
                NativeFrame header={0x49555a41,2,native_json?3:1,native_width,native_height,native_phase,sequence,bytes,(uint32_t)native_generation};
                BYTE *copy=NULL;
                BYTE *values=NULL;DWORD values_bytes=0;
                BYTE *visual=NULL;NativeFrame visual_header={0};
                if((native_json || native_pixels) && (sent!=sequence || !was_visible)) {
                    copy=malloc(bytes);if(copy)memcpy(copy,native_json?(void *)native_json:(void *)native_pixels,bytes);
                    if(native_values && native_values_bytes){values_bytes=native_values_bytes;values=malloc(values_bytes);if(values)memcpy(values,native_values,values_bytes);}
                    if(native_visual_pixels && native_visual_bytes) {
                        visual=malloc(native_visual_bytes);if(visual)memcpy(visual,native_visual_pixels,native_visual_bytes);
                        visual_header=(NativeFrame){0x49555a41,2,5,native_visual_width,native_visual_height,native_visual_id,sequence,native_visual_bytes,(uint32_t)native_generation};
                    }
                }
                LeaveCriticalSection(&native_frame_lock);
                if(copy) {
                    ok=socket_transfer(client,&header,sizeof(header),TRUE) && socket_transfer(client,copy,header.bytes,TRUE);
                    free(copy);sent=header.sequence;was_visible=TRUE;
                    if(ok && values) {
                        NativeFrame private_header=header;private_header.kind=4;private_header.bytes=values_bytes;
                        ok=socket_transfer(client,&private_header,sizeof(private_header),TRUE) && socket_transfer(client,values,values_bytes,TRUE);
                    }
                    if(ok && visual)ok=socket_transfer(client,&visual_header,sizeof(visual_header),TRUE) && socket_transfer(client,visual,visual_header.bytes,TRUE);
                }
                if(values){SecureZeroMemory(values,values_bytes);free(values);}
                if(visual){SecureZeroMemory(visual,visual_header.bytes);free(visual);}
            } else if(was_visible) {
                NativeFrame header={0x49555a41,2,2,0,0,native_phase,++sent,0,(uint32_t)native_generation};
                ok=socket_transfer(client,&header,sizeof(header),TRUE);was_visible=FALSE;
            }
            fd_set readers;FD_ZERO(&readers);FD_SET(client,&readers);struct timeval wait={0,10000};
            int selected=select(0,&readers,NULL,NULL,&wait);
            if(selected==SOCKET_ERROR){ok=FALSE;break;}
            if(selected>0) {
                uint32_t bytes;
                if(!socket_transfer(client,&bytes,sizeof(bytes),FALSE) || bytes<36 || bytes>65536){ok=FALSE;break;}
                NativeInput *input=calloc(1,(size_t)bytes+2);
                if(!input || !socket_transfer(client,input,(int)bytes,FALSE)){free(input);ok=FALSE;break;}
                if(input->chars>(bytes-36)/2 || !PostMessageW(main_window,WM_APP+4,0,(LPARAM)input))free(input);
            }
        }
        InterlockedExchange(&native_connected,0);closesocket(client);
    }
    return 0;
}

static BOOL start_native_transport(void)
{
    WCHAR enabled[4];
    native_mode=GetEnvironmentVariableW(L"FINEWINE_AZUR_NATIVE_UI",enabled,4) && !wcscmp(enabled,L"1");
    if(!native_mode)return FALSE;
    WSADATA data;if(WSAStartup(MAKEWORD(2,2),&data))return FALSE;
    native_listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    if(native_listener==INVALID_SOCKET)return FALSE;
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(native_listener,(struct sockaddr *)&address,sizeof(address)) || listen(native_listener,1))return FALSE;
    int size=sizeof(address);if(getsockname(native_listener,(struct sockaddr *)&address,&size))return FALSE;
    BYTE random[32];if(BCryptGenRandom(NULL,random,sizeof(random),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)return FALSE;
    for(int i=0;i<32;i++)sprintf(native_token+i*2,"%02x",random[i]);
    InitializeCriticalSection(&native_frame_lock);
    FILE *file=_wfopen(L"C:\\FineWine\\native-endpoint.json",L"w");
    if(!file)return FALSE;
    fprintf(file,"{\"revision\":2,\"port\":%u,\"token\":\"%s\",\"host\":%lu}\n",ntohs(address.sin_port),native_token,GetCurrentProcessId());
    fclose(file);SecureZeroMemory(random,sizeof(random));
    CloseHandle(CreateThread(NULL,0,native_transport,NULL,0,NULL));
    CloseHandle(CreateThread(NULL,0,native_browser_requests,NULL,0,NULL));
    return TRUE;
}

static void publish_native_frame(void)
{
    static ULONGLONG previous;
    ULONGLONG now=GetTickCount64();
    if(!native_mode || !image_bits || now-previous<33)return;
    previous=now;
    DWORD bytes=(DWORD)image_stride*(DWORD)image_height;
    EnterCriticalSection(&native_frame_lock);
    if(native_bytes!=bytes){free(native_pixels);native_pixels=malloc(bytes);native_bytes=bytes;}
    if(native_pixels) {
        memcpy(native_pixels,image_bits,bytes);native_width=image_width;native_height=image_height;
        native_sequence++;InterlockedExchange(&native_visible,1);
    }
    LeaveCriticalSection(&native_frame_lock);
}

typedef struct {int x,y;} QtPoint;
typedef struct {double x,y;} QtPointF;
static void *sdk_widget,*mouse_receiver;
static void *(*widget_child_at)(const void *,int,int);
static QtPoint *(*widget_map_from)(const void *,QtPoint *,const void *,const QtPoint *);
static QtPoint *(*widget_map_global)(const void *,QtPoint *,const QtPoint *);
static QtPoint *(*widget_map_to)(const void *,QtPoint *,const void *,const QtPoint *);
static int (*widget_width)(const void *),(*widget_height)(const void *);
static void (*widget_focus)(void *,int);
static void *(*focused_widget)(void);
static bool (*qt_send_event)(void *,void *);
static void (*mouse_construct)(void *,int,const QtPointF *,const QtPointF *,const QtPointF *,int,unsigned int,unsigned int);
static void (*mouse_destruct)(void *);
static void (*key_construct)(void *,int,int,unsigned int,const void *,bool,unsigned short);
static void (*key_destruct)(void *);
static void (*string_construct)(void *,const WCHAR *,int);
static void (*string_destruct)(void *);
static void (*dump_tree)(const void *);
static bool (*widget_close)(void *);

static BOOL initialize_input(void)
{
    if(qt_send_event)return TRUE;
    HMODULE core=GetModuleHandleW(L"Qt5Core.dll"),gui=GetModuleHandleW(L"Qt5Gui.dll"),widgets=GetModuleHandleW(L"Qt5Widgets.dll");
    widget_child_at=(void *)GetProcAddress(widgets,"?childAt@QWidget@@QEBAPEAV1@HH@Z");
    widget_map_from=(void *)GetProcAddress(widgets,"?mapFrom@QWidget@@QEBA?AVQPoint@@PEBV1@AEBV2@@Z");
    widget_map_global=(void *)GetProcAddress(widgets,"?mapToGlobal@QWidget@@QEBA?AVQPoint@@AEBV2@@Z");
    widget_map_to=(void *)GetProcAddress(widgets,"?mapTo@QWidget@@QEBA?AVQPoint@@PEBV1@AEBV2@@Z");
    widget_width=(void *)GetProcAddress(widgets,"?width@QWidget@@QEBAHXZ");
    widget_height=(void *)GetProcAddress(widgets,"?height@QWidget@@QEBAHXZ");
    widget_focus=(void *)GetProcAddress(widgets,"?setFocus@QWidget@@QEAAXW4FocusReason@Qt@@@Z");
    focused_widget=(void *)GetProcAddress(widgets,"?focusWidget@QApplication@@SAPEAVQWidget@@XZ");
    widget_close=(void *)GetProcAddress(widgets,"?close@QWidget@@QEAA_NXZ");
    mouse_construct=(void *)GetProcAddress(gui,"??0QMouseEvent@@QEAA@W4Type@QEvent@@AEBVQPointF@@11W4MouseButton@Qt@@V?$QFlags@W4MouseButton@Qt@@@@V?$QFlags@W4KeyboardModifier@Qt@@@@@Z");
    mouse_destruct=(void *)GetProcAddress(gui,"??1QMouseEvent@@UEAA@XZ");
    key_construct=(void *)GetProcAddress(gui,"??0QKeyEvent@@QEAA@W4Type@QEvent@@HV?$QFlags@W4KeyboardModifier@Qt@@@@AEBVQString@@_NG@Z");
    key_destruct=(void *)GetProcAddress(gui,"??1QKeyEvent@@UEAA@XZ");
    string_construct=(void *)GetProcAddress(core,"??0QString@@QEAA@PEBVQChar@@H@Z");
    string_destruct=(void *)GetProcAddress(core,"??1QString@@QEAA@XZ");
    dump_tree=(void *)GetProcAddress(core,"?dumpObjectTree@QObject@@QEBAXXZ");
    void *send=(void *)GetProcAddress(core,"?sendEvent@QCoreApplication@@SA_NPEAVQObject@@PEAVQEvent@@@Z");
    if(!widget_child_at || !widget_map_from || !widget_map_global || !widget_width || !widget_height || !widget_focus ||
       !focused_widget || !mouse_construct || !mouse_destruct || !key_construct || !key_destruct || !string_construct || !string_destruct || !send)return FALSE;
    qt_send_event=send;return TRUE;
}

static BOOL live_widget(void *widget)
{
    if(!widget)return FALSE;
    QtWidgetList list={0};all_widgets(&list);BOOL found=FALSE;
    if(list.data && list.data->begin>=0 && list.data->end<=list.data->allocation)
        for(int i=list.data->begin;i<list.data->end;i++)if(list.data->items[i]==widget){found=TRUE;break;}
    if(list.data && list.data->references!=-1 &&
       (!list.data->references || InterlockedDecrement(&list.data->references)==0))dispose_list(list.data);
    return found;
}

static void handle_native_input(NativeInput *input)
{
    if(shutting_down || !ui_active || input->generation!=(uint32_t)native_generation || !sdk_widget || !live_widget(sdk_widget) || !initialize_input()) {
        if(diagnostic && input->kind==5 && input->x==1){fprintf(diagnostic,"native button ignored: id=%u generation=%u current=%ld active=%d shutdown=%d\n",input->key,input->generation,native_generation,ui_active,shutting_down);fflush(diagnostic);}
        goto finished;
    }
    if(input->kind==5){handle_control_action(input);goto finished;}
    if(input->kind==1) {
        QtPoint position={MulDiv(input->x,widget_width(sdk_widget),image_width),MulDiv(input->y,widget_height(sdk_widget),image_height)};
        void *receiver=widget_child_at(sdk_widget,position.x,position.y);
        if(!receiver)receiver=sdk_widget;
        if(input->key==2 || input->key==4){mouse_receiver=receiver;widget_focus(receiver,0);}
        if((input->key==3 || input->buttons) && live_widget(mouse_receiver))receiver=mouse_receiver;
        QtPoint local,global;widget_map_from(receiver,&local,sdk_widget,&position);widget_map_global(sdk_widget,&global,&position);
        QtPointF local_f={local.x,local.y},window_f={position.x,position.y},global_f={global.x,global.y};
        _Alignas(16) BYTE event[104];
        mouse_construct(event,(int)input->key,&local_f,&window_f,&global_f,(int)input->button,input->buttons,input->modifiers);
        qt_send_event(receiver,event);mouse_destruct(event);
        if(input->key==3)mouse_receiver=NULL;
    } else if(input->kind==2 || input->kind==3) {
        void *receiver=focused_widget();if(!receiver)receiver=sdk_widget;
        void *text=NULL;string_construct(&text,input->text,(int)input->chars);
        _Alignas(16) BYTE event[64];
        key_construct(event,input->kind==2?6:7,(int)input->key,input->modifiers,&text,false,1);
        qt_send_event(receiver,event);key_destruct(event);string_destruct(&text);
    } else if(input->kind==4 && widget_close)widget_close(sdk_widget);
finished:
    SecureZeroMemory(input->text,input->chars*2);free(input);
}
