const std = @import("std");
const Io = std.Io;

const valid_args = [_][]const u8{ "all", "repeat", "clear", "mul", "scan", "offs" };
pub var value = std.StringHashMap(bool).init(std.heap.page_allocator);

const Error = error{ ParseError, TooManyArgs, FileNotGiven };

pub fn parse(argv: []const []const u8, cwd: Io.Dir, io: Io) !Io.File {
    var file_param: bool = true;
    var source_file: ?Io.File = null;
    for (argv[1..]) |s| {
        if (s[0] == '-') {
            const flag = s[1..];
            if (!find(valid_args[0..], flag))
                return Error.ParseError;
            try value.put(flag, true);
        } else if (file_param) {
            source_file = try Io.Dir.openFile(cwd, io, s, .{ .mode = .read_only });
            file_param = false;
        } else {
            return Error.TooManyArgs;
        }
    }

    if (source_file) |file| {
        return file;
    } else {
        return Error.FileNotGiven;
    }
}

fn find(args: []const []const u8, target: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, target)) {
            return true;
        }
    }
    return false;
}
