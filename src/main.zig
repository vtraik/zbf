const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Command = union(enum) {
    add_data: u8,
    add_ptr: u16, // addr space: 2^16
    mul: struct { // mul(x,y) := mem[ptr + x] += mem[ptr] * y
        x: u16,
        y: u8,
    },
    clear,
    out_byte,
    in_byte,
    loop_start: usize,
    loop_end: usize,
};

// map file input to commands, modulo arithmetic (256, 65536)
fn mapToCommands(alloc: Allocator, code: []const u8) ![]Command {
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(alloc);

    for (code) |c| {
        const cmd: Command = switch (c) {
            '>' => .{ .add_ptr = 1 },

            '<' => .{ .add_ptr = 65535 },

            '+' => .{ .add_data = 1 },

            '-' => .{ .add_data = 255 },

            '.' => .{ .out_byte = {} },
            ',' => .{ .in_byte = {} },

            '[' => .{ .loop_start = 0 },
            ']' => .{ .loop_end = 0 },
            else => continue,
        };
        try commands.append(alloc, cmd);
    }

    return commands.toOwnedSlice(alloc);
}

// optimize repeats to singular commands
fn optimizeRepeat(alloc: Allocator, commands_ptr: *[]Command) !void {
    var commands: []Command = commands_ptr.*;
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < commands.len) {
        switch (commands[read_idx]) {
            .add_data => {
                // repeating + or -
                var inc_value: u8 = 0;
                while (read_idx < commands.len and
                    commands[read_idx] == .add_data) : (read_idx += 1)
                {
                    inc_value +%= commands[read_idx].add_data;
                }

                commands[write_idx] = .{ .add_data = inc_value };
                write_idx += 1;
            },
            .add_ptr => {
                // repeating > or <
                var shift_value: u16 = 0;
                while (read_idx < commands.len and
                    commands[read_idx] == .add_ptr) : (read_idx += 1)
                {
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

// [-], [+], [---], [+++], ...  => clear command
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
            if (c1 == .loop_start and c2 == .add_data and c3 == .loop_end and c2.add_data % 2 == 1) {
                commands[write_idx] = .clear;
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

fn validRange(start: usize, end: usize, commands: []Command) bool {
    var idx = start;
    while (idx < end) : (idx += 1) {
        if (commands[idx] != .add_data and commands[idx] != .add_ptr and commands[idx] != .clear and commands[idx] != .mul)
            return false;
    }
    return true;
}

fn simulateLoop(alloc: Allocator, start_lidx: usize, end_lidx: usize, commands: []Command) !?std.AutoHashMap(u16, u8) {
    var ptr: u16 = 0;
    var pc: usize = start_lidx + 1;
    // <base_off, val>
    var delta = std.AutoHashMap(u16, u8).init(alloc);

    while (pc < end_lidx) : (pc += 1) {
        switch (commands[pc]) {
            .add_ptr => |v| ptr +%= v,
            .add_data => |v| {
                const entry = try delta.getOrPut(ptr);
                if (!entry.found_existing)
                    entry.value_ptr.* = 0;
                entry.value_ptr.* +%= v;
            },
            else => {
                defer delta.deinit();
                return null;
            },
        }
    }

    // ptr is in start pos and starting cell net diff -1 => mult loop
    if (ptr != 0 or (delta.get(0) orelse 0) != -1) { // if change == -1 => delta(0): 255 = all 1's = -1
        defer delta.deinit();
        return null;
    }

    _ = delta.remove(0);

    // 0: nd, 1: nd, 2: nd ...
    // m(x,y) := mem[ptr + delta.key] += mem[ptr] * delta.val
    return delta;
}

// [->+++>+++++++<<] => mul(x,y) command
//     ^     ^
//     |     |
// ____x_____y______
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
                if (!validRange(open_idx + 1, new_commands.items.len - 1, new_commands.items)) continue :label;

                // check if mult loop <=> simulate loop
                var offs_and_factors =
                    try simulateLoop(alloc, open_idx, new_commands.items.len, new_commands.items) orelse continue :label;
                defer offs_and_factors.deinit();

                // is mult loop => make mult instructions
                new_commands.shrinkRetainingCapacity(open_idx); // back to '[' to overwrite from there
                var it = offs_and_factors.iterator();
                while (it.next()) |entry| {
                    try new_commands.append(alloc, .{ .mul = .{ .x = entry.key_ptr.*, .y = entry.value_ptr.* } });
                }
                try new_commands.append(alloc, .clear);
            },
            else => continue :label,
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
                const open_idx = stack.pop() orelse return error.UnmatchedLoopClose;

                commands[close_idx].loop_end = open_idx + 1;
                commands[open_idx].loop_start = close_idx + 1;
            },
            else => continue,
        }
    }
}

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
            .add_data => |val| mem[ptr] +%= val,
            .add_ptr => |val| ptr +%= val,
            .clear => mem[ptr] = 0,
            .mul => |p| {
                mem[ptr + p.x] += mem[ptr] * p.y;
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
            .in_byte => {
                const byte = try reader.takeByte();
                mem[ptr] = byte;
            },
            .out_byte => {
                // std.debug.print("Im writing byte {}\n", .{mem[ptr]});
                try writer.writeByte(mem[ptr]);
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

    if (args.len != 2) {
        std.debug.print("Usage: {s} <file>\n", .{args[0]});
        std.process.exit(1);
    }

    const source_file = try Io.Dir.openFile(cwd, io, args[1], .{ .mode = .read_only });
    defer source_file.close(io);

    const code = try Io.Dir.readFileAlloc(cwd, io, args[1], allocator, .limited(std.math.maxInt(u32)));
    defer allocator.free(code);

    // get commands
    var commands: []Command = try mapToCommands(allocator, code);

    // (optimize: repeats, clear([-]))
    try optimizeRepeat(allocator, &commands);
    try optimizeClear(allocator, &commands);
    commands = try optimizeMul(allocator, commands);

    // calc loop indx
    try calcLoops(allocator, &commands);

    // execute
    try execute(io, commands);
}
