pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var root_directory: []const u8 = ".";
    var list_mode: bool = false;
    var approx_count_printing: bool = false;

    var ignored_files: std.StringArrayHashMapUnmanaged(void) = .{};
    try ignored_files.put(gpa, ".git", {});

    var extension_whitelist: std.StringArrayHashMapUnmanaged(void) = .{};
    var line_count_threshold: u64 = 0;

    {
        var cli_args = std.process.args();

        _ = cli_args.next().?;

        while (cli_args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-e")) {
                const ext = cli_args.next().?;

                try extension_whitelist.put(gpa, ext, {});
            } else if (std.mem.eql(u8, arg, "-l")) {
                list_mode = true;
            } else if (std.mem.eql(u8, arg, "-a")) {
                approx_count_printing = true;
            } else if (std.mem.eql(u8, arg, "-threshold")) {
                const threshold_string = cli_args.next().?;
                line_count_threshold = try std.fmt.parseInt(
                    u64,
                    threshold_string,
                    0,
                );
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

    const cwd_path = try std.fs.cwd().realpathAlloc(arena, ".");

    var context: Context = .{
        .io = io,
        .group = &result_group,
        .gpa = gpa,
        .arena = arena,
        .ignored_files = &ignored_files,
        .extension_whitelist = &extension_whitelist,
        .results = &results,
        .file_results = .{},
        .file_list_mode = list_mode,
        .cwd_path = cwd_path,
        .line_count_threshold = line_count_threshold,
    };

    if (root_file_stat.kind != .directory) {
        try kickoffProcessFile(
            &context,
            cwd_path,
            root_directory,
        );
    } else {
        const cwd_iterable = try cwd.openDir(root_directory, .{
            .iterate = true,
        });

        try walkDirectoryIter(
            &context,
            cwd_iterable,
            cwd_path,
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

    var largest_number_char_length: usize = 0;

    if (list_mode) {
        std.sort.insertion(
            Context.FileResult,
            context.file_results.items,
            {},
            Context.FileResult.lessThan,
        );

        var temp_buf: [1024]u8 = undefined;

        const largest_number_string = try bufPrintCount(
            &temp_buf,
            "{}",
            context.file_results.items[context.file_results.items.len - 1].count,
            .{ .approximate = approx_count_printing },
        );
        _ = largest_number_string; // autofix

        for (context.file_results.items) |result| {
            const count_string = try bufPrintCount(
                &temp_buf,
                "{}",
                result.count,
                .{ .approximate = approx_count_printing },
            );
            largest_number_char_length = @max(largest_number_char_length, count_string.len);
        }

        for (context.file_results.items) |entry| {
            const number_string = try bufPrintCount(
                &temp_buf,
                "{}",
                entry.count,
                .{ .approximate = approx_count_printing },
            );

            const number_padding = largest_number_char_length - number_string.len;
            _ = try stdout.splatByte(' ', number_padding);
            try printCount(stdout, "  {}", entry.count, .{
                .approximate = approx_count_printing,
            });
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

    for (result_buffer) |result| {
        const count_string = try bufPrintCount(
            &temp_buf,
            "{}",
            result.lines,
            .{ .approximate = approx_count_printing },
        );
        largest_number_char_length = @max(largest_number_char_length, count_string.len);
    }

    for (result_buffer) |result| {
        if (result.lines == 0) continue;
        if (result.lines < context.line_count_threshold) continue;

        const number_string = try bufPrintCount(
            &temp_buf,
            "{}",
            result.lines,
            .{ .approximate = approx_count_printing },
        );

        const number_padding = largest_number_char_length - number_string.len;
        _ = try stdout.splatByte(' ', number_padding);
        try printCount(
            stdout,
            "  {}",
            result.lines,
            .{ .approximate = approx_count_printing },
        );
        try stdout.print(": {s}\n", .{
            results.keys()[result.index],
        });
    }

    try stdout.flush();
}

const PrintCountOptions = struct {
    approximate: bool = false,
};

fn bufPrintCount(
    buffer: []u8,
    comptime fmt: []const u8,
    count: u64,
    options: PrintCountOptions,
) ![]u8 {
    var writer: std.Io.Writer = .fixed(buffer);

    try printCount(&writer, fmt, count, options);
    return buffer[0..writer.end];
}

fn printCount(
    writer: *std.Io.Writer,
    comptime fmt: []const u8,
    count: u64,
    options: PrintCountOptions,
) !void {
    var actual_count: u64 = count;
    var marker: u8 = 0;

    if (options.approximate) {
        const thousands = actual_count / 1000;
        const millions = thousands / 1000;

        if (thousands != 0) {
            actual_count = thousands;
            marker = 'k';
        }

        if (millions != 0) {
            actual_count = millions;
            marker = 'm';
        }
    }

    try writer.print(fmt, .{actual_count});
    if (marker != 0) {
        try writer.print("{c}", .{marker});
    }
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
    file_list_mode: bool,
    cwd_path: []const u8,
    line_count_threshold: u64,

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
    dir_path: []const u8,
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
                var sub_dir_iter = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir_iter.close();

                const sub_dir_path = try std.fs.path.join(context.arena, &.{ dir_path, entry.name });

                try walkDirectoryIter(
                    context,
                    sub_dir_iter,
                    sub_dir_path,
                );
            },
            .file => {
                try kickoffProcessFile(
                    context,
                    dir_path,
                    entry.name,
                );
            },
            else => {},
        }
    }
}

fn kickoffProcessFile(
    context: *Context,
    dir_path: []const u8,
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
        dir_path,
        try context.arena.dupe(u8, file_name),
        counter_query.value_ptr.*,
    });
}

