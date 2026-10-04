//! The Windows functions and types petal calls that Zig's standard library does not declare.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HANDLE = windows.HANDLE;
pub const WCHAR = windows.WCHAR;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const PROCESS_INFORMATION = windows.PROCESS.INFORMATION;
pub const CreateProcessFlags = windows.CreateProcessFlags;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const CloseHandle = windows.CloseHandle;
pub const GetLastError = windows.GetLastError;
pub const CreateProcessW = windows.kernel32.CreateProcessW;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;

pub const STARTF_USESTDHANDLES: DWORD = 0x100;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x1;
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x20002;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_READ_ATTRIBUTES: DWORD = 0x80;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const FILE_SHARE_DELETE: DWORD = 0x4;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_END: DWORD = 2;
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
pub const LOCKFILE_EXCLUSIVE_LOCK: DWORD = 0x2;

pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_PATH_NOT_FOUND: u32 = 3;
pub const ERROR_BROKEN_PIPE: u32 = 109;
pub const ERROR_ALREADY_EXISTS: u32 = 183;
pub const ERROR_NO_MORE_FILES: u32 = 18;

pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: windows.FILETIME,
    ftLastAccessTime: windows.FILETIME,
    ftLastWriteTime: windows.FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]WCHAR,
    cAlternateFileName: [14]WCHAR,
};

pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: DWORD,
    OffsetHigh: DWORD,
    hEvent: ?HANDLE,
};

/// One process in a Toolhelp snapshot of the system's processes.
pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]WCHAR,
};

pub const TH32CS_SNAPPROCESS: DWORD = 0x2;

/// A slim reader/writer lock and a condition variable; both start as all zeroes.
pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };

// The sizes Windows expects; a mismatch would silently corrupt every call that takes these.
comptime {
    std.debug.assert(@sizeOf(WIN32_FIND_DATAW) == 592);
    std.debug.assert(@sizeOf(SYSTEMTIME) == 16);
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(STARTUPINFOW) == 104);
        std.debug.assert(@sizeOf(STARTUPINFOEXW) == 112);
        std.debug.assert(@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144);
        std.debug.assert(@sizeOf(OVERLAPPED) == 32);
        std.debug.assert(@sizeOf(PROCESSENTRY32W) == 568);
    }
}

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn LockFileEx(hFile: HANDLE, dwFlags: DWORD, dwReserved: DWORD, nNumberOfBytesToLockLow: DWORD, nNumberOfBytesToLockHigh: DWORD, lpOverlapped: *OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn UnlockFileEx(hFile: HANDLE, dwReserved: DWORD, nNumberOfBytesToUnlockLow: DWORD, nNumberOfBytesToUnlockHigh: DWORD, lpOverlapped: *OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: *const anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*SECURITY_ATTRIBUTES, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: c_int, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetSystemTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn SystemTimeToFileTime(lpSystemTime: *const SYSTEMTIME, lpFileTime: *windows.FILETIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn SleepConditionVariableSRW(ConditionVariable: *CONDITION_VARIABLE, SRWLock: *SRWLOCK, dwMilliseconds: DWORD, Flags: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn WakeAllConditionVariable(ConditionVariable: *CONDITION_VARIABLE) callconv(.winapi) void;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?windows.HMODULE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFullPathNameW(lpFileName: [*:0]const u16, nBufferLength: DWORD, lpBuffer: [*]u16, lpFilePart: ?*?[*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentDirectoryW(nBufferLength: DWORD, lpBuffer: [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: i64, lpNewFilePointer: ?*i64, dwMoveMethod: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileTime(hFile: HANDLE, lpCreationTime: ?*windows.FILETIME, lpLastAccessTime: ?*windows.FILETIME, lpLastWriteTime: ?*windows.FILETIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn FileTimeToSystemTime(lpFileTime: *const windows.FILETIME, lpSystemTime: *SYSTEMTIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn SystemTimeToTzSpecificLocalTime(lpTimeZoneInformation: ?*const anyopaque, lpUniversalTime: *const SYSTEMTIME, lpLocalTime: *SYSTEMTIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?[*]u8, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ExitProcess(uExitCode: c_uint) callconv(.winapi) noreturn;
