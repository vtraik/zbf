const std = @import("std");
const parser = @import("parser.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const BfError = error{ScanLoopMissingTerm};

const Command = union(enum) {
    add_data: struct { x: u8, offs: u16 },
    add_ptr: u16, // addr space: 2^16
    mul: struct { // mul(x,y) := mem[ptr + x] += mem[ptr] * y
        x: u16,
        y: u8,
        offs: u16,
    },
    // u16 == offset
    clear: u16,
    out_byte: u16,
    in_byte: u16,
    loop_start: usize,
    loop_end: usize,
    scan_left,
    scan_right,
};

// map file input to commands, modulo arithmetic (256, 65536)
fn mapToCommands(alloc: Allocator, code: []const u8) ![]Command {
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(alloc);

    for (code) |c| {
        const cmd: Command = switch (c) {
            '>' => .{ .add_ptr = 1 },

            '<' => .{ .add_ptr = 65535 },

            '+' => .{ .add_data = .{ .x = 1, .offs = 0 } },

            '-' => .{ .add_data = .{ .x = 255, .offs = 0 } },

            '.' => .{ .out_byte = 0 },
            ',' => .{ .in_byte = 0 },

            '[' => .{ .loop_start = 0 },
            ']' => .{ .loop_end = 0 },
            else => continue,
        };
        try commands.append(alloc, cmd);
    }

    return commands.toOwnedSlice(alloc);
}

// transforms repeating sequences of +,-,<,> to singular commands
fn optimizeRepeat(alloc: Allocator, commands_ptr: *[]Command) !void {
    var commands: []Command = commands_ptr.*;
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < commands.len) {
        switch (commands[read_idx]) {
            .add_data => {
                // repeating + or -
                var inc_value: u8 = 0;
                while (read_idx < commands.len
                and fcommands[read_idx] == .add_data) : (read_idx += 1) {
                    inc_value +%= commands[read_idx].add_data.x;
                }

                commands[write_idx] = .{ .add_data = .{ .x = inc_value, .offs = 0 } };
                write_idx += 1;
            },
            .add_ptr => {
                // repeating > or <
                var shift_value: u16 = 0;
                while (read_idx < commands.len
                and commands[read_idx] == .add_ptr) : (read_idx += 1) {
                    shift_value +%= commands[read_idx].add_ptr;
                }

                commands[write_idx] = .{ .add_ptr = shift_value };
                write_idx += 1;
            },
            else => {
                // other commands
                commands[write_idx] = commands[read_idx];
                write_idx += 1;
                read_idx += 1;
            },
        }
    }
    commands_ptr.* = try alloc.realloc(commands, write_idx);
}

// transforms clear loops [-], [+], [---], [+++]... to clear instructions
fn optimizeClear(alloc: Allocator, commands_ptr: *[]Command) !void {
    var commands: []Command = commands_ptr.*;
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < commands.len) {
        if (read_idx + 2 < commands.len) {
            const c1 = commands[read_idx];
            const c2 = commands[read_idx + 1];
            const c3 = commands[read_idx + 2];

            // odd values clear eventually, even don't
            if (c1 == .loop_start and c2 == .add_data and c3 == .loop_end and c2.add_data.x % 2 == 1) {
                commands[write_idx] = .{ .clear = 0 };
                write_idx += 1;
                read_idx += 3;
                continue;
            }
        }

        commands[write_idx] = commands[read_idx];
        write_idx += 1;
        read_idx += 1;
    }

    commands_ptr.* = try alloc.realloc(commands, write_idx);
}

// checks if the range [start, end) has valid instructions for a mul loop
fn validRange(start: usize, end: usize, commands: []Command) bool {
    var idx = start;
    while (idx < end) : (idx += 1) {
        if (commands[idx] != .add_data and commands[idx] != .add_ptr)
            return false;
    }
    return true;
}

