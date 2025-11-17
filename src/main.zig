pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var root_directory: []const u8 = ".";

    var ignored_files: std.StringArrayHashMapUnmanaged(void) = .{};
    try ignored_files.put(gpa, ".git", {});

    {
        var cli_args = std.process.args();

        _ = cli_args.next();

        while (cli_args.next()) |arg| {
            root_directory = arg;
        }
    }

    var stdout_file = std.fs.File.stdout();

    var stdout_buffer: [1024 * 4]u8 = undefined;

    var stdout_writer = stdout_file.writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var threaded_io: std.Io.Threaded = .init(gpa);
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const cwd = std.fs.cwd();

    blk: {
        const gitignore_file = cwd.openFile(".gitignore", .{}) catch |e| {
            switch (e) {
                error.FileNotFound => break :blk,
                else => return e,
            }
        };
        defer gitignore_file.close();

        const gitignore_stat = try gitignore_file.stat();

        const gitignore_data = try gpa.alloc(u8, gitignore_stat.size);
        defer gpa.free(gitignore_data);

        _ = try gitignore_file.read(gitignore_data);

        var token_iter = std.mem.tokenizeScalar(u8, gitignore_data, '\n');

        while (token_iter.next()) |ignore_entry| {
            try ignored_files.put(gpa, try gpa.dupe(u8, std.fs.path.basename(ignore_entry)), {});
        }
    }

    var cwd_iterable = try cwd.openDir(root_directory, .{
        .iterate = true,
    });
    defer cwd_iterable.close();

    var results: std.StringArrayHashMapUnmanaged(*align(64) u64) = .{};

    var result_group: std.Io.Group = .init;

    try walkDirectoryIter(
        gpa,
        arena,
        io,
        &result_group,
        cwd_iterable,
        &ignored_files,
        &results,
    );

    result_group.wait(io);

    const LineCountResult = struct {
        lines: u64,
        index: usize,

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.lines > rhs.lines;
        }
    };

    var result_buffer = try gpa.alloc(LineCountResult, results.count());
    defer gpa.free(result_buffer);

    for (results.keys(), results.values(), 0..) |extension, line_count, i| {
        _ = extension; // autofix
        result_buffer[i] = .{ .index = i, .lines = line_count.* };
    }

    std.sort.insertion(
        LineCountResult,
        result_buffer,
        {},
        LineCountResult.lessThan,
    );

    for (result_buffer) |result| {
        try stdout.print("  extension: {s}, lines: {}\n", .{ results.keys()[result.index], result.lines });
    }

    try stdout.flush();
}

fn walkDirectoryIter(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    group: *std.Io.Group,
    dir: std.fs.Dir,
    ignored_files: *std.StringArrayHashMapUnmanaged(void),
    ///Map from file extensions to line counts
    results: *std.StringArrayHashMapUnmanaged(*align(64) u64),
) !void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (ignored_files.get(entry.name)) |_| {
            continue;
        }

        switch (entry.kind) {
            .directory => {
                const sub_dir_iter = try dir.openDir(entry.name, .{ .iterate = true });
                // defer sub_dir_iter.close();

                try walkDirectoryIter(
                    gpa,
                    arena,
                    io,
                    group,
                    sub_dir_iter,
                    ignored_files,
                    results,
                );
            },
            .file => {
                const file_extension = std.fs.path.extension(entry.name);

                const counter_query = try results.getOrPut(gpa, try arena.dupe(u8, file_extension));

                if (!counter_query.found_existing) {
                    const counter = try arena.alignedAlloc(u64, .@"64", 1);

                    counter[0] = 0;

                    counter_query.value_ptr.* = @ptrCast(counter.ptr);
                }

                group.async(io, processFile, .{
                    io,
                    dir,
                    try arena.dupe(u8, entry.name),
                    counter_query.value_ptr.*,
                });
            },
            else => {},
        }
    }
}

fn processFile(
    io: std.Io,
    dir: std.fs.Dir,
    file_name: []const u8,
    result_count: *align(64) u64,
) void {
    const file = dir.adaptToNewApi().openFile(
        io,
        file_name,
        .{},
    ) catch unreachable;
    defer file.close(io);

    const stat = file.stat(io) catch unreachable;

    var reader = file.readerStreaming(io, &.{});

    const file_data = reader.interface.readAlloc(std.heap.page_allocator, stat.size) catch unreachable;
    defer std.heap.page_allocator.free(file_data);

    var line_count: u64 = 0;

    const vec_len = comptime std.simd.suggestVectorLength(u8).?;

    const vec_count = file_data.len / vec_len;

    var char_index: usize = 0;

    for (0..vec_count) |vec_index| {
        const vec_ptr: *@Vector(vec_len, u8) = @ptrCast(@alignCast(file_data.ptr + vec_index * vec_len));
        const vec: @Vector(vec_len, u8) = vec_ptr.*;
        const vec_new_line: @Vector(vec_len, u8) = @splat('\n');

        const vec_cmp = vec == vec_new_line;

        line_count += std.simd.countTrues(vec_cmp);

        char_index += vec_len;
    }

    for (file_data[char_index..]) |char| {
        if (char == '\n') {
            line_count += 1;
        }
    }

    _ = @atomicRmw(u64, result_count, .Add, line_count, .acq_rel);
}

const std = @import("std");
