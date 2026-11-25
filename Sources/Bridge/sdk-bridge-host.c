#include <winsock2.h>
#include "sdk-bridge.h"
#include <stdbool.h>
#include <limits.h>

typedef LONG (WINAPI *ProcessControl)(HANDLE);
typedef struct {Packet packet;BYTE payload[];} Request;
static HMODULE sdk;
static HWND main_window;
static HANDLE command_pipe,event_pipe,game_process;
static CRITICAL_SECTION event_lock;
static ProcessControl suspend_process,resume_process;
static LONG paused;
static DWORD game_pid;
static BOOL waiting_ui;
static BOOL ui_active;
static BOOL auxiliary_ui;
static BOOL shutting_down;
static void (*pump_qt)(unsigned int);
static void (*pump_qt_timed)(unsigned int,int);
static void (*keep_qt_alive)(bool);
static const WCHAR *status=L"正在准备登录…";
static FILE *diagnostic;
static HDC paint_buffer;
static HBITMAP paint_bitmap;
static HGDIOBJ paint_original;
static int paint_width,paint_height;
static HWND sdk_window;
static void *image,*origin,*region;
static int image_width,image_height,image_stride;
static BYTE *image_bits;
static int (*meta_type)(const char *);
static int (*meta_size)(int);
static void *(*meta_create)(int,const void *);
static void (*image_construct)(void *,int,int,int);
static void (*image_destruct)(void *);
static BYTE *(*image_data)(void *);
static int (*image_bytes_per_line)(const void *);
static void (*image_fill)(void *,unsigned int);
static void (*image_ratio)(void *,double);
static void *(*widget_find)(uintptr_t);
static void *(*widget_window)(const void *);
static double (*window_ratio)(const void *);
static void (*widget_render)(void *,void *,const void *,const void *,unsigned int);
typedef struct { volatile LONG references; int allocation,begin,end; void *items[1]; } QtListData;
typedef struct { QtListData *data; } QtWidgetList;
static void (*all_widgets)(QtWidgetList *);
static void (*dispose_list)(QtListData *);
static bool (*widget_visible)(const void *,const void *);
static bool (*object_inherits)(const void *,const char *);
static uintptr_t (*widget_id)(const void *);
static void *(*widget_top)(const void *);
static void (*widget_opacity)(void *,double);
#include "sdk-native-ui.h"
#include "sdk-native-controls.h"

static BOOL CALLBACK activate_game_window(HWND window,LPARAM parameter)
{
    DWORD pid;GetWindowThreadProcessId(window,&pid);
    if(pid!=game_pid || !IsWindowVisible(window))return TRUE;
    WCHAR cls[128];GetClassNameW(window,cls,128);
    if(wcscmp(cls,L"UnityWndClass"))return TRUE;
    SetForegroundWindow(window);return FALSE;
}

static void return_to_game(void)
{
    ui_active=FALSE;waiting_ui=FALSE;auxiliary_ui=FALSE;
    sdk_widget=NULL;mouse_receiver=NULL;sdk_window=NULL;image_bits=NULL;
    InterlockedIncrement(&native_generation);
    InterlockedExchange(&native_visible,0);
    ShowWindow(main_window,SW_HIDE);
    EnumWindows(activate_game_window,0);
}

