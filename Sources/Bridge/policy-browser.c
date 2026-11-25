#ifndef UNICODE
#define UNICODE
#endif
#include <winsock2.h>
#include <windows.h>
#include <wincrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static HANDLE sdk_pipe;
static DWORD host_pid;
static char relay_token[65];
static CRITICAL_SECTION sdk_write_lock,captcha_lock;
static SOCKET callback_listener=INVALID_SOCKET;
static unsigned short callback_port;
static WCHAR captcha_page[1024];

static BOOL socket_bytes(SOCKET socket,void *buffer,int bytes,BOOL writing)
{
    char *current=buffer;
    while(bytes) {
        int count=writing?send(socket,current,bytes,0):recv(socket,current,bytes,0);
        if(count<=0)return FALSE;
        current+=count;bytes-=count;
    }
    return TRUE;
}

static BOOL transfer_bytes(HANDLE pipe,void *buffer,DWORD bytes,BOOL writing)
{
    BYTE *cursor=buffer;
    while(bytes) {
        DWORD count=0;
        OVERLAPPED operation={.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL)};
        if(!operation.hEvent)return FALSE;
        BOOL ok=writing?WriteFile(pipe,cursor,bytes,&count,&operation):ReadFile(pipe,cursor,bytes,&count,&operation);
        if(!ok && GetLastError()==ERROR_IO_PENDING)ok=GetOverlappedResult(pipe,&operation,&count,TRUE);
        CloseHandle(operation.hEvent);
        if(!ok || !count)return FALSE;
        cursor+=count;bytes-=count;
    }
    return TRUE;
}

static BOOL json_string(const WCHAR **position,WCHAR *value,size_t capacity)
{
    const WCHAR *p=*position;
    if(*p!=L'"')return FALSE;
    p++;size_t length=0;
    while(*p && *p!=L'"') {
        WCHAR ch=*p++;
        if(ch==L'\\') {
            ch=*p++;
            if(ch==L'u') {
                unsigned code=0;
                for(int i=0;i<4;i++) {
                    WCHAR digit=*p++;
                    if(digit>=L'0' && digit<=L'9')code=code*16+digit-L'0';
                    else if(digit>=L'a' && digit<=L'f')code=code*16+digit-L'a'+10;
                    else if(digit>=L'A' && digit<=L'F')code=code*16+digit-L'A'+10;
                    else return FALSE;
                }
                ch=(WCHAR)code;
            } else if(ch==L'n')ch=L'\n';
            else if(ch==L'r')ch=L'\r';
            else if(ch==L't')ch=L'\t';
            else if(ch==L'b')ch=L'\b';
            else if(ch==L'f')ch=L'\f';
            else if(ch!=L'"' && ch!=L'\\' && ch!=L'/')return FALSE;
        }
        if(length+1>=capacity)return FALSE;
        value[length++]=ch;
    }
    if(*p!=L'"')return FALSE;
    value[length]=0;*position=p+1;return TRUE;
}

static WCHAR *wide_json(const char *json,DWORD bytes)
{
    int chars=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,json,(int)bytes,NULL,0);
    WCHAR *wide=chars?calloc((size_t)chars+1,2):NULL;
    if(wide)MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,json,(int)bytes,wide,chars);
    return wide;
}

static const WCHAR *root_value(const WCHAR *json,const WCHAR *key)
{
    const WCHAR *p=json;int depth=0;WCHAR token[32768];
    while(*p) {
        if(*p==L'{' || *p==L'['){depth++;p++;continue;}
        if(*p==L'}' || *p==L']'){depth--;p++;continue;}
        if(*p!=L'"'){p++;continue;}
        if(!json_string(&p,token,32768))return NULL;
        const WCHAR *next=p;while(*next==L' ' || *next==L'\n' || *next==L'\r' || *next==L'\t')next++;
        if(depth==1 && *next==L':' && !wcscmp(token,key)) {
            next++;while(*next==L' ' || *next==L'\n' || *next==L'\r' || *next==L'\t')next++;
            return next;
        }
    }
    return NULL;
}

static BOOL valid_token(const WCHAR *token)
{
    if(wcslen(token)!=64)return FALSE;
    for(const WCHAR *p=token;*p;p++)if(!((*p>=L'0' && *p<=L'9') || (*p>=L'a' && *p<=L'f') || (*p>=L'A' && *p<=L'F')))return FALSE;
    return TRUE;
}

