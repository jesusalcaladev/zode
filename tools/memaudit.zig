//! CLI for the memory-safety source auditor. Walks every `.zig` file under
//! `src/`, scans it with `lib/memaudit.zig`, and prints each finding with a
//! file:line reference. Exits 1 when anything is found, so it can gate CI.
//!
//!   zig build memaudit
//!
//! Review each finding. If it is intentional, annotate the line with
//! `// memaudit: allow` and a short reason, then rerun.

const std = @import("std");
const audit = @import("memaudit");

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    var dir = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch {
        std.debug.print("memaudit: cannot open src/\n", .{});
        std.process.exit(2);
    };
    defer dir.close(io);
    var walker = dir.walk(gpa) catch {
        std.debug.print("memaudit: cannot walk src/\n", .{});
        std.process.exit(2);
    };
    defer walker.deinit();

    var total: usize = 0;
    var files: usize = 0;
    var scanned: usize = 0;
    while (walker.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
        // e.path borrows the walker buffer and dies on the next call: copy it.
        const rel = gpa.dupe(u8, e.path) catch continue;
        defer gpa.free(rel);
        const path = std.fmt.allocPrint(gpa, "src/{s}", .{rel}) catch continue;
        defer gpa.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch continue;
        defer gpa.free(source);

        const findings = audit.scan(gpa, source) catch continue;
        defer gpa.free(findings);
        scanned += 1;
        if (findings.len == 0) continue;
        files += 1;
        for (findings) |f| {
            total += 1;
            std.debug.print("{s}:{d}: {s}\n    {s}\n    -> {s}\n", .{
                path, f.line, f.kind.label(), std.mem.trim(u8, f.snippet, " \t"), f.kind.advice(),
            });
        }
    }

    if (total == 0) {
        std.debug.print("memaudit: clean ({d} source files scanned)\n", .{scanned});
        return;
    }
    std.debug.print("memaudit: {d} finding(s) in {d} file(s)\n", .{ total, files });
    std.process.exit(1);
}