static BOOL initialize_renderer(void)
{
    if(widget_render)return TRUE;
    HMODULE core=GetModuleHandleW(L"Qt5Core.dll"),gui=GetModuleHandleW(L"Qt5Gui.dll"),widgets=GetModuleHandleW(L"Qt5Widgets.dll");
    if(!core || !gui || !widgets)return FALSE;
    keep_qt_alive=(void *)GetProcAddress(gui,"?setQuitOnLastWindowClosed@QGuiApplication@@SAX_N@Z");
    if(keep_qt_alive)keep_qt_alive(false);
    meta_type=(void *)GetProcAddress(core,"?type@QMetaType@@SAHPEBD@Z");
    meta_size=(void *)GetProcAddress(core,"?sizeOf@QMetaType@@SAHH@Z");
    meta_create=(void *)GetProcAddress(core,"?create@QMetaType@@SAPEAXHPEBX@Z");
    image_construct=(void *)GetProcAddress(gui,"??0QImage@@QEAA@HHW4Format@0@@Z");
    image_destruct=(void *)GetProcAddress(gui,"??1QImage@@UEAA@XZ");
    image_data=(void *)GetProcAddress(gui,"?bits@QImage@@QEAAPEAEXZ");
    image_bytes_per_line=(void *)GetProcAddress(gui,"?bytesPerLine@QImage@@QEBAHXZ");
    image_fill=(void *)GetProcAddress(gui,"?fill@QImage@@QEAAXI@Z");
    image_ratio=(void *)GetProcAddress(gui,"?setDevicePixelRatio@QImage@@QEAAXN@Z");
    widget_find=(void *)GetProcAddress(widgets,"?find@QWidget@@SAPEAV1@_K@Z");
    widget_window=(void *)GetProcAddress(widgets,"?windowHandle@QWidget@@QEBAPEAVQWindow@@XZ");
    window_ratio=(void *)GetProcAddress(gui,"?devicePixelRatio@QWindow@@QEBANXZ");
    all_widgets=(void *)GetProcAddress(widgets,"?allWidgets@QApplication@@SA?AV?$QList@PEAVQWidget@@@@XZ");
    dispose_list=(void *)GetProcAddress(core,"?dispose@QListData@@SAXPEAUData@1@@Z");
    widget_visible=(void *)GetProcAddress(widgets,"?isVisibleTo@QWidget@@QEBA_NPEBV1@@Z");
    object_inherits=(void *)GetProcAddress(core,"?inherits@QObject@@QEBA_NPEBD@Z");
    widget_id=(void *)GetProcAddress(widgets,"?winId@QWidget@@QEBA_KXZ");
    widget_top=(void *)GetProcAddress(widgets,"?window@QWidget@@QEBAPEAV1@XZ");
    widget_opacity=(void *)GetProcAddress(widgets,"?setWindowOpacity@QWidget@@QEAAXN@Z");
    void *render=(void *)GetProcAddress(widgets,"?render@QWidget@@QEAAXPEAVQPaintDevice@@AEBVQPoint@@AEBVQRegion@@V?$QFlags@W4RenderFlag@QWidget@@@@@Z");
    if(!meta_type || !meta_size || !meta_create || !image_construct || !image_destruct || !image_data ||
       !image_bytes_per_line || !image_fill || !image_ratio || !widget_find || !widget_window || !window_ratio || !render ||
       !all_widgets || !dispose_list || !widget_visible || !object_inherits || !widget_id || !widget_top)return FALSE;
    int size=meta_size(meta_type("QImage"));
    if(size<=0)return FALSE;
    image=calloc(1,(size_t)size);
    origin=meta_create(meta_type("QPoint"),NULL);
    region=meta_create(meta_type("QRegion"),NULL);
    if(!image || !origin || !region)return FALSE;
    widget_render=render;
    if(diagnostic){fprintf(diagnostic,"external renderer initialized; QImage size %d\n",size);fflush(diagnostic);}
    return TRUE;
}

static BOOL CALLBACK find_sdk_window(HWND window,LPARAM parameter)
{
    DWORD pid;GetWindowThreadProcessId(window,&pid);
    if(pid!=GetCurrentProcessId() || !IsWindowVisible(window))return TRUE;
    WCHAR cls[128];GetClassNameW(window,cls,128);
    if(!wcscmp(cls,L"Qt5152QWindowToolSaveBits") || !wcscmp(cls,L"Qt5152QWindowIcon")) {
        *(HWND *)parameter=window;return FALSE;
    }
    return TRUE;
}

