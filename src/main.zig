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

    for (results.keys(), results.values()) |extension, line_count| {
        std.log.info("extension: {s}, lines: {}", .{ extension, line_count.* });
    }
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
                    gpa,
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
    gpa: std.mem.Allocator,
    file_name: []const u8,
    result_count: *align(64) u64,
) void {
    _ = gpa; // autofix
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
