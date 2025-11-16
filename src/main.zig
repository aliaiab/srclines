pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    const gpa = std.heap.smp_allocator;

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var threaded_io: std.Io.Threaded = .init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const cwd = std.fs.cwd();
    var cwd_iterable = try cwd.openDir(".", .{
        .iterate = true,
    });
    defer cwd_iterable.close();

    var results: std.StringArrayHashMapUnmanaged(*align(64) u64) = .{};

    try walkDirectoryIter(
        gpa,
        arena,
        io,
        cwd_iterable,
        &results,
    );

    for (results.keys(), results.values()) |extension, line_count| {
        std.log.info("extension: {s}, lines: {}", .{ extension, line_count.* });
    }
}

fn walkDirectoryIter(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.fs.Dir,
    ///Map from file extensions to line counts
    results: *std.StringArrayHashMapUnmanaged(*align(64) u64),
) !void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".git")) {
                    continue;
                }

                if (std.mem.eql(u8, entry.name, ".zig_cache")) {
                    continue;
                }

                if (std.mem.eql(u8, entry.name, "zig-out")) {
                    continue;
                }

                var sub_dir_iter = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir_iter.close();

                try walkDirectoryIter(gpa, arena, io, sub_dir_iter, results);
            },
            .file => {
                const file_extension = std.fs.path.extension(entry.name);

                const counter_query = try results.getOrPut(gpa, try arena.dupe(u8, file_extension));

                if (!counter_query.found_existing) {
                    const counter = try arena.alignedAlloc(u64, .@"64", 1);

                    counter[0] = 0;

                    counter_query.value_ptr.* = @ptrCast(counter.ptr);
                }

                const file = try dir.adaptToNewApi().openFile(
                    io,
                    entry.name,
                    .{},
                );
                defer file.close(io);

                const stat = try file.stat(io);

                var reader = file.readerStreaming(io, &.{});

                const file_data = try reader.interface.readAlloc(gpa, stat.size);

                var line_count: u64 = 1;

                for (file_data) |char| {
                    if (char == '\n') {
                        line_count += 1;
                    }
                }

                counter_query.value_ptr.*.* += line_count;
            },
            else => {},
        }
    }
}

fn processFile(
    dir: std.fs.Dir,
) void {
    _ = dir; // autofix
}

const std = @import("std");