// simulates a loop to decide if it is a mult loop
fn simulateLoop(alloc: Allocator, start_lidx: usize, end_lidx: usize, commands: []Command) !?std.AutoHashMap(u16, u8) {
    var ptr: u16 = 0;
    var pc: usize = start_lidx;
    // <base_off, val>
    var delta = std.AutoHashMap(u16, u8).init(alloc);

    while (pc < end_lidx) : (pc += 1) {
        switch (commands[pc]) {
            .add_ptr => |v| ptr +%= v,
            .add_data => |v| {
                const entry = try delta.getOrPut(ptr);
                if (!entry.found_existing)
                    entry.value_ptr.* = 0;
                entry.value_ptr.* +%= v.x;
            },
            else => {
                defer delta.deinit();
                return null;
            },
        }
    }

    // ptr is in start pos and starting cell net diff -1 => mult loop
    if (ptr != 0 or (delta.get(0) orelse 0) != 255) { // if change == -1 => delta(0): 255 = all 1's = -1
        defer delta.deinit();
        return null;
    }

    _ = delta.remove(0);

    return delta;
}

// transforms mult loops [->+++>+++++++<<] to mul(x,y) := mem[ptr + x] += mem[ptr] * y
fn optimizeMul(alloc: Allocator, commands: []Command) ![]Command {
    var read_idx: usize = 0;

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(alloc);

    var new_commands: std.ArrayList(Command) = .empty;
    errdefer new_commands.deinit(alloc);

    label: while (read_idx < commands.len) : (read_idx += 1) {
        try new_commands.append(alloc, commands[read_idx]);

        // find next innermost loop
        switch (commands[read_idx]) {
            .loop_start => { // append and write to its place, should fix if this is mult loop
                try stack.append(alloc, new_commands.items.len - 1);
            },
            .loop_end => {
                const open_idx = stack.pop() orelse unreachable;
                // check for only + - > < inside range (open_idx, read_idx)
                if (!validRange(open_idx + 1, new_commands.items.len - 1, new_commands.items))
                    continue :label;

                // check if mult loop <=> simulate loop
                var offs_and_factors =
                    try simulateLoop(alloc, open_idx + 1, new_commands.items.len - 1, new_commands.items)
                    orelse continue :label;
                defer offs_and_factors.deinit();

                // is mult loop => make mult instructions
                new_commands.shrinkRetainingCapacity(open_idx); // back to '[' to overwrite from there
                var it = offs_and_factors.iterator();
                while (it.next()) |entry| {
                    try new_commands.append(alloc, .{ .mul = .{ .x = entry.key_ptr.*, .y = entry.value_ptr.*, .offs = 0 } });
                }
                try new_commands.append(alloc, .{ .clear = 0 });
            },
            else => continue :label,
        }
    }

    return try new_commands.toOwnedSlice(alloc);
}

// transforms scan loops [<] or [>] to scan instructions
fn optimizeScan(alloc: Allocator, commands_ptr: *[]Command) !void {
    var commands: []Command = commands_ptr.*;
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < commands.len) {
        if (read_idx + 2 < commands.len) {
            if (commands[read_idx] == .loop_start and commands[read_idx + 1] == .add_ptr
            and commands[read_idx + 2] == .loop_end) {
                if (commands[read_idx + 1].add_ptr == 1) {
                    commands[write_idx] = .scan_right;
                    write_idx += 1;
                    read_idx += 3;
                    continue;
                } else if (commands[read_idx + 1].add_ptr == 65535) {
                    commands[write_idx] = .scan_left;
                    write_idx += 1;
                    read_idx += 3;
                    continue;
                }
            }
        }

        commands[write_idx] = commands[read_idx];
        write_idx += 1;
        read_idx += 1;
    }
    commands_ptr.* = try alloc.realloc(commands, write_idx);
}

// suspends ptr calculations until loop_start, loop_end, scan_left, scan_right is reached
fn optimizeOffs(alloc: Allocator, commands: []Command) ![]Command {
    var read_idx: usize = 0;
    var curr_offs: u16 = 0;

    var new_commands: std.ArrayList(Command) = .empty;
    errdefer new_commands.deinit(alloc);

    while (read_idx < commands.len) : (read_idx += 1) {
        switch (commands[read_idx]) {
            .add_ptr => |v| curr_offs +%= v,
            .add_data => |p|
                try new_commands.append(alloc, .{ .add_data = .{ .x = p.x, .offs = curr_offs } }),
            .mul => |p|
                try new_commands.append(alloc, .{ .mul = .{ .x = p.x, .y = p.y, .offs = curr_offs } }),
            .clear =>
                try new_commands.append(alloc, .{ .clear = curr_offs }),
            .in_byte =>
                try new_commands.append(alloc, .{ .in_byte = curr_offs }),
            .out_byte =>
                try new_commands.append(alloc, .{ .out_byte = curr_offs }),
            inline .loop_start, .loop_end, .scan_left, .scan_right => |_, tag| {
                if (curr_offs != 0) {
                    try new_commands.append(alloc, .{ .add_ptr = curr_offs });
                    curr_offs = 0;
                }
                try new_commands.append(alloc, switch (tag) {
                    .loop_start => .{ .loop_start = 0 },
                    .loop_end => .{ .loop_end = 0 },
                    .scan_left => .scan_left,
                    .scan_right => .scan_right,
                    else => unreachable,
                });
            },
        }
    }

    return try new_commands.toOwnedSlice(alloc);
}

