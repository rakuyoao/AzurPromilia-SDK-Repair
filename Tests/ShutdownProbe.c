#define wmain sdk_host_entry
#include "../Sources/Bridge/sdk-bridge-host.c"
#undef wmain

int wmain(int argc,WCHAR **argv)
{
    if(argc==3) {
        diagnostic=stderr;
        sdk=LoadLibraryW(argv[2]);if(!sdk)return 10;
        main_window=CreateWindowExW(0,L"STATIC",L"shutdown-test",0,0,0,1,1,NULL,NULL,NULL,NULL);
        ui_active=TRUE;waiting_ui=TRUE;native_visible=1;
        Request *request=calloc(1,sizeof(*request)+2);request->packet.kind=CMD_UNINIT;
        handle_request(request);
        if(!shutting_down || ui_active || native_visible || waiting_ui)return 11;
        return 0;
    }
    if(argc!=2)return 2;
    for(int blocked=0;blocked<2;blocked++) {
        SetEnvironmentVariableW(L"MANJUUSDKFIX_TEST_HANG",blocked?L"1":NULL);
        WCHAR image[32768],command[65536];GetModuleFileNameW(NULL,image,32768);
        swprintf(command,65536,L"\"%ls\" --child \"%ls\"",image,argv[1]);
        STARTUPINFOW startup={.cb=sizeof(startup)};PROCESS_INFORMATION process={0};
        ULONGLONG started=GetTickCount64();
        if(!CreateProcessW(image,command,NULL,NULL,FALSE,0,NULL,NULL,&startup,&process))return 3;
        DWORD result=WaitForSingleObject(process.hProcess,6000),code=99;
        if(result!=WAIT_OBJECT_0){TerminateProcess(process.hProcess,12);return 4;}
        GetExitCodeProcess(process.hProcess,&code);CloseHandle(process.hThread);CloseHandle(process.hProcess);
        ULONGLONG elapsed=GetTickCount64()-started;
        if(code || (blocked && elapsed<2500))return 5;
        printf("SDK shutdown %s: %llu ms PASS\n",blocked?"blocked":"normal",(unsigned long long)elapsed);
    }
    return 0;
}
