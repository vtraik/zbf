const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Command = union(enum) {
    add_data: u8,
    add_ptr: u16, // addr space: 2^16
    // clear (optimiz: [-])
    out_byte,
    in_byte,
    loop_start: usize,
    loop_end: usize,
};

// map file input to commands, modulo arithmetic (256, 65536)
fn mapToCommands(aloc: Allocator, code: []const u8) ![]Command {
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(aloc);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(aloc);

    for (code) |c| {
        switch (c) {
            '>' => try commands.append(aloc, .{ .add_ptr = 1 }),

            '<' => try commands.append(aloc, .{ .add_ptr = 65535 }),

            '+' => try commands.append(aloc, .{ .add_data = 1 }),

            '-' => try commands.append(aloc, .{ .add_data = 255 }),

            '.' => try commands.append(aloc, .{ .out_byte = {} }),
            ',' => try commands.append(aloc, .{ .in_byte = {} }),

            '[' => {
                const open_idx = commands.items.len;
                try stack.append(aloc, open_idx);
                try commands.append(aloc, .{ .loop_start = undefined });
            },
            ']' => {
                const close_idx = commands.items.len;
                const open_idx = stack.pop() orelse return error.UnmatchedLoopClose;

                try commands.append(aloc, .{ .loop_end = open_idx + 1 });
                commands.items[open_idx].loop_start = close_idx + 1;
            },
            else => continue,
        }
    }

    return commands.toOwnedSlice(aloc);
}

// optimize repeats to singular commands
// fn optimize(aloc: Allocator, commands_ptr: *[]Command) !void {
//     var commands: []Command = commands_ptr.*;
//     var read_idx: usize = 0;
//     var write_idx: usize = 0;
//
//     while (read_idx < commands.len) {
//         switch (commands[read_idx]) {
//             .add_data => {
//                 // repeating + or -
//                 var inc_value: u8 = 0;
//                 while (read_idx < commands.len and
//                     commands[read_idx] == .add_data) : (read_idx += 1)
//                 {
//                     inc_value +%= commands[read_idx].add_data;
//                 }
//
//                 commands[write_idx] = .{ .add_data = inc_value };
//                 write_idx += 1;
//             },
//             .add_ptr => {
//                 // repeating > or <
//                 var shift_value: u16 = 0;
//                 while (read_idx < commands.len and
//                     commands[read_idx] == .add_ptr) : (read_idx += 1)
//                 {
//                     shift_value +%= commands[read_idx].add_ptr;
//                 }
//
//                 commands[write_idx] = .{ .add_ptr = shift_value };
//                 write_idx += 1;
//             },
//             else => {
//                 // other commands
//                 // std.debug.print("wr = {d} | re = {d}\n", .{ write_idx, read_idx });
//                 commands[write_idx] = commands[read_idx];
//                 write_idx += 1;
//                 read_idx += 1;
//             },
//         }
//     }
//     commands_ptr.* = try aloc.realloc(commands, write_idx);
// }

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
                try writer.writeByte(mem[ptr]);
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
        // const stderr = io.getStdErr().writer();
        std.debug.print("Usage: {s} <file>\n", .{args[0]});
        std.process.exit(1);
    }

    const source_file = try Io.Dir.openFile(cwd, io, args[1], .{ .mode = .read_only });
    defer source_file.close(io);

    const code = try Io.Dir.readFileAlloc(cwd, io, args[1], allocator, .limited(std.math.maxInt(u32)));
    defer allocator.free(code);

    // get commands
    const commands: []Command = try mapToCommands(allocator, code);

    // (optimize: repeats, clear([-]))
    // try optimize(allocator, &commands);

    // execute
    try execute(io, commands);
}