// calculates loop targets after optimizations
fn calcLoops(alloc: Allocator, commands_ptr: *[]Command) !void {
    var commands = commands_ptr.*;
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(alloc);

    for (commands, 0..) |c, idx| {
        switch (c) {
            .loop_start => {
                const open_idx = idx;
                try stack.append(alloc, open_idx);
            },
            .loop_end => {
                const close_idx = idx;
                const open_idx = stack.pop()
                                 orelse return error.UnmatchedLoopClose;

                commands[close_idx].loop_end = open_idx + 1;
                commands[open_idx].loop_start = close_idx + 1;
            },
            else => continue,
        }
    }
}

// executes program with 2^16 bytes mem avail
fn execute(io: std.Io, commands: []const Command) !void {
    var in_buf: [1]u8 = undefined;
    var out_buf: [1]u8 = undefined;

    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var stdout = std.Io.File.stdout().writer(io, &out_buf);

    const reader = &stdin.interface;
    const writer = &stdout.interface;

    var pc: usize = 0;
    var mem: [65536]u8 = @splat(0);
    var ptr: u16 = 0;

    while (pc < commands.len) {
        switch (commands[pc]) {
            .add_data => |p| mem[ptr +% p.offs] +%= p.x,
            .add_ptr => |val| ptr +%= val,
            .clear => |v| mem[ptr +% v] = 0,
            .mul => |p| {
                mem[ptr +% p.x +% p.offs] +%= mem[ptr +% p.offs] *% p.y;
            },
            .scan_right => {
                const off = std.mem.indexOfScalar(u8, mem[ptr..], 0)
                            orelse return BfError.ScanLoopMissingTerm;
                ptr += @intCast(off);
            },
            .scan_left => {
                const idx = std.mem.lastIndexOfScalar(u8, mem[0 .. ptr + 1], 0)
                            orelse return BfError.ScanLoopMissingTerm;
                ptr = @intCast(idx);
            },
            .loop_start => |end_idx| {
                if (mem[ptr] == 0) {
                    pc = end_idx;
                    continue;
                }
            },
            .loop_end => |start_idx| {
                if (mem[ptr] != 0) {
                    pc = start_idx;
                    continue;
                }
            },
            .in_byte => |v| {
                const byte = try reader.takeByte();
                mem[ptr +% v] = byte;
            },
            .out_byte => |v| {
                try writer.writeByte(mem[ptr +% v]);
                try writer.flush();
            },
        }
        pc += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = Io.Dir.cwd();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    const source_file = try parser.parse(args, cwd, io);
    defer source_file.close(io);

    const code = try Io.Dir.readFileAlloc(cwd, io, args[1], allocator, .limited(std.math.maxInt(u32)));
    defer allocator.free(code);

    var commands: []Command = try mapToCommands(allocator, code);

    // (optimize: repeats, clear([-]), mul, scan, offsets)
    const all: bool = parser.value.get("all") orelse false;
    if (all or (parser.value.get("repeat") orelse false))
        try optimizeRepeat(allocator, &commands);
    if (all or (parser.value.get("clear") orelse false))
        try optimizeClear(allocator, &commands);
    if (all or (parser.value.get("mul") orelse false))
        commands = try optimizeMul(allocator, commands);
    if (all or (parser.value.get("scan") orelse false))
        try optimizeScan(allocator, &commands);
    if (all or (parser.value.get("offs") orelse false))
        commands = try optimizeOffs(allocator, commands);

    try calcLoops(allocator, &commands);

    try execute(io, commands);
}