static BOOL send_json(HANDLE pipe,const char *json)
{
    DWORD bytes=0;
    if(!CryptBinaryToStringA((BYTE *)json,(DWORD)strlen(json),CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,NULL,&bytes))return FALSE;
    char *encoded=malloc(bytes);if(!encoded)return FALSE;
    BOOL ok=CryptBinaryToStringA((BYTE *)json,(DWORD)strlen(json),CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,encoded,&bytes);
    bytes=(DWORD)strlen(encoded);
    for(DWORD i=0;i<bytes/2;i++){char ch=encoded[i];encoded[i]=encoded[bytes-1-i];encoded[bytes-1-i]=ch;}
    BYTE header[]={(BYTE)(bytes>>24),(BYTE)(bytes>>16),(BYTE)(bytes>>8),(BYTE)bytes};
    if(ok)ok=transfer_bytes(pipe,header,4,TRUE) && transfer_bytes(pipe,encoded,bytes,TRUE);
    SecureZeroMemory(encoded,bytes);free(encoded);return ok;
}

static char *decode_message(BYTE *payload,DWORD bytes,DWORD *decoded_size)
{
    if(!bytes || bytes>16*1024*1024)return NULL;
    for(DWORD i=0;i<bytes/2;i++){BYTE ch=payload[i];payload[i]=payload[bytes-1-i];payload[bytes-1-i]=ch;}
    *decoded_size=0;
    if(!CryptStringToBinaryA((char *)payload,bytes,CRYPT_STRING_BASE64,NULL,decoded_size,NULL,NULL))return NULL;
    char *json=calloc((size_t)*decoded_size+1,1);if(!json)return NULL;
    if(!CryptStringToBinaryA((char *)payload,bytes,CRYPT_STRING_BASE64,(BYTE *)json,decoded_size,NULL,NULL)){free(json);return NULL;}
    return json;
}

static BOOL send_sdk_json(const char *json)
{
    EnterCriticalSection(&sdk_write_lock);
    BOOL ok=send_json(sdk_pipe,json);
    LeaveCriticalSection(&sdk_write_lock);
    return ok;
}

static BOOL accept_captcha_result(const char *json,DWORD bytes)
{
    WCHAR *wide=wide_json(json,bytes);if(!wide)return FALSE;
    const WCHAR *type=root_value(wide,L"type"),*position=root_value(wide,L"page_id");
    WCHAR page[1024],result[32768];
    int message_type=type?(int)wcstol(type,NULL,10):0;
    BOOL ok=(message_type==200 || message_type==204) && position && json_string(&position,page,1024);
    if(ok && message_type==200) {
        position=root_value(wide,L"result");
        ok=position && json_string(&position,result,32768) && result[0];
    }
    if(ok) {
        EnterCriticalSection(&captcha_lock);
        ok=captcha_page[0] && !wcscmp(page,captcha_page) && send_sdk_json(json);
        if(ok)SecureZeroMemory(captcha_page,sizeof(captcha_page));
        LeaveCriticalSection(&captcha_lock);
    }
    SecureZeroMemory(result,sizeof(result));SecureZeroMemory(page,sizeof(page));
    SecureZeroMemory(wide,wcslen(wide)*2);free(wide);return ok;
}

static DWORD WINAPI captcha_callbacks(void *unused)
{
    for(;;) {
        SOCKET client=accept(callback_listener,NULL,NULL);
        if(client==INVALID_SOCKET)break;
        DWORD timeout=2000;setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,(char *)&timeout,sizeof(timeout));
        setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,(char *)&timeout,sizeof(timeout));
        char token[64];DWORD bytes=0,accepted=0;
        if(socket_bytes(client,token,64,FALSE) && !memcmp(token,relay_token,64) && socket_bytes(client,&bytes,4,FALSE) && bytes>0 && bytes<=65536) {
            char *json=calloc((size_t)bytes+1,1);
            if(json && socket_bytes(client,json,(int)bytes,FALSE))accepted=accept_captcha_result(json,bytes)?1:0;
            if(json){SecureZeroMemory(json,bytes);free(json);}
        }
        socket_bytes(client,&accepted,4,TRUE);SecureZeroMemory(token,sizeof(token));closesocket(client);
    }
    return 0;
}

