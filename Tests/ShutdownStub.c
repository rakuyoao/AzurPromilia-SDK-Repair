#include <windows.h>

__declspec(dllexport) void ManjuuSdk_UnInit(void)
{
    WCHAR enabled[2];
    if(GetEnvironmentVariableW(L"MANJUUSDKFIX_TEST_HANG",enabled,2))Sleep(INFINITE);
}
