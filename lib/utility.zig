// set log level by build type
pub const default_level: std.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

const Error = error{
    StringToLong,
    AccountNotFound,
    NoMemory,
    UnableToOpen,
};

const std = @import("std");
const win32 = @import("win32").everything;
const win32_security = @import("win32").security;

// This exists until zigwin32 is updated to enable bitmasks for DesiredAccess /-:
extern "advapi32" fn OpenProcessToken(
    ProcessHandle: ?win32.HANDLE,
    DesiredAccess: win32_security.TOKEN_ACCESS_MASK,
    TokenHandle: ?*?win32.HANDLE,
) callconv(std.os.windows.WINAPI) win32.BOOL;

pub fn closeHandle(handle: ?win32.HANDLE) void {
    if (handle != null and handle.? != win32.INVALID_HANDLE_VALUE) {
        // https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-closehandle
        _ = win32.CloseHandle(handle.?);
    }
}

pub fn miniDumpPID(allocator: std.mem.Allocator, pid: u32, outfile: []u8) !void {
    const lpFileName = try std.fmt.allocPrintZ(allocator, "{s}", .{outfile});
    errdefer allocator.free(lpFileName);

    const outFileH: ?win32.HANDLE = win32.CreateFileA(
        lpFileName,
        win32.FILE_WRITE_DATA,
        win32.FILE_SHARE_NONE,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    defer closeHandle(outFileH);

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
    const processH = win32.OpenProcess(
        win32.PROCESS_ALL_ACCESS,
        0,
        pid,
    );
    defer closeHandle(processH);

    if (processH == null) {
        return Error.UnableToOpen;
    }

    var tokenH: ?win32.HANDLE = null;

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
    const hProcess: ?win32.HANDLE = win32.GetCurrentProcess();
    defer _ = closeHandle(hProcess);

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
    if (0 == OpenProcessToken(
        hProcess,
        win32_security.TOKEN_ADJUST_PRIVILEGES,
        &tokenH,
    )) {
        std.log.err("[!] Failed OpenProcessToken :: error code ({d})", .{@intFromEnum(win32.GetLastError())});
        return Error.NoMemory;
    }

    if (!tryEnablePrivilege(
        hProcess,
        win32.SE_DEBUG_NAME,
        &tokenH,
    )) {
        return Error.AccountNotFound;
    }

    // https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump
    if (std.os.windows.FALSE == win32.MiniDumpWriteDump(
        processH,
        pid,
        outFileH,
        win32.MiniDumpWithFullMemory,
        null,
        null,
        null,
    )) {
        return Error.UnableToOpen;
    }
}

pub fn tryEnablePrivilege(hProcess: ?win32.HANDLE, lpName: ?[*:0]const u8, tokenHandle: *?win32.HANDLE) bool {
    var tp: win32.TOKEN_PRIVILEGES = undefined;
    var luid: win32.LUID = undefined;

    // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupprivilegevaluea
    if (0 == win32.LookupPrivilegeValueA(
        null, //    [in, optional] LPCSTR lpSystemName,
        lpName, //        [in]           LPCSTR lpName,
        &luid, //         [out]          PLUID  lpLuid
    )) {
        std.log.err("[!] Failed LookupPrivilegeValueA :: error code ({d})", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    tp.PrivilegeCount = 1;
    tp.Privileges[0].Luid = luid;
    tp.Privileges[0].Attributes = win32.SE_PRIVILEGE_ENABLED;

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess
    defer _ = closeHandle(hProcess);

    var da: u32 = @bitCast(win32_security.TOKEN_ADJUST_PRIVILEGES);
    da |= @bitCast(win32_security.TOKEN_QUERY);

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
    if (0 == win32.OpenProcessToken(
        hProcess.?, //                [in]  HANDLE  ProcessHandle,
        @bitCast(da), //   [in]  DWORD   DesiredAccess,
        tokenHandle, //                 [out] PHANDLE TokenHandle
    )) {
        std.log.err("[!] Failed OpenProcessToken :: error code ({d})", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    // https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges
    if (0 == win32.AdjustTokenPrivileges(
        tokenHandle.*, //                    [in]            HANDLE            TokenHandle,
        0, //       [in]            BOOL              DisableAllPrivileges,
        &tp, //                                 [in, optional]  PTOKEN_PRIVILEGES NewState,
        @sizeOf(win32.TOKEN_PRIVILEGES), // [in]            DWORD             BufferLength,
        null, //                           [out, optional] PTOKEN_PRIVILEGES PreviousState,
        null, //                            [out, optional] PDWORD            ReturnLength
    )) {
        const result = @intFromEnum(win32.GetLastError());
        if (result == @intFromEnum(win32.WIN32_ERROR.ERROR_INVALID_HANDLE)) {
            std.log.err("[!] Failed AdjustTokenPrivileges - invalid handle :: error code ({d})", .{result});
        } else {
            std.log.err("[!] Failed AdjustTokenPrivileges:: error code ({d})", .{result});
        }

        return false;
    }

    const result = @intFromEnum(win32.GetLastError());
    if (result != 0) { // win32.WIN32_ERROR.ERROR_SUCCESS

        if (result == 1300) { // win32.WIN32_ERROR.ERROR_NOT_ALL_ASSIGNED
            std.log.err("[!] Failed to assign privilege :: error code ({d})", .{result});
        } else {
            std.log.err("[!] Failed to enable {s} :: error code ({d})", .{ lpName.?, result });
        }

        return false;
    }

    std.log.debug("tryEnablePrivilege success for {s}", .{lpName.?});

    return true;
}

pub fn getProcessOwnerSID(allocator: std.mem.Allocator, hToken: ?win32.HANDLE) !*?[]u64 {
    var dwSize: u32 = 0;

    // https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
    if (0 == win32.GetTokenInformation(hToken, win32.TokenUser, null, 0, &dwSize) and win32.GetLastError() != win32.ERROR_INSUFFICIENT_BUFFER) {
        std.log.err("getProcessOwnerSID:GetTokenInformation failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
        closeHandle(hToken);
        return Error.AccountNotFound;
    }

    // Allocate memory for the token information
    var ptu = allocator.alloc(u8, dwSize) catch |err| {
        std.log.err("Memory allocation failed. {any}\n", .{err});
        closeHandle(hToken);
        return Error.AccountNotFound;
    };

    // https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
    if (0 == win32.GetTokenInformation(hToken, win32.TokenUser, @ptrCast(&ptu), dwSize, &dwSize)) {
        std.log.err("GetCurrentUserSid:GetTokenInformation failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
        closeHandle(hToken);
        return Error.AccountNotFound;
    }

    const pTokenUser: *win32.TOKEN_USER = @ptrCast(&ptu);

    // https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getlengthsid
    dwSize = win32.GetLengthSid(pTokenUser.*.User.Sid);

    // TODO: https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-isvalidsid ?
    std.log.debug("dwSize :: {d}\n", .{dwSize});

    // Allocate memory for the SID
    var ppSid: ?*win32.PSID = undefined;
    var u64ppSid: ?[]u64 = try allocator.alloc(u64, dwSize);
    ppSid.? = @ptrCast(&u64ppSid);

    // https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-copysid
    if (0 == win32.CopySid(dwSize, ppSid.?.*, pTokenUser.*.User.Sid)) {
        std.log.err("GetCurrentUserSid:CopySid failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
        closeHandle(hToken);
        return Error.AccountNotFound;
    }

    // var sida: ?win32.PSTR = null;

    // // https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsidtostringsida
    // if (0 == win32.ConvertSidToStringSidA(ppSid.?.*, &sida)) {
    //     std.log.err("ConvertSidToStringSidA:CopySid failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
    //     closeHandle(hToken);
    //     return Error.AccountNotFound;
    // }

    // std.log.debug("SID: {s}\n", .{sida.?});
    // if (win32.LocalFree(sida) != null) {
    //     std.log.err("LocalFree failed {d}\n", .{@intFromEnum(win32.GetLastError())});
    // }

    return &u64ppSid;
}
