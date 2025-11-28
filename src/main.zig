pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var root_directory: []const u8 = ".";
    var list_mode: bool = false;

    var ignored_files: std.StringArrayHashMapUnmanaged(void) = .{};
    try ignored_files.put(gpa, ".git", {});

    var extension_whitelist: std.StringArrayHashMapUnmanaged(void) = .{};

    {
        var cli_args = std.process.args();

        _ = cli_args.next();

        while (cli_args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-e")) {
                const ext = cli_args.next().?;

                try extension_whitelist.put(gpa, ext, {});
            } else if (std.mem.eql(u8, arg, "-l")) {
                list_mode = true;
            } else {
                root_directory = arg;
            }
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

    const root_file = try cwd.openFile(root_directory, .{});

    const root_file_stat = try root_file.stat();

    root_file.close();

    var results: std.StringArrayHashMapUnmanaged(*align(64) u64) = .{};

    var result_group: std.Io.Group = .init;

    var context: Context = .{
        .io = io,
        .group = &result_group,
        .gpa = gpa,
        .arena = arena,
        .ignored_files = &ignored_files,
        .extension_whitelist = &extension_whitelist,
        .results = &results,
        .file_results = .{},
    };

    if (root_file_stat.kind != .directory) {
        try kickoffProcessFile(
            &context,
            cwd,
            root_directory,
        );
    } else {
        const cwd_iterable = try cwd.openDir(root_directory, .{
            .iterate = true,
        });

        try walkDirectoryIter(
            &context,
            cwd_iterable,
        );
    }

    result_group.wait(io);

    const LineCountResult = struct {
        lines: u64,
        index: usize,

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.lines > rhs.lines;
        }
    };

    if (list_mode) {
        std.sort.insertion(
            Context.FileResult,
            context.file_results.items,
            {},
            Context.FileResult.lessThan,
        );

        var temp_buf: [1024]u8 = undefined;

        const largest_number_string = try std.fmt.bufPrint(&temp_buf, "{}", .{
            context.file_results.items[context.file_results.items.len - 1].count,
        });

        for (context.file_results.items) |entry| {
            const number_string = try std.fmt.bufPrint(&temp_buf, "{}", .{entry.count});

            const number_padding = largest_number_string.len - number_string.len;
            try stdout.print("  {}", .{entry.count});
            _ = try stdout.splatByte(' ', number_padding);
            try stdout.print(": {s}\n", .{
                entry.file_path,
            });
        }
    }

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

    if (list_mode)
        try stdout.print("\nTotal:\n", .{});
    var temp_buf: [1024]u8 = undefined;

    const largest_number_string = try std.fmt.bufPrint(&temp_buf, "{}", .{result_buffer[0].lines});

    for (result_buffer) |result| {
        if (result.lines == 0) continue;

        const number_string = try std.fmt.bufPrint(&temp_buf, "{}", .{result.lines});

        const number_padding = largest_number_string.len - number_string.len;
        try stdout.print("  {}", .{result.lines});
        _ = try stdout.splatByte(' ', number_padding);
        try stdout.print(": {s}\n", .{
            results.keys()[result.index],
        });
    }

    try stdout.flush();
}

const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    group: *std.Io.Group,
    ignored_files: *const std.StringArrayHashMapUnmanaged(void),
    extension_whitelist: *const std.StringArrayHashMapUnmanaged(void),
    ///Map from file extensions to line counts
    results: *std.StringArrayHashMapUnmanaged(*align(64) u64),
    file_results: std.ArrayList(FileResult),
    file_result_mutex: std.Thread.Mutex = .{},

    pub const FileResult = struct {
        file_path: []const u8,
        count: u64,

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.count < rhs.count;
        }
    };
};

fn walkDirectoryIter(
    context: *Context,
    dir: std.fs.Dir,
) !void {
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (context.ignored_files.get(entry.name)) |_| {
            continue;
        }

        //TODO: add option to include dot files
        if (std.mem.startsWith(u8, entry.name, ".")) {
            continue;
        }

        switch (entry.kind) {
            .directory => {
                const sub_dir_iter = try dir.openDir(entry.name, .{ .iterate = true });
                // defer sub_dir_iter.close();

                try walkDirectoryIter(
                    context,
                    sub_dir_iter,
                );
            },
            .file => {
                try kickoffProcessFile(context, dir, entry.name);
            },
            else => {},
        }
    }
}

fn kickoffProcessFile(
    context: *Context,
    dir: std.fs.Dir,
    file_name: []const u8,
) !void {
    const file_extension = std.fs.path.extension(file_name);

    if (file_extension.len == 0) {
        return;
    }

    if (context.extension_whitelist.count() != 0) {
        if (context.extension_whitelist.get(file_extension) == null) {
            return;
        }
    }

    const counter_query = try context.results.getOrPut(context.gpa, try context.arena.dupe(u8, file_extension));

    if (!counter_query.found_existing) {
        const counter = try context.arena.alignedAlloc(u64, .@"64", 1);

        counter[0] = 0;

        counter_query.value_ptr.* = @ptrCast(counter.ptr);
    }

    context.group.async(context.io, processFile, .{
        context,
        dir,
        try context.arena.dupe(u8, file_name),
        counter_query.value_ptr.*,
    });
}

fn processFile(
    context: *Context,
    dir: std.fs.Dir,
    file_name: []const u8,
    result_count: *align(64) u64,
) void {
    const io = context.io;
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
    var is_ascii: bool = true;

    for (0..vec_count) |vec_index| {
        const vec_ptr: *@Vector(vec_len, u8) = @ptrCast(@alignCast(file_data.ptr + vec_index * vec_len));
        const vec: @Vector(vec_len, u8) = vec_ptr.*;
        const vec_new_line: @Vector(vec_len, u8) = @splat('\n');

        const vec_cmp = vec == vec_new_line;
        const ascii_max: @Vector(vec_len, u8) = @splat(127);

        line_count += std.simd.countTrues(vec_cmp);

        is_ascii = is_ascii and std.simd.countTrues(vec < ascii_max) == vec_len;
        char_index += vec_len;
    }

    for (file_data[char_index..]) |char| {
        if (char == '\n') {
            line_count += 1;
        }
        is_ascii = is_ascii and char < 127;
    }

    if (!is_ascii) return;

    {
        var is_blank: bool = true;
        for (file_data) |char| {
            switch (char) {
                '\n' => {
                    if (is_blank) {
                        line_count -= 1;
                    }

                    is_blank = true;
                },
                ' ', '\t', '\r' => {},
                else => {
                    is_blank = false;
                },
            }
        }
    }

    _ = @atomicRmw(u64, result_count, .Add, line_count, .acq_rel);

    context.file_result_mutex.lock();
    defer context.file_result_mutex.unlock();

    context.file_results.append(context.gpa, .{
        .file_path = file_name,
        .count = line_count,
    }) catch unreachable;
}

const std = @import("std");