static void render_sdk(void)
{
    if(!ui_active)return;
    if(!initialize_renderer())return;
    if(!initialize_input())return;
    HWND target=NULL;
    void *widget=NULL;
    {
        QtWidgetList list={0};all_widgets(&list);
        int priority=0,best_order=INT_MAX;
        if(list.data && list.data->begin>=0 && list.data->end<=list.data->allocation) {
            for(int i=list.data->begin;i<list.data->end;i++) {
                void *candidate=list.data->items[i];
                if(!candidate || !widget_visible(candidate,NULL))continue;
                if(object_inherits(candidate,"mj_base::MjToastWnd"))continue;
                int rank=widget_top(candidate)==candidate?1:0;
                if(!rank)continue;
                if(object_inherits(candidate,"mj_agr::AgreementWidget"))rank=2;
                if(object_inherits(candidate,"mj_base::MjConfirmPopupWnd"))rank=3;
                HWND handle=(HWND)widget_id(candidate);int order=0;
                for(HWND previous=GetWindow(handle,GW_HWNDPREV);previous;previous=GetWindow(previous,GW_HWNDPREV))order++;
                if(rank>priority || (rank==priority && order<best_order)){widget=candidate;priority=rank;best_order=order;}
            }
        }
        if(list.data && list.data->references!=-1 &&
           (!list.data->references || InterlockedDecrement(&list.data->references)==0))dispose_list(list.data);
        if(widget)target=(HWND)widget_id(widget);
    }
    if(!widget || !target){
        sdk_widget=NULL;mouse_receiver=NULL;sdk_window=NULL;image_bits=NULL;
        if(!waiting_ui)return_to_game();
        return;
    }
    if(auxiliary_ui && object_inherits(widget,"mj_official_cn::UserCenterWnd"))waiting_ui=FALSE;
    RECT client,position;POINT origin_screen={0,0};
    GetClientRect(main_window,&client);ClientToScreen(main_window,&origin_screen);
    GetWindowRect(target,&position);
    LONG_PTR extended=GetWindowLongPtrW(target,GWL_EXSTYLE);
    LONG_PTR desired=extended|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE;
    if(native_mode)desired|=WS_EX_TOOLWINDOW;
    if(extended!=desired)SetWindowLongPtrW(target,GWL_EXSTYLE,desired);
    if(native_mode && sdk_window!=target && widget_opacity)widget_opacity(widget,0.0);
    if(!native_mode && (position.left!=origin_screen.x || position.top!=origin_screen.y ||
       position.right-position.left!=client.right || position.bottom-position.top!=client.bottom))
        SetWindowPos(target,HWND_BOTTOM,origin_screen.x,origin_screen.y,client.right,client.bottom,SWP_NOACTIVATE);
    RECT rect;GetClientRect(target,&rect);
    int width=native_mode?widget_width(widget):rect.right,height=native_mode?widget_height(widget):rect.bottom;
    if(width<=0 || height<=0 || width>8192 || height>8192)return;
    sdk_widget=widget;initialize_input();
    if(sdk_window!=target) {
        sdk_window=target;InterlockedIncrement(&native_generation);control_count=0;
        if(!native_mode)SetWindowPos(main_window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
        if(diagnostic){fprintf(diagnostic,"SDK dialog %p at %d x %d generation %ld\n",target,width,height,native_generation);fflush(diagnostic);}
    }
    if(native_mode){image_width=width;image_height=height;publish_native_controls();return;}
    if(width!=image_width || height!=image_height) {
        if(image_width)image_destruct(image);
        image_construct(image,width,height,5);
        image_width=width;image_height=height;
    }
    void *window=widget_window(widget);
    image_ratio(image,window?window_ratio(window):1.0);
    image_fill(image,0xfff5f7fb);
    widget_render(widget,image,origin,region,3);
    image_bits=image_data(image);image_stride=image_bytes_per_line(image);
    publish_native_frame();
    publish_native_controls();
    InvalidateRect(main_window,NULL,FALSE);
}

static BOOL forward_input(UINT message,WPARAM wparam,LPARAM lparam)
{
    if(!sdk_window || !image_bits)return FALSE;
    if(message>=WM_MOUSEFIRST && message<=WM_MOUSELAST) {
        RECT rect;GetClientRect(main_window,&rect);
        POINT point={(short)LOWORD(lparam),(short)HIWORD(lparam)};
        if(message==WM_MOUSEWHEEL || message==WM_MOUSEHWHEEL)ScreenToClient(main_window,&point);
        if(rect.right>0)point.x=MulDiv(point.x,image_width,rect.right);
        if(rect.bottom>0)point.y=MulDiv(point.y,image_height,rect.bottom);
        if(message==WM_MOUSEWHEEL || message==WM_MOUSEHWHEEL)ClientToScreen(sdk_window,&point);
        PostMessageW(sdk_window,message,wparam,MAKELPARAM(point.x,point.y));return TRUE;
    }
    if(message>=WM_KEYFIRST && message<=WM_KEYLAST) {
        PostMessageW(sdk_window,message,wparam,lparam);return TRUE;
    }
    return FALSE;
}

static void resume_game(void)
{
    if(InterlockedExchange(&paused,0) && resume_process)resume_process(game_process);
}

static void pause_game(void)
{
    WCHAR preview[4];
    if(GetEnvironmentVariableW(L"FINEWINE_AZUR_PREVIEW",preview,4) && !wcscmp(preview,L"1"))return;
    if(!InterlockedCompareExchange(&paused,1,0) && suspend_process && suspend_process(game_process)<0)
        InterlockedExchange(&paused,0);
}

static void deliver(unsigned int index,const SdkText *text)
{
    if(!text || text->length<0 || text->length>500000)return;
    if(index<2)resume_game();
    if(index<2)PostMessageW(main_window,WM_APP+3,index,0);
    if(diagnostic){fprintf(diagnostic,"callback %u chars %d\n",index,text->length);fflush(diagnostic);}
    send_packet(event_pipe,&event_lock,EVENT_BASE+index,0,text->text,(uint32_t)text->length*2);
    if(index==0)status=L"正在连接游戏…";
    if(index==1)status=L"登录结果已发送。";
    InvalidateRect(main_window,NULL,FALSE);
}
#define CALLBACK_FN(index) static void callback_##index(const SdkText *text){deliver(index,text);}
CALLBACK_FN(0) CALLBACK_FN(1) CALLBACK_FN(2) CALLBACK_FN(3)
CALLBACK_FN(4) CALLBACK_FN(5) CALLBACK_FN(6) CALLBACK_FN(7)

static DWORD WINAPI read_commands(void *unused)
{
    Packet packet;void *data;
    while((data=receive_packet(command_pipe,&packet))) {
        Request *request=malloc(sizeof(*request)+packet.bytes+2);
        request->packet=packet;memcpy(request->payload,data,packet.bytes+2);free(data);
        if(!PostMessageW(main_window,WM_APP+1,0,(LPARAM)request)) {free(request);break;}
    }
    if(diagnostic){fprintf(diagnostic,"game command pipe closed: %lu\n",GetLastError());fflush(diagnostic);}
    PostMessageW(main_window,WM_CLOSE,0,0);
    return 0;
}

static DWORD WINAPI finish_shutdown(void *unused)
{
    Sleep(3000);
    if(diagnostic){fprintf(diagnostic,"SDK shutdown deadline reached; closing isolated host\n");fflush(diagnostic);}
    TerminateProcess(GetCurrentProcess(),0);
    return 0;
}

static void handle_request(Request *request)
{
    Packet packet=request->packet;WCHAR *text=(WCHAR *)request->payload;
    if(diagnostic){fprintf(diagnostic,"command %u chars %u\n",packet.kind,packet.bytes/2);fflush(diagnostic);}
    SdkContext context={main_window,{text,(int32_t)(packet.bytes/2)}};
    if(shutting_down)goto request_finished;
    if(packet.kind==CMD_UNINIT) {
        shutting_down=TRUE;
        return_to_game();
        if(diagnostic){fprintf(diagnostic,"SDK shutdown started; native interface retired\n");fflush(diagnostic);}
        CloseHandle(CreateThread(NULL,0,finish_shutdown,NULL,0,NULL));
        void (*call)(void)=(void *)GetProcAddress(sdk,"ManjuuSdk_UnInit");
        if(call)call();
        if(diagnostic){fprintf(diagnostic,"SDK shutdown completed\n");fflush(diagnostic);}
        PostMessageW(main_window,WM_CLOSE,0,0);
    } else if(packet.kind==CMD_LOG || packet.kind==CMD_EXTENSIVE) {
        WCHAR *fields[4]={0};size_t offset=0,total=packet.bytes/2;
        int count=packet.kind==CMD_LOG?4:2;
        for(int i=0;i<count;i++) {
            if(offset>=total)goto request_finished;
            fields[i]=text+offset;
            size_t length=wcsnlen(fields[i],total-offset);
            if(length==total-offset)goto request_finished;
            offset+=length+1;
        }
        if(packet.kind==CMD_LOG) {
            void (*call)(void *,const WCHAR *,const WCHAR *,const WCHAR *,const WCHAR *)=(void *)GetProcAddress(sdk,"ManjuuSdk_LogEvent");
            call(main_window,fields[0],fields[1],fields[2],fields[3]);
        } else {
            if(!wcscmp(fields[0],L"showUserCenter")) {
                ui_active=TRUE;waiting_ui=TRUE;auxiliary_ui=TRUE;native_phase=2;
                if(diagnostic){fprintf(diagnostic,"native user center requested\n");fflush(diagnostic);}
            }
            void (*call)(void *,const WCHAR *,const WCHAR *)=(void *)GetProcAddress(sdk,"ManjuuSdk_Extensive");
            call(main_window,fields[0],fields[1]);
        }
    } else if(packet.kind==CMD_SET) {
        size_t length=wcsnlen(text,packet.bytes/2);
        if(length+1<packet.bytes/2) {
            void (*call)(const SdkContext *,const WCHAR *,const WCHAR *)=(void *)GetProcAddress(sdk,"ManjuuSdk_SetValue");
            call(&context,text,text+length+1);
        }
    } else if(packet.kind==CMD_GET) {
        const WCHAR *(*call)(const SdkContext *,const WCHAR *)=(void *)GetProcAddress(sdk,"ManjuuSdk_GetValue");
        const WCHAR *value=call(&context,text);
        send_packet(event_pipe,&event_lock,REPLY_VALUE,packet.request,value,(uint32_t)(value?wcslen(value):0)*2);
    } else if(packet.kind>0 && packet.kind<=CMD_UNINIT) {
        if(packet.kind==CMD_INIT || packet.kind==CMD_LOGIN) {
            auxiliary_ui=FALSE;
            sdk_widget=NULL;mouse_receiver=NULL;sdk_window=NULL;image_bits=NULL;
            InterlockedExchange(&native_visible,0);InterlockedIncrement(&native_generation);
            waiting_ui=TRUE;ui_active=TRUE;
            native_phase=packet.kind==CMD_INIT?1:2;
            SetWindowTextW(main_window,packet.kind==CMD_INIT?L"用户协议":L"账户登录");
            status=packet.kind==CMD_INIT?L"请阅读并确认协议。":L"请完成账户登录。";
            if(!native_mode) {
                ShowWindow(main_window,SW_SHOW);SetForegroundWindow(main_window);
                SetWindowPos(main_window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW);
            }
            pause_game();
        }
        void (*call)(const SdkContext *)=(void *)GetProcAddress(sdk,commands[packet.kind]);
        if(call)call(&context);
        if(!pump_qt) {
            HMODULE core=GetModuleHandleW(L"Qt5Core.dll");
            pump_qt=(void *)GetProcAddress(core,"?processEvents@QCoreApplication@@SAXV?$QFlags@W4ProcessEventsFlag@QEventLoop@@@@@Z");
            pump_qt_timed=(void *)GetProcAddress(core,"?processEvents@QCoreApplication@@SAXV?$QFlags@W4ProcessEventsFlag@QEventLoop@@@@H@Z");
            HMODULE gui=GetModuleHandleW(L"Qt5Gui.dll");
            keep_qt_alive=(void *)GetProcAddress(gui,"?setQuitOnLastWindowClosed@QGuiApplication@@SAX_N@Z");
            if(keep_qt_alive)keep_qt_alive(false);
        }
    }
request_finished:
    SecureZeroMemory(text,packet.bytes);free(request);
    InvalidateRect(main_window,NULL,FALSE);
}

static LRESULT CALLBACK window_proc(HWND window,UINT message,WPARAM wparam,LPARAM lparam)
{
    if(message==WM_CLOSE && diagnostic){fprintf(diagnostic,"external window close message\n");fflush(diagnostic);}
    if(forward_input(message,wparam,lparam))return 0;
    if(message==WM_APP+1){handle_request((Request *)lparam);return 0;}
    if(message==WM_APP+3){
        if(diagnostic){fprintf(diagnostic,"SDK dialog completed: %llu; hiding native panel\n",(unsigned long long)wparam);fflush(diagnostic);}
        return_to_game();return 0;
    }
    if(message==WM_APP+4){handle_native_input((NativeInput *)lparam);return 0;}
    if(message==WM_ERASEBKGND)return 1;
    if(message==WM_SIZE || message==WM_MOVE){InvalidateRect(window,NULL,FALSE);return DefWindowProcW(window,message,wparam,lparam);}
    if(message==WM_TIMER) {
        static BOOL updating;
        if(updating)return 0;
        updating=TRUE;
        if(pump_qt_timed)pump_qt_timed(0,2);
        render_sdk();
        if(WaitForSingleObject(game_process,0)==WAIT_OBJECT_0) {
            DWORD code=0;GetExitCodeProcess(game_process,&code);
            if(diagnostic){fprintf(diagnostic,"game exited: %lu\n",code);fflush(diagnostic);}
            DestroyWindow(window);
        }
        updating=FALSE;
        return 0;
    }
    if(message==WM_PAINT) {
        PAINTSTRUCT paint;HDC screen=BeginPaint(window,&paint);RECT rect;GetClientRect(window,&rect);
        if(rect.right<=0 || rect.bottom<=0){EndPaint(window,&paint);return 0;}
        if(!paint_buffer)paint_buffer=CreateCompatibleDC(screen);
        if(!paint_bitmap || paint_width!=rect.right || paint_height!=rect.bottom) {
            if(paint_bitmap){SelectObject(paint_buffer,paint_original);DeleteObject(paint_bitmap);}
            paint_bitmap=CreateCompatibleBitmap(screen,rect.right,rect.bottom);
            paint_original=SelectObject(paint_buffer,paint_bitmap);
            paint_width=rect.right;paint_height=rect.bottom;
        }
        HDC dc=paint_buffer;
        HBRUSH brush=CreateSolidBrush(RGB(245,247,251));FillRect(dc,&rect,brush);DeleteObject(brush);
        if(image_bits && image_stride==image_width*4) {
            BITMAPINFO bitmap={0};bitmap.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
            bitmap.bmiHeader.biWidth=image_width;bitmap.bmiHeader.biHeight=-image_height;
            bitmap.bmiHeader.biPlanes=1;bitmap.bmiHeader.biBitCount=32;bitmap.bmiHeader.biCompression=BI_RGB;
            SetStretchBltMode(dc,HALFTONE);
            StretchDIBits(dc,0,0,rect.right,rect.bottom,0,0,image_width,image_height,image_bits,&bitmap,DIB_RGB_COLORS,SRCCOPY);
            BitBlt(screen,0,0,rect.right,rect.bottom,dc,0,0,SRCCOPY);
            EndPaint(window,&paint);return 0;
        }
        HFONT font=CreateFontW(-26,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Microsoft YaHei");
        HGDIOBJ old=SelectObject(dc,font);SetBkMode(dc,TRANSPARENT);SetTextColor(dc,RGB(36,49,70));
        RECT info={40,36,1100,120};DrawTextW(dc,status,-1,&info,DT_LEFT|DT_WORDBREAK);
        SelectObject(dc,old);DeleteObject(font);
        BitBlt(screen,0,0,rect.right,rect.bottom,dc,0,0,SRCCOPY);
        EndPaint(window,&paint);return 0;
    }
    if(message==WM_DESTROY){
        if(diagnostic){fprintf(diagnostic,"external window destroyed\n");fflush(diagnostic);}
        if(paint_buffer){if(paint_bitmap){SelectObject(paint_buffer,paint_original);DeleteObject(paint_bitmap);}DeleteDC(paint_buffer);}
        resume_game();PostQuitMessage(0);return 0;
    }
    return DefWindowProcW(window,message,wparam,lparam);
}

int wmain(int argc,WCHAR **argv)
{
    if(argc==4 && !wcscmp(argv[1],L"--watchdog")) {
        DWORD game_id=wcstoul(argv[2],NULL,10);
        HANDLE game=OpenProcess(PROCESS_SUSPEND_RESUME|PROCESS_TERMINATE,FALSE,game_id);
        HANDLE host=OpenProcess(SYNCHRONIZE,FALSE,wcstoul(argv[3],NULL,10));
        if(!game || !host)return 8;
        WaitForSingleObject(host,INFINITE);
        ProcessControl resume=(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"NtResumeProcess");
        if(resume)resume(game);
        WCHAR name[128];swprintf(name,128,L"Local\\AzurPromiliaLoginReady-%lu",game_id);
        HANDLE ready=OpenEventW(SYNCHRONIZE,FALSE,name);
        if(ready && WaitForSingleObject(ready,0)!=WAIT_OBJECT_0)TerminateProcess(game,ERROR_CANCELLED);
        return 0;
    }
    if(argc!=2)return 2;
    DWORD pid=wcstoul(argv[1],NULL,10);
    game_pid=pid;
    game_process=OpenProcess(PROCESS_SUSPEND_RESUME|PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,pid);
    if(!game_process)return 3;
    HMODULE nt=GetModuleHandleW(L"ntdll.dll");
    suspend_process=(void *)GetProcAddress(nt,"NtSuspendProcess");
    resume_process=(void *)GetProcAddress(nt,"NtResumeProcess");
    WCHAR command[128],events[128];make_names(pid,command,events);
    command_pipe=CreateFileW(command,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);
    event_pipe=CreateFileW(events,GENERIC_WRITE,0,NULL,OPEN_EXISTING,0,NULL);
    if(command_pipe==INVALID_HANDLE_VALUE || event_pipe==INVALID_HANDLE_VALUE)return 4;
    InitializeCriticalSection(&event_lock);
    WCHAR directory[32768],path[32768];GetModuleFileNameW(NULL,directory,32768);
    WCHAR watcher[33000];
    swprintf(watcher,33000,L"\"%ls\" --watchdog %lu %lu",directory,pid,GetCurrentProcessId());
    STARTUPINFOW startup={.cb=sizeof(startup)};PROCESS_INFORMATION process={0};
    if(!CreateProcessW(directory,watcher,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&startup,&process))return 9;
    CloseHandle(process.hThread);CloseHandle(process.hProcess);
    WCHAR *slash=wcsrchr(directory,L'\\');if(!slash)return 5;*slash=0;
    SetCurrentDirectoryW(directory);
    swprintf(path,32768,L"%ls\\AzurPromilia_Data\\Plugins\\mj_sdk",directory);
    SetDllDirectoryW(path);
    wcscat(path,L"\\union_pcsdk_original.dll");
    diagnostic=_wfopen(L"C:\\FineWine\\sdk-bridge.log",L"w");
    sdk=LoadLibraryW(path);
    if(!sdk){if(diagnostic)fprintf(diagnostic,"SDK load error %lu\n",GetLastError());return 6;}
    SdkCallback functions[]={callback_0,callback_1,callback_2,callback_3,callback_4,callback_5,callback_6,callback_7};
    for(int i=0;i<8;i++) {
        void (*reg)(SdkCallback)=(void *)GetProcAddress(sdk,registrations[i]);
        if(!reg)return 7;reg(functions[i]);
    }
    SetProcessDPIAware();
    WNDCLASSW cls={.lpfnWndProc=window_proc,.hInstance=GetModuleHandleW(NULL),.lpszClassName=L"AzurPromiliaExternalSdkHost",.hCursor=LoadCursorW(NULL,IDC_ARROW)};
    RegisterClassW(&cls);
    WCHAR native_enabled[4];
    BOOL use_native=GetEnvironmentVariableW(L"FINEWINE_AZUR_NATIVE_UI",native_enabled,4) && !wcscmp(native_enabled,L"1");
    main_window=CreateWindowExW(use_native?(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_LAYERED):(WS_EX_APPWINDOW|WS_EX_TOPMOST),cls.lpszClassName,L"账户登录",use_native?WS_POPUP:WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,CW_USEDEFAULT,1200,860,NULL,NULL,cls.hInstance,NULL);
    start_native_transport();
    if(native_mode){SetLayeredWindowAttributes(main_window,0,0,LWA_ALPHA);ShowWindow(main_window,SW_SHOWNOACTIVATE);}
    else {ShowWindow(main_window,SW_SHOW);SetForegroundWindow(main_window);}
    SetTimer(main_window,1,16,NULL);
    CloseHandle(CreateThread(NULL,0,read_commands,NULL,0,NULL));
    MSG message;
    while(TRUE) {
        int result=GetMessageW(&message,NULL,0,0);
        if(result<0)break;
        if(!result) {
            if(!shutting_down && IsWindow(main_window) && WaitForSingleObject(game_process,0)==WAIT_TIMEOUT) {
                if(diagnostic){fprintf(diagnostic,"ignored premature Qt quit while game is active\n");fflush(diagnostic);}
                continue;
            }
            break;
        }
        TranslateMessage(&message);DispatchMessageW(&message);
    }
    resume_game();
    return 0;
}
