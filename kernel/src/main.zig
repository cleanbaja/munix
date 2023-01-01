const std = @import("std");
const limine = @import("limine");
const logger = std.log.scoped(.main);

// modules
pub const arch = @import("x86_64/arch.zig");
pub const acpi = @import("acpi.zig");
pub const pmm = @import("pmm.zig");
pub const vmm = @import("vmm.zig");
pub const smp = @import("smp.zig");

pub export var terminal_request: limine.TerminalRequest = .{};
var log_buffer: [16 * 4096]u8 = undefined;
var limine_terminal_cr3: u64 = 0;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buffer = std.io.fixedBufferStream(&log_buffer);
    var writer = buffer.writer();

    if (scope != .default) {
        switch (level) {
            .warn => {
                writer.print("{s}: (\x1b[33mwarn\x1b[0m) ", .{@tagName(scope)}) catch unreachable;
            },
            .err => {
                writer.print("{s}: (\x1b[31merr\x1b[0m) ", .{@tagName(scope)}) catch unreachable;
            },
            else => {
                writer.print("{s}: ", .{@tagName(scope)}) catch unreachable;
            },
        }
    }

    writer.print(fmt ++ "\n", args) catch unreachable;

    var old_pagetable: u64 = arch.paging.saveSpace();
    defer arch.paging.loadSpace(old_pagetable);
    arch.paging.loadSpace(limine_terminal_cr3);

    if (terminal_request.response) |resp| {
        resp.write(null, buffer.getWritten());
    }
}

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    _ = stack_trace;
    _ = return_addr;

    std.log.err("\n<-------------- \x1b[31mKERNEL PANIC\x1b[0m -------------->", .{});
    std.log.err("The munix kernel panicked with the following message...", .{});
    std.log.err("    \"{s}\"", .{message});
    std.log.err("Stacktrace: ", .{});

    var stack_iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    while (stack_iter.next()) |addr| {
        std.log.err("    > 0x{X:0>16} (??:0)", .{addr});
    }

    while (true) {
        asm volatile ("hlt");
    }
}

export fn entry() callconv(.C) noreturn {
    limine_terminal_cr3 = arch.paging.saveSpace();
    logger.info("hello from munix!", .{});

    arch.setupCpu();
    pmm.init();
    vmm.init();
    acpi.init();
    arch.ic.setup();

    @panic("init complete, end of kernel reached!");
}