static BOOL start_callbacks(void)
{
    WSADATA data;if(WSAStartup(MAKEWORD(2,2),&data))return FALSE;
    callback_listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    if(callback_listener==INVALID_SOCKET)return FALSE;
    struct sockaddr_in address={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(callback_listener,(struct sockaddr *)&address,sizeof(address)) || listen(callback_listener,2))return FALSE;
    int size=sizeof(address);
    if(getsockname(callback_listener,(struct sockaddr *)&address,&size))return FALSE;
    callback_port=ntohs(address.sin_port);
    HANDLE thread=CreateThread(NULL,0,captcha_callbacks,NULL,0,NULL);
    if(!thread)return FALSE;
    CloseHandle(thread);return TRUE;
}

static BOOL load_relay_token(void)
{
    FILE *file=_wfopen(L"C:\\FineWine\\native-endpoint.json",L"rb");if(!file)return FALSE;
    char json[4096];size_t bytes=fread(json,1,sizeof(json),file);fclose(file);
    WCHAR *wide=wide_json(json,(DWORD)bytes);if(!wide)return FALSE;
    const WCHAR *position=root_value(wide,L"token");WCHAR token[65];
    BOOL ok=position && json_string(&position,token,65) && valid_token(token);
    if(ok)for(int i=0;i<64;i++)relay_token[i]=(char)token[i];
    SecureZeroMemory(token,sizeof(token));SecureZeroMemory(wide,wcslen(wide)*2);free(wide);
    SecureZeroMemory(json,sizeof(json));return ok;
}

