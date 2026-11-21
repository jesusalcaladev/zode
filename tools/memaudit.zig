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
    var skipped: usize = 0;
    // A labeled loop is required here: in Zig 0.17 a plain `break` inside the
    // `catch` of a `while` condition is a "break expression outside loop" error.
    outer: while (true) {
        const maybe_e = walker.next(io) catch |err| {
            // A walk error used to end the loop silently: "clean (0 files scanned)"
            // looked like a pass. It is not.
            skipped += 1;
            std.debug.print("memaudit: walk error {t} after {d} files\n", .{ err, scanned });
            break :outer;
        };
        const e = maybe_e orelse break :outer;
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
        // e.path borrows the walker buffer and dies on the next call: copy it.
        const rel = gpa.dupe(u8, e.path) catch {
            skipped += 1;
            continue;
        };
        defer gpa.free(rel);
        const path = std.fmt.allocPrint(gpa, "src/{s}", .{rel}) catch {
            skipped += 1;
            continue;
        };
        defer gpa.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch {
            skipped += 1;
            std.debug.print("memaudit: SKIPPED {s} (unreadable or too large)\n", .{path});
            continue;
        };
        defer gpa.free(source);

        const findings = audit.scan(gpa, source) catch {
            skipped += 1;
            std.debug.print("memaudit: SKIPPED {s} (scanner failed)\n", .{path});
            continue;
        };
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

    if (total == 0 and skipped == 0) {
        std.debug.print("memaudit: clean ({d} source files scanned)\n", .{scanned});
        return;
    }
    if (total > 0) std.debug.print("memaudit: {d} finding(s) in {d} file(s)\n", .{ total, files });
    // A gate that skips files and still reports success is worse than no gate:
    // it says "clean" about a tree it never read. Fail loudly instead.
    if (skipped > 0) {
        std.debug.print("memaudit: {d} file(s) could not be scanned — NOT clean\n", .{skipped});
    }
    std.process.exit(1);
}