fn processFile(
    context: *Context,
    dir_path: []const u8,
    file_name: []const u8,
    result_count: *align(64) u64,
) void {
    const io = context.io;

    var path_allocator = std.heap.stackFallback(1024, context.gpa);
    const path_alloc = path_allocator.get();

    const file_path = std.fs.path.join(path_alloc, &.{ dir_path, file_name }) catch @panic("oom");
    defer path_alloc.free(file_path);

    const file = std.fs.openFileAbsolute(
        file_path,
        .{},
    ) catch unreachable;
    defer file.close();

    const stat = file.stat() catch unreachable;

    var reader = file.readerStreaming(io, &.{});

    const file_data = reader.interface.readAlloc(std.heap.page_allocator, stat.size) catch unreachable;
    defer std.heap.page_allocator.free(file_data);

    if (file_data.len == 0) return;

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

        if (!is_ascii) {
            @branchHint(.cold);
        }
    }

    for (file_data[char_index..]) |char| {
        if (char == '\n') {
            line_count += 1;
        }
        is_ascii = is_ascii and char < 127;
    }

    if (!is_ascii) {}

    {
        var is_blank: bool = true;
        var is_comment: bool = false;
        for (file_data, 0..) |char, i| {
            switch (char) {
                '\n' => {
                    if (is_blank or is_comment) {
                        line_count -= 1;
                    }

                    is_blank = true;
                    is_comment = false;
                },
                ' ', '\t', '\r' => {},
                else => {
                    if (is_blank) {
                        if (char == '/') {
                            if (i < file_data.len -| 1) {
                                if (file_data[i + 1] == '/') {
                                    is_comment = true;
                                }
                            }
                        }
                    }

                    is_blank = false;
                },
            }
        }
    }

    _ = @atomicRmw(u64, result_count, .Add, line_count, .acq_rel);

    if (context.file_list_mode) {
        if (line_count < context.line_count_threshold) {
            return;
        }
        context.file_result_mutex.lock();
        defer context.file_result_mutex.unlock();

        const relative_path = std.fs.path.relative(
            context.gpa,
            context.cwd_path,
            file_path,
        ) catch unreachable;

        context.file_results.append(context.gpa, .{
            .file_path = relative_path,
            .count = line_count,
        }) catch unreachable;
    }
}

const std = @import("std");
