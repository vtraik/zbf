const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Command = union(enum) {
    add_data: u8,
    add_ptr: u16, // addr space: 2^16
    // clear (optimiz: [-])
    out_byte,
    in_byte,
    jump_start: usize,
    jump_end: usize,
};

// map file input to commands, modulo arithmetic (256, 65536)
// fn mapToCommands(aloc: Allocator, code: []const u8) ![]Command {
//     var commands: std.ArrayList(Command) = .empty;
//     defer commands.deinit(aloc);
//
//     for (code) |c| {
//         const command: Command = switch (c) {
//             '>' => .{ .add_ptr = 1 },
//             '<' => .{ .add_ptr = 65535 },
//             '+' => .{ .add_data = 1 },
//             '-' => .{ .add_data = 255 },
//             '.' => .out_byte,
//             ',' => .in_byte,
//             '[' => undefined,
//             ']' => undefined,
//             else => continue,
//         };
//         try commands.append(aloc, command);
//     }
//
//     return commands.toOwnedSlice(aloc);
// }
//
// fn addLoops(commands: []Command) !void {
//
// }
//
// fn execute(commands: []Command) !void {
//
// }

// [> + -, - < ] -> jf inc + - out in - < jb

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

    std.debug.print("{s}\n", .{code});

    // get commands
    // var commands: []Command = try mapToCommands(allocator, code);

    // (optimize: repeats, clear([-]))

    // link_loops (start,end)
    // try addLoops(commands);
    // execute
    // try execute(commands);
}