static BOOL relay_request(const char *json,DWORD bytes)
{
    if(bytes>65536)return FALSE;
    WCHAR *wide=wide_json(json,bytes);if(!wide)return FALSE;
    const WCHAR *position=root_value(wide,L"scene");WCHAR scene[128];
    BOOL captcha=position && json_string(&position,scene,128) && !wcscmp(scene,L"captcha");
    if(captcha) {
        position=root_value(wide,L"page_id");WCHAR page[1024];
        const WCHAR *type=root_value(wide,L"type");
        if(type && wcstol(type,NULL,10)==200 && position && json_string(&position,page,1024) && page[0]) {
            EnterCriticalSection(&captcha_lock);wcscpy(captcha_page,page);LeaveCriticalSection(&captcha_lock);
        } else if(type && wcstol(type,NULL,10)==201) {
            EnterCriticalSection(&captcha_lock);SecureZeroMemory(captcha_page,sizeof(captcha_page));LeaveCriticalSection(&captcha_lock);
        }
        SecureZeroMemory(page,sizeof(page));
    }
    SecureZeroMemory(wide,wcslen(wide)*2);free(wide);
    char *wrapped=NULL;
    if(captcha) {
        DWORD end=bytes;while(end && (json[end-1]==' ' || json[end-1]=='\r' || json[end-1]=='\n' || json[end-1]=='\t'))end--;
        if(!end || json[end-1]!='}')return FALSE;
        wrapped=calloc((size_t)bytes+160,1);if(!wrapped)return FALSE;
        memcpy(wrapped,json,end-1);
        snprintf(wrapped+end-1,161," ,\"native_callback\":{\"port\":%u,\"token\":\"%s\"}}",callback_port,relay_token);
        json=wrapped;bytes=(DWORD)strlen(json);
    }
    WCHAR name[128];swprintf(name,128,L"\\\\.\\pipe\\AzurPromiliaNativeBrowser-%lu",host_pid);
    HANDLE pipe=INVALID_HANDLE_VALUE;
    for(int i=0;i<30;i++) {
        pipe=CreateFileW(name,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
        if(pipe!=INVALID_HANDLE_VALUE)break;
        WaitNamedPipeW(name,100);Sleep(100);
    }
    if(pipe==INVALID_HANDLE_VALUE){if(wrapped){SecureZeroMemory(wrapped,bytes);free(wrapped);}return FALSE;}
    DWORD accepted=0;
    BOOL ok=transfer_bytes(pipe,relay_token,64,TRUE) && transfer_bytes(pipe,&bytes,4,TRUE) && transfer_bytes(pipe,(void *)json,bytes,TRUE) && transfer_bytes(pipe,&accepted,4,FALSE) && accepted==1;
    CloseHandle(pipe);
    if(wrapped){SecureZeroMemory(wrapped,bytes);free(wrapped);}
    return ok;
}

static DWORD WINAPI read_requests(void *unused)
{
    for(;;) {
        BYTE header[4];if(!transfer_bytes(sdk_pipe,header,4,FALSE))break;
        DWORD bytes=((DWORD)header[0]<<24)|((DWORD)header[1]<<16)|((DWORD)header[2]<<8)|header[3];
        if(!bytes || bytes>16*1024*1024)break;
        BYTE *payload=malloc(bytes);if(!payload)break;
        BOOL ok=transfer_bytes(sdk_pipe,payload,bytes,FALSE);DWORD decoded_size=0;
        char *json=ok?decode_message(payload,bytes,&decoded_size):NULL;
        SecureZeroMemory(payload,bytes);free(payload);
        if(!json)break;
        WCHAR *wide=wide_json(json,decoded_size);
        const WCHAR *type=wide?root_value(wide,L"type"):NULL;
        if(type && wcstol(type,NULL,10)==200) {
            const WCHAR *value=root_value(wide,L"url");WCHAR url[32768];
            if(value && json_string(&value,url,32768) && (!wcsncmp(url,L"https://",8) || !wcsncmp(url,L"http://",7)))ok=relay_request(json,decoded_size);
            SecureZeroMemory(url,sizeof(url));
        } else if(type && wcstol(type,NULL,10)==201)ok=relay_request(json,decoded_size);
        if(wide){SecureZeroMemory(wide,wcslen(wide)*2);free(wide);}
        SecureZeroMemory(json,decoded_size);free(json);
        if(!ok)break;
    }
    return 0;
}

int wmain(int argc,WCHAR **argv)
{
    const WCHAR *server=NULL,*capability=NULL;
    for(int i=1;i+1<argc;i++) {
        if(!wcscmp(argv[i],L"--ipc-server"))server=argv[i+1];
        if(!wcscmp(argv[i],L"--ipc-capability"))capability=argv[i+1];
        if(!wcscmp(argv[i],L"--parent-pid"))host_pid=wcstoul(argv[i+1],NULL,10);
    }
    if(!server || !capability || !host_pid || !valid_token(capability) || !load_relay_token())return 2;
    InitializeCriticalSection(&sdk_write_lock);InitializeCriticalSection(&captcha_lock);
    if(!start_callbacks())return 6;
    WCHAR name[32768];swprintf(name,32768,L"\\\\.\\pipe\\%ls",server);
    sdk_pipe=INVALID_HANDLE_VALUE;
    for(int i=0;i<50;i++) {
        sdk_pipe=CreateFileW(name,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
        if(sdk_pipe!=INVALID_HANDLE_VALUE)break;
        WaitNamedPipeW(name,100);Sleep(100);
    }
    if(sdk_pipe==INVALID_HANDLE_VALUE)return 3;
    char hello[128],token[65]={0};for(int i=0;i<64;i++)token[i]=(char)capability[i];
    snprintf(hello,sizeof(hello),"{\"capability\":\"%s\",\"type\":1}",token);
    BOOL ready=send_sdk_json(hello);
    SecureZeroMemory(token,sizeof(token));SecureZeroMemory(hello,sizeof(hello));
    if(!ready){CloseHandle(sdk_pipe);return 4;}
    HANDLE parent=OpenProcess(SYNCHRONIZE,FALSE,host_pid);
    HANDLE reader=CreateThread(NULL,0,read_requests,NULL,0,NULL);
    if(!parent || !reader)return 5;
    HANDLE waiting[]={parent,reader};
    while(WaitForMultipleObjects(2,waiting,FALSE,1000)==WAIT_TIMEOUT) {
        EnterCriticalSection(&captcha_lock);BOOL visible=captcha_page[0]!=0;LeaveCriticalSection(&captcha_lock);
        if(!send_sdk_json(visible?"{\"type\":2,\"window_exists\":true}":"{\"type\":2,\"window_exists\":false}"))break;
    }
    CancelIoEx(sdk_pipe,NULL);CloseHandle(sdk_pipe);WaitForSingleObject(reader,2000);
    closesocket(callback_listener);CloseHandle(reader);CloseHandle(parent);SecureZeroMemory(relay_token,sizeof(relay_token));return 0;
}
