const std = @import("std");

const btree_page_header_t = struct {
    page_type: u8,
    freeblock_start: u16,
    no_of_cells: u16,
    cellcontent_start: u16,
    frag_byte_count: u8,
    r_pointer: ?u32, // optional present only for internal nodes

    pub fn parse(self: *btree_page_header_t, raw_page: []const u8) void {
        self.page_type = std.mem.readInt(u8, raw_page[0..1], .big);
        self.freeblock_start = std.mem.readInt(u16, raw_page[1..3], .big);
        self.no_of_cells = std.mem.readInt(u16, raw_page[3..5], .big);
        self.cellcontent_start = std.mem.readInt(u16, raw_page[5..7], .big);
        self.frag_byte_count = raw_page[7];
        self.r_pointer = if (raw_page[0] == 0x13)
            std.mem.readInt(u32, raw_page[8..12], .big)
        else
            null;
    }
};

const btree_page_table_t = struct {
    page_header: btree_page_header_t,
    data: []u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.io.getStdErr().writer().print("Usage: {s} <database_file_path> <command>\n", .{args[0]});
        return;
    }

    const database_file_path: []const u8 = args[1];
    const command: []const u8 = args[2];

    if (std.mem.eql(u8, command, ".dbinfo")) {
        var file = try std.fs.cwd().openFile(database_file_path, .{});
        defer file.close();

        var buf: [2]u8 = undefined;
        _ = try file.seekTo(16);
        _ = try file.read(&buf);

        const page_size = std.mem.readInt(u16, &buf, .big);
        try std.io.getStdOut().writer().print("database page size: {}\n", .{page_size});

        std.debug.assert(page_size == 4096);
        const table_count = btree_walk(file);
        try std.io.getStdOut().writer().print("number of tables: {!}\n", .{table_count});
    }
}

pub fn btree_walk(file: std.fs.File) !u32 {
    var page_buf: [4096]u8 = undefined;
    _ = try file.seekTo(100);
    _ = try file.read(&page_buf);

    var page: btree_page_table_t = undefined;
    page.page_header.parse(&page_buf);
    const header_size_outer: u8 = if (page.page_header.r_pointer != null) 12 else 8;
    page.data = page_buf[header_size_outer..];

    var count: u32 = 0;
    if (page.page_header.page_type == 0x0D) {
        count = page.page_header.no_of_cells;
    }
    const allocator = std.heap.page_allocator;
    var stack = std.ArrayList(btree_page_table_t).init(allocator);
    defer stack.deinit();

    try stack.append(page);
    while (stack.items.len != 0) {
        //std.debug.print("in here {} {}", .{ count, stack.items[0] });
        count += 1;
        var page_popped = stack.pop();
        const header_size: u8 = if (page_popped.page_header.r_pointer != null) 12 else 8;
        if (page_popped.page_header.page_type == 0x05) {
            const truncated = page_popped.data[0 .. page_popped.page_header.no_of_cells * 2];

            const aligned_ptr: *const u16 = @ptrCast(@alignCast(truncated.ptr));

            const cell_pointer_ptr: [*]const u16 = @ptrCast(aligned_ptr);
            const cell_pointer_array: []const u16 = cell_pointer_ptr[0..page_popped.page_header.no_of_cells];

            for (cell_pointer_array) |value| {
                const file_offset: u16 = value;

                const number_arr: *const [4]u8 = @ptrCast(&page.data[(file_offset - header_size) .. (file_offset - header_size) + 4]);
                const page_number = std.mem.readInt(u32, number_arr, .big);

                const bitmask_read = 0b01111111;
                const bitmask = 0b10000000;
                var key: u64 = 0; // stores the key value

                for (page.data[(file_offset - header_size) + 4 ..], 0..9) |varint_part, index| {
                    const temp = varint_part & bitmask_read; // Extract the lower 7 bits
                    key |= (@as(u64, temp) << @truncate(index * 7)); // Ensure it fits u6

                    if ((varint_part & bitmask) == 0 and index >= 8) { // Stop if MSB is 0 or max bytes read
                        break;
                    }
                }

                var page_buf_under: [4096]u8 = undefined;
                _ = try file.seekTo((page_number - 1) * 4096);
                _ = try file.read(&page_buf_under);

                var page_under: btree_page_table_t = undefined;
                page_under.page_header.parse(&page_buf_under);
                const header_size_under: u8 = if (page_under.page_header.r_pointer != null) 12 else 8;
                page_under.data = page_buf_under[header_size_under..];

                try stack.append(page_under);
            }
        }
    }

    return count - 1;
}
