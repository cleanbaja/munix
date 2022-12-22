const limine = @import("limine");
const std = @import("std");

const Bitmap = struct {
    bits: [*]u8,
    size: usize,
    last_free: usize = 0,

    fn check(self: *Bitmap, bit: usize) bool {
        return self.bits[bit / 8] & @as(u8, 1) << @intCast(u3, bit % 8) != 0;
    }

    fn mark(self: *Bitmap, bit: usize) void {
        self.bits[bit / 8] |= @as(u8, 1) << @intCast(u3, bit % 8);
    }

    fn markRange(self: *Bitmap, start: usize, length: usize) void {
        var i: usize = start;

        while (i < (start + length)) : (i += 1) {
            self.mark(i);
        }
    }

    fn clear(self: *Bitmap, bit: usize) void {
        self.bits[bit / 8] &= ~(@as(u8, 1) << @intCast(u3, bit % 8));
    }

    fn clearRange(self: *Bitmap, start: usize, length: usize) void {
        var i: usize = start;

        while (i < (start + length)) : (i += 1) {
            self.clear(i);
        }
    }

    fn findFreeRange(self: *Bitmap, pages: usize, step_size: usize) ?u64 {
        var i: usize = std.mem.alignBackward(self.last_free, step_size);

        while (i < self.size * 8) : (i += step_size) {
            if (self.check(i)) {
                var found = find_pages: {
                    var j: usize = 1;
                    while (j < pages) : (j += 1) {
                        if (!self.check(i + j)) {
                            break :find_pages false;
                        }
                    }
                    break :find_pages true;
                };

                if (found) {
                    self.last_free = i + pages;
                    return i;
                }
            }
        }

        if (self.last_free != 0) {
            self.last_free = 0;
            return self.findFreeRange(pages, step_size);
        } else {
            return null;
        }
    }
};

// TODO(cleanbaja): move this constants somewhere else in the
// next refactor (proably arch.zig)
pub const HIGHER_HALF: u64 = 0xFFFF800000000000;
pub const PAGE_SIZE = 4096;

pub export var memmap_request: limine.MemoryMapRequest = .{};
var global_bitmap: Bitmap = undefined;

fn getKindName(kind: anytype) []const u8 {
    return switch (kind) {
        .usable => "usable",
        .reserved => "reserved",
        .acpi_reclaimable => "reclaimable (acpi)",
        .acpi_nvs => "acpi nvs",
        .bad_memory => "bad memory",
        .bootloader_reclaimable => "reclaimable (bootloader)",
        .kernel_and_modules => "kernel and modules",
        .framebuffer => "framebuffer",
    };
}

pub fn init() void {
    const sink = @import("std").log.scoped(.pmm);
    var highest_addr: u64 = 0;

    if (memmap_request.response) |resp| {
        sink.info("dumping memory map entries...", .{});

        // find highest addr (and dump memory map)
        for (resp.entries()) |ent| {
            sink.info("\tBase: {X:0>16}, Length: {X:0>8}, Type: {s}", .{ ent.base, ent.length, getKindName(ent.kind) });
            highest_addr = std.math.max(highest_addr, ent.base + ent.length);
        }

        // find the size of the bitmap
        var n_bits = highest_addr / PAGE_SIZE;
        var n_bytes = std.mem.alignForward((n_bits / 8), PAGE_SIZE);

        // find a entry that can hold the bitmap
        for (resp.entries()) |ent| {
            if (ent.length > n_bytes) {
                ent.base += n_bytes;
                ent.length -= n_bytes;

                global_bitmap.bits = @intToPtr([*]u8, ent.base + HIGHER_HALF);
                global_bitmap.size = n_bytes;
            }
        }

        // clear the bitmap to all 0xFFs (reserved)
        @memset(global_bitmap.bits, std.math.maxInt(u8), n_bytes);

        // mark usable ranges in the global_bitmap
        for (resp.entries()) |ent| {
            if (ent.kind == .usable) {
                global_bitmap.clearRange(ent.base / PAGE_SIZE, ent.length / PAGE_SIZE);
            }
        }

        // finally, mark the bitmap itself as used
        global_bitmap.markRange((@ptrToInt(global_bitmap.bits) - HIGHER_HALF) / PAGE_SIZE, n_bytes / PAGE_SIZE);
    } else {
        sink.err("bootloader did not pass memory map!", .{});
        while (true) {}
    }
}

pub fn allocPages(count: usize) ?u64 {
    return global_bitmap.findFreeRange(count, 1) * PAGE_SIZE orelse null;
}

pub fn allocHugePages(count: usize) ?u64 {
    return global_bitmap.findFreeRange(count * 0x200, 0x200) * PAGE_SIZE orelse null;
}

pub fn freePages(ptr: usize, count: usize) void {
    global_bitmap.clearRange(ptr / PAGE_SIZE, count);
}