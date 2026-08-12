const std = @import("std");

const utf8_bom = "\xEF\xBB\xBF";

pub const IssueKind = enum {
    torn_write,
    invalid_utf8,
    malformed_json,
    invalid_schema,
    duplicate_sequence,
    non_monotonic_sequence,
};

pub const Issue = struct {
    kind: IssueKind,
    byte_offset: usize,
    row: usize,
    sequence: ?u64 = null,
};

/// Iterate only the valid LF-framed prefix of one JSONL byte slice. Callers
/// validate their typed schema, then accept the row (with or without sequence
/// ordering). Once one row fails, every projection observes the same boundary.
pub const PrefixReader = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    cursor: usize,
    valid_end: usize,
    rows_seen: usize = 0,
    pending_start: usize = 0,
    pending_end: usize = 0,
    pending_row: usize = 0,
    pending: bool = false,
    last_sequence: ?u64 = null,
    issue: ?Issue = null,
    had_bom: bool,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) PrefixReader {
        const had_bom = std.mem.startsWith(u8, content, utf8_bom);
        const start = if (had_bom) utf8_bom.len else 0;
        return .{
            .allocator = allocator,
            .content = content,
            .cursor = start,
            .valid_end = start,
            .had_bom = had_bom,
        };
    }

    pub fn next(self: *PrefixReader) !?[]const u8 {
        std.debug.assert(!self.pending);
        if (self.issue != null) return null;

        while (self.cursor < self.content.len) {
            const start = self.cursor;
            const newline = std.mem.indexOfScalar(u8, self.content[start..], '\n');
            const end = if (newline) |offset| start + offset else self.content.len;
            const terminated = newline != null;
            self.cursor = if (terminated) end + 1 else end;

            var line = self.content[start..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (std.mem.trim(u8, line, " \t\r").len == 0) {
                self.valid_end = self.cursor;
                continue;
            }

            self.rows_seen += 1;
            if (!std.unicode.utf8ValidateSlice(line)) {
                self.issue = .{ .kind = .invalid_utf8, .byte_offset = start, .row = self.rows_seen };
                return null;
            }
            if (!try std.json.validate(self.allocator, line)) {
                self.issue = .{
                    .kind = if (terminated) .malformed_json else .torn_write,
                    .byte_offset = start,
                    .row = self.rows_seen,
                };
                return null;
            }

            self.pending_start = start;
            self.pending_end = self.cursor;
            self.pending_row = self.rows_seen;
            self.pending = true;
            return line;
        }

        return null;
    }

    pub fn accept(self: *PrefixReader) void {
        std.debug.assert(self.pending);
        self.valid_end = self.pending_end;
        self.pending = false;
    }

    pub fn acceptSequence(self: *PrefixReader, sequence: u64) bool {
        std.debug.assert(self.pending);
        if (self.last_sequence) |last| {
            if (sequence <= last) {
                self.issue = .{
                    .kind = if (sequence == last) .duplicate_sequence else .non_monotonic_sequence,
                    .byte_offset = self.pending_start,
                    .row = self.pending_row,
                    .sequence = sequence,
                };
                self.pending = false;
                return false;
            }
        }
        self.last_sequence = sequence;
        self.accept();
        return true;
    }

    pub fn reject(self: *PrefixReader, kind: IssueKind) void {
        std.debug.assert(self.pending);
        self.issue = .{
            .kind = kind,
            .byte_offset = self.pending_start,
            .row = self.pending_row,
        };
        self.pending = false;
    }
};

pub fn stripBom(content: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, content, utf8_bom)) content[utf8_bom.len..] else content;
}

test "prefix reader keeps one LF boundary across BOM poison and duplicates" {
    const content = utf8_bom ++
        "{\"seq\":1}\n" ++
        "{\"seq\":1}\n" ++
        "{\"seq\":2}\n";
    var reader = PrefixReader.init(std.testing.allocator, content);
    const first = (try reader.next()).?;
    try std.testing.expectEqualStrings("{\"seq\":1}", first);
    try std.testing.expect(reader.acceptSequence(1));
    _ = (try reader.next()).?;
    try std.testing.expect(!reader.acceptSequence(1));
    try std.testing.expectEqual(IssueKind.duplicate_sequence, reader.issue.?.kind);
    try std.testing.expect((try reader.next()) == null);
    try std.testing.expect(reader.had_bom);
}

test "prefix reader accepts complete final JSON and rejects a torn final row" {
    var complete = PrefixReader.init(std.testing.allocator, "{\"seq\":1}");
    _ = (try complete.next()).?;
    complete.accept();
    try std.testing.expect((try complete.next()) == null);
    try std.testing.expect(complete.issue == null);

    var torn = PrefixReader.init(std.testing.allocator, "{\"seq\":");
    try std.testing.expect((try torn.next()) == null);
    try std.testing.expectEqual(IssueKind.torn_write, torn.issue.?.kind);
}
