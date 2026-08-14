const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const input_protocol = VAR1.shared.protocol.input;

const TextInput = tui.widgets.TextInput;

const option_keys = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
const invalid_display_text = "(invalid text)";

pub const Action = enum {
    consumed,
    submit,
    cancel,
};

pub const DrawStyles = struct {
    panel: tui.Cell.Style,
    title: tui.Cell.Style,
    prompt: tui.Cell.Style,
    option: tui.Cell.Style,
    selected: tui.Cell.Style,
    hint: tui.Cell.Style,
    input: tui.Cell.Style,
    confirm: tui.Cell.Style,
};

const Option = struct {
    id: []u8,
    label: []u8,
    description: ?[]u8 = null,
    selected: bool = false,

    fn deinit(self: Option, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        if (self.description) |value| allocator.free(value);
    }
};

const Question = struct {
    id: []u8,
    prompt: []u8,
    multiple: bool,
    options: std.ArrayList(Option) = .{},
    other_text: ?[]u8 = null,

    fn deinit(self: *Question, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.prompt);
        for (self.options.items) |option| option.deinit(allocator);
        self.options.deinit(allocator);
        if (self.other_text) |value| allocator.free(value);
    }

    fn hasSelection(self: *const Question) bool {
        for (self.options.items) |option| if (option.selected) return true;
        return false;
    }

    fn hasIncompleteOther(self: *const Question) bool {
        for (self.options.items) |option| {
            if (std.mem.eql(u8, option.id, "f") and option.selected) {
                return self.other_text == null or self.other_text.?.len == 0;
            }
        }
        return false;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    request_id: []u8,
    questions: std.ArrayList(Question) = .{},
    question_index: usize = 0,
    option_cursor: usize = 0,
    confirming: bool = false,
    editing_other: bool = false,
    confirm_error: bool = false,

    pub fn initFromJson(allocator: std.mem.Allocator, request_json: []const u8) !State {
        // The kernel emits this bounded envelope, and replayed event data is
        // still untrusted at the client boundary. Reject an oversized payload
        // before the JSON parser can turn it into an unbounded UI allocation.
        if (request_json.len == 0 or request_json.len > input_protocol.max_serialized_bytes) {
            return error.InvalidInputRequest;
        }
        var parsed = try std.json.parseFromSlice(input_protocol.Request, allocator, request_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, input_protocol.request_schema) or
            !std.mem.eql(u8, parsed.value.kind, "question") or
            parsed.value.request_id.len == 0 or parsed.value.questions.len == 0 or
            parsed.value.questions.len > input_protocol.max_questions) return error.InvalidInputRequest;

        var state = State{
            .allocator = allocator,
            .request_id = try allocator.dupe(u8, parsed.value.request_id),
        };
        errdefer state.deinit();
        for (parsed.value.questions) |question| {
            if (question.id.len == 0 or question.prompt.len == 0 or question.prompt.len > input_protocol.max_prompt_bytes or
                question.options.len < 2 or question.options.len > input_protocol.max_options) return error.InvalidInputRequest;
            var owned_question = Question{
                .id = try allocator.dupe(u8, question.id),
                .prompt = try allocator.dupe(u8, question.prompt),
                .multiple = question.multiple,
            };
            errdefer owned_question.deinit(allocator);
            for (question.options) |option| {
                if (option.id.len == 0 or option.label.len == 0 or option.label.len > input_protocol.max_label_bytes) return error.InvalidInputRequest;
                const owned_description = if (option.description) |description| blk: {
                    if (description.len > input_protocol.max_description_bytes) return error.InvalidInputRequest;
                    break :blk try allocator.dupe(u8, description);
                } else null;
                try owned_question.options.append(allocator, .{
                    .id = try allocator.dupe(u8, option.id),
                    .label = try allocator.dupe(u8, option.label),
                    .description = owned_description,
                });
            }
            try state.questions.append(allocator, owned_question);
        }
        return state;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.request_id);
        for (self.questions.items) |*question| question.deinit(self.allocator);
        self.questions.deinit(self.allocator);
    }

    pub fn panelHeight(self: *const State, root_height: u16) u16 {
        if (root_height == 0 or self.questions.items.len == 0) return 0;
        const needed: u16 = @intCast(@min(
            self.questions.items.len + 4 + @as(usize, if (self.editing_other and !self.confirming) 1 else 0),
            @as(usize, std.math.maxInt(u16)),
        ));
        return @min(root_height, @max(@as(u16, 6), needed));
    }

    pub fn handleKey(self: *State, key: tui.Key, input: *TextInput) !Action {
        self.clampCursors();
        if (key.matches('c', .{ .ctrl = true })) return .cancel;
        if (self.questions.items.len == 0) return .cancel;

        if (self.editing_other) {
            if (key.matches(tui.Key.escape, .{})) {
                self.editing_other = false;
                input.clearAndFree();
                return .consumed;
            }
            if (key.matches(tui.Key.enter, .{})) {
                const value = try input.toOwnedSlice();
                defer self.allocator.free(value);
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len == 0) return .consumed;
                const question = &self.questions.items[self.question_index];
                if (question.other_text) |previous| self.allocator.free(previous);
                question.other_text = try self.allocator.dupe(u8, trimmed);
                self.editing_other = false;
                input.clearAndFree();
                if (!question.multiple) self.advanceOrConfirm();
                return .consumed;
            }
            try input.update(.{ .key_press = key });
            return .consumed;
        }

        if (self.confirming) {
            if (key.matches(tui.Key.escape, .{})) {
                self.confirming = false;
                self.confirm_error = false;
                self.question_index = self.questions.items.len -| 1;
                self.option_cursor = 0;
                return .consumed;
            }
            if (key.matches(tui.Key.enter, .{})) {
                for (self.questions.items) |*question| {
                    if (!question.hasSelection() or question.hasIncompleteOther()) {
                        self.confirm_error = true;
                        return .consumed;
                    }
                }
                return .submit;
            }
            return .consumed;
        }

        const question = &self.questions.items[self.question_index];
        if (key.matches(tui.Key.escape, .{})) return .cancel;
        if (key.matches(tui.Key.tab, .{ .shift = true }) or key.matches(tui.Key.up, .{})) {
            self.moveQuestion(-1);
            return .consumed;
        }
        if (key.matches(tui.Key.tab, .{})) {
            if (self.question_index + 1 < self.questions.items.len) {
                self.moveQuestion(1);
            } else {
                self.confirming = true;
                self.confirm_error = false;
            }
            return .consumed;
        }
        if (key.matches(tui.Key.left, .{})) {
            if (self.option_cursor > 0) self.option_cursor -= 1;
            return .consumed;
        }
        if (key.matches(tui.Key.down, .{})) {
            self.moveQuestion(1);
            return .consumed;
        }
        if (key.matches(tui.Key.right, .{})) {
            if (self.option_cursor + 1 < question.options.items.len) self.option_cursor += 1;
            return .consumed;
        }
        if (key.matches(' ', .{})) {
            self.toggleOption(question);
            return .consumed;
        }
        if (key.matches(tui.Key.enter, .{})) {
            const current = &question.options.items[self.option_cursor];
            if (question.multiple) {
                // Multi-select questions stay on their row until the review
                // state. Enter and Space are both toggles, matching the
                // settings-style reference controller. Selecting Other with
                // Enter opens the inline editor instead of advancing.
                if (std.mem.eql(u8, current.id, "f") and (!current.selected or question.other_text == null)) {
                    current.selected = true;
                    self.editing_other = true;
                    input.clearAndFree();
                    return .consumed;
                }
                self.toggleOption(question);
                return .consumed;
            }
            if (!question.multiple) {
                for (question.options.items) |*option| option.selected = false;
            }
            current.selected = true;
            if (!std.mem.eql(u8, current.id, "f")) self.clearOther(question);
            if (std.mem.eql(u8, current.id, "f") and question.other_text == null) {
                self.editing_other = true;
                input.clearAndFree();
                return .consumed;
            }
            self.advanceOrConfirm();
            return .consumed;
        }
        return .consumed;
    }

    fn toggleOption(self: *State, question: *Question) void {
        const option = &question.options.items[self.option_cursor];
        option.selected = !option.selected;
        if (!option.selected and std.mem.eql(u8, option.id, "f")) self.clearOther(question);
    }

    fn clearOther(self: *State, question: *Question) void {
        if (question.other_text) |value| self.allocator.free(value);
        question.other_text = null;
    }

    fn advanceOrConfirm(self: *State) void {
        if (self.question_index + 1 < self.questions.items.len) {
            self.question_index += 1;
            self.option_cursor = 0;
        } else {
            self.confirming = true;
        }
    }

    fn moveQuestion(self: *State, direction: i8) void {
        if (self.questions.items.len == 0) return;
        if (direction < 0) {
            if (self.question_index > 0) self.question_index -= 1;
        } else if (self.question_index + 1 < self.questions.items.len) {
            self.question_index += 1;
        }
        self.option_cursor = 0;
        self.confirm_error = false;
    }

    fn clampCursors(self: *State) void {
        if (self.questions.items.len == 0) {
            self.question_index = 0;
            self.option_cursor = 0;
            return;
        }
        if (self.question_index >= self.questions.items.len) self.question_index = self.questions.items.len - 1;
        const options_len = self.questions.items[self.question_index].options.items.len;
        if (options_len == 0) {
            self.option_cursor = 0;
        } else if (self.option_cursor >= options_len) {
            self.option_cursor = options_len - 1;
        }
    }

    pub fn responseJson(self: *const State, allocator: std.mem.Allocator, cancelled: bool) ![]u8 {
        if (cancelled) return input_protocol.serializeResponse(allocator, self.request_id, true, &.{});

        var answers = try allocator.alloc(input_protocol.Answer, self.questions.items.len);
        defer allocator.free(answers);
        var selections = try allocator.alloc([]const []const u8, self.questions.items.len);
        var selections_initialized: usize = 0;
        defer {
            for (selections[0..selections_initialized]) |selection| allocator.free(selection);
            allocator.free(selections);
        }

        for (self.questions.items, 0..) |question, index| {
            var count: usize = 0;
            for (question.options.items) |option| {
                if (option.selected) count += 1;
            }
            const selection = try allocator.alloc([]const u8, count);
            selections[index] = selection;
            selections_initialized += 1;
            var cursor: usize = 0;
            for (question.options.items) |option| {
                if (!option.selected) continue;
                selection[cursor] = option.id;
                cursor += 1;
            }
            answers[index] = .{
                .question_id = question.id,
                .selected = selection,
                .other = question.other_text,
            };
        }
        return input_protocol.serializeResponse(allocator, self.request_id, false, answers);
    }

    pub fn draw(
        self: *const State,
        win: tui.Window,
        input: *TextInput,
        styles: DrawStyles,
        frame_allocator: std.mem.Allocator,
    ) void {
        win.fill(.{ .style = styles.panel });
        if (win.width == 0 or win.height == 0 or self.questions.items.len == 0) return;
        if (self.confirming) {
            if (win.height > 0) {
                _ = win.print(&.{.{ .text = " Confirm answers", .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
            }
            if (win.height > 1) {
                _ = win.print(&.{.{ .text = "Enter submit · Esc back", .style = styles.hint }}, .{ .row_offset = 1, .wrap = .none });
            }
            if (win.height > 2) {
                _ = win.print(&.{.{ .text = "────────────────────────────────────────────────────────────────", .style = styles.hint }}, .{ .row_offset = 2, .wrap = .none });
            }
            var row: usize = 3;
            for (self.questions.items) |question| {
                if (row >= win.height) break;
                drawAnswerSummary(win, question, row, styles.confirm, frame_allocator);
                row += 1;
            }
            if (self.confirm_error and row < win.height) {
                _ = win.print(&.{.{ .text = "Choose an answer and complete every selected Other option.", .style = styles.hint }}, .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });
            }
            return;
        }

        const active_index = @min(self.question_index, self.questions.items.len - 1);
        // Vaxis retains printed text until the outer frame reaches
        // `vx.render`.  Header text therefore belongs to the frame arena, not
        // a helper stack frame that ends before the render boundary.
        const header = std.fmt.allocPrint(
            frame_allocator,
            " Questions {d}/{d} · ↑/↓ question · ←/→ option · Tab next",
            .{ active_index + 1, self.questions.items.len },
        ) catch " Questions";
        if (win.height > 0) {
            _ = win.print(&.{.{ .text = header, .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
        }
        if (win.height > 1) {
            _ = win.print(&.{.{ .text = "────────────────────────────────────────────────────────────────", .style = styles.hint }}, .{ .row_offset = 1, .wrap = .none });
        }

        const row_start: usize = 2;
        const reserved_rows: usize = 1 + @as(usize, if (self.editing_other) 1 else 0);
        const visible_capacity = @as(usize, win.height) -| row_start -| reserved_rows;
        if (visible_capacity == 0) return;
        const visible_questions = @min(self.questions.items.len, visible_capacity);
        const first_question = if (active_index >= visible_questions)
            @min(active_index - visible_questions + 1, self.questions.items.len - visible_questions)
        else
            0;
        var row = row_start;
        for (self.questions.items[first_question .. first_question + visible_questions], first_question..) |question, question_index| {
            self.drawQuestionRow(win, question, question_index == active_index, row, styles, frame_allocator);
            row += 1;
        }

        if (self.editing_other and row < @as(usize, win.height) -| 1) {
            _ = win.print(&.{.{ .text = " Other: ", .style = styles.option }}, .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });
            if (win.width > 10) {
                input.drawWithStyle(win.child(.{ .x_off = 9, .y_off = @intCast(row), .width = win.width -| 10, .height = 1 }), styles.input);
            }
        }
        const confirm_row: usize = @as(usize, win.height) -| 1;
        _ = win.print(&.{.{ .text = " Review and submit · Tab from the last question", .style = styles.hint }}, .{ .row_offset = @intCast(confirm_row), .col_offset = 1, .wrap = .none });
    }

    fn drawQuestionRow(
        self: *const State,
        win: tui.Window,
        question: Question,
        active: bool,
        row: usize,
        styles: DrawStyles,
        frame_allocator: std.mem.Allocator,
    ) void {
        if (row >= win.height or win.width == 0) return;
        const prompt_width = @min(@as(usize, 28), @max(@as(usize, 10), @as(usize, win.width) / 3));
        const prompt_limit = prompt_width -| 2;
        const prompt = truncateToWidth(win, safeDisplayText(frame_allocator, question.prompt), prompt_limit);
        const prompt_style = if (active) styles.selected else styles.prompt;
        _ = win.print(
            &.{
                .{ .text = if (active) "› " else "  ", .style = prompt_style },
                .{ .text = prompt, .style = prompt_style },
            },
            .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none },
        );

        var col: usize = prompt_width + 3;
        for (question.options.items, 0..) |option, option_index| {
            if (col >= win.width) break;
            const available = @as(usize, win.width) - col;
            const marker = if (option.selected) "✓ " else if (active and option_index == self.option_cursor) "› " else "  ";
            const option_style = if (active and option_index == self.option_cursor)
                styles.selected
            else if (option.selected)
                styles.confirm
            else
                styles.option;
            const key = optionKey(option_index);
            const prefix_width: usize = @intCast(
                win.gwidth(marker) + win.gwidth(key) + win.gwidth(") "),
            );
            const label_width = available -| prefix_width;
            const visible_label = truncateToWidth(win, safeDisplayText(frame_allocator, option.label), label_width);
            if (visible_label.len == 0) break;
            _ = win.print(
                &.{
                    .{ .text = marker, .style = option_style },
                    .{ .text = key, .style = option_style },
                    .{ .text = ") ", .style = option_style },
                    .{ .text = visible_label, .style = option_style },
                },
                .{ .row_offset = @intCast(row), .col_offset = @intCast(col), .wrap = .none },
            );
            const option_width: usize = @intCast(
                win.gwidth(marker) + win.gwidth(key) + win.gwidth(") ") + win.gwidth(visible_label),
            );
            col += @min(available, option_width + @as(usize, win.gwidth("  ")));
        }
    }
};

fn appendSegment(
    segments: []tui.Cell.Segment,
    count: *usize,
    text: []const u8,
    style: tui.Cell.Style,
) void {
    if (text.len == 0 or count.* >= segments.len) return;
    segments[count.*] = .{ .text = text, .style = style };
    count.* += 1;
}

fn drawAnswerSummary(
    win: tui.Window,
    question: Question,
    row: usize,
    style: tui.Cell.Style,
    frame_allocator: std.mem.Allocator,
) void {
    if (row >= win.height) return;

    // Every segment points to static text or storage owned by State. Do not
    // allocate a summary and free it before `vx.render`; the window keeps the
    // segment text borrowed through that boundary.
    var segments: [32]tui.Cell.Segment = undefined;
    var count: usize = 0;
    appendSegment(segments[0..], &count, safeDisplayText(frame_allocator, question.prompt), style);
    appendSegment(segments[0..], &count, ": ", style);

    var selected_count: usize = 0;
    for (question.options.items) |option| {
        if (!option.selected) continue;
        if (selected_count > 0) appendSegment(segments[0..], &count, ", ", style);
        appendSegment(segments[0..], &count, safeDisplayText(frame_allocator, option.label), style);
        if (std.mem.eql(u8, option.id, "f")) {
            if (question.other_text) |value| {
                appendSegment(segments[0..], &count, " = ", style);
                appendSegment(segments[0..], &count, safeDisplayText(frame_allocator, value), style);
            }
        }
        selected_count += 1;
    }
    if (selected_count == 0) appendSegment(segments[0..], &count, "(none)", style);

    _ = win.print(segments[0..count], .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });
}

fn optionKey(index: usize) []const u8 {
    return if (index < option_keys.len) option_keys[index] else "?";
}

/// Keep model- and operator-provided text single-line and UTF-8-safe before it
/// reaches Vaxis. The question state keeps the original id/label for the
/// response contract; only the borrowed display projection is normalized.
fn safeDisplayText(allocator: std.mem.Allocator, value: []const u8) []const u8 {
    if (value.len == 0) return value;
    if (!std.unicode.utf8ValidateSlice(value)) return invalid_display_text;

    var needs_copy = false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return value;

    var normalized = std.array_list.Managed(u8).init(allocator);
    defer normalized.deinit();
    var pending_space = false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            pending_space = true;
            continue;
        }
        if (pending_space and normalized.items.len > 0 and normalized.items[normalized.items.len - 1] != ' ') {
            normalized.append(' ') catch return invalid_display_text;
        }
        normalized.append(byte) catch return invalid_display_text;
        pending_space = false;
    }
    while (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
        _ = normalized.pop();
    }
    if (normalized.items.len == 0) return invalid_display_text;
    return normalized.toOwnedSlice() catch invalid_display_text;
}

fn truncateToWidth(win: tui.Window, value: []const u8, width: usize) []const u8 {
    if (width == 0 or value.len == 0) return value[0..0];
    var byte_index: usize = 0;
    var cells: usize = 0;
    var iterator = win.unicode.graphemeIterator(value);
    while (iterator.next()) |grapheme| {
        const bytes = grapheme.bytes(value);
        const grapheme_width: usize = @intCast(win.gwidth(bytes));
        if (grapheme_width > 0 and cells + grapheme_width > width) break;
        byte_index += bytes.len;
        cells += grapheme_width;
    }
    return value[0..byte_index];
}

fn sliceBorrowedFromQuestionOwner(slice: []const u8, owner: []const u8) bool {
    if (slice.len == 0) return true;
    if (owner.len == 0) return false;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    const owner_start = @intFromPtr(owner.ptr);
    const owner_end = owner_start + owner.len;
    return slice_start >= owner_start and slice_end <= owner_end;
}

fn sliceBorrowedFromQuestionState(slice: []const u8, questions: []const Question) bool {
    for (questions) |question| {
        if (sliceBorrowedFromQuestionOwner(slice, question.id) or
            sliceBorrowedFromQuestionOwner(slice, question.prompt)) return true;
        if (question.other_text) |value| {
            if (sliceBorrowedFromQuestionOwner(slice, value)) return true;
        }
        for (question.options.items) |option| {
            if (sliceBorrowedFromQuestionOwner(slice, option.id) or
                sliceBorrowedFromQuestionOwner(slice, option.label)) return true;
        }
    }
    return false;
}

fn sliceBorrowedFromQuestionStatic(slice: []const u8) bool {
    const sources = [_][]const u8{
        " Confirm answers",
        "Enter submit · Esc back",
        "────────────────────────────────────────────────────────────────",
        " Questions",
        "› ",
        "✓ ",
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
        "?",
        ") ",
        " Other: ",
        " Review and submit · Tab from the last question",
        "Choose an answer and complete every selected Other option.",
        "(none)",
        ": ",
        ", ",
        " = ",
    };
    for (sources) |source| {
        if (sliceBorrowedFromQuestionOwner(slice, source)) return true;
    }
    return false;
}

fn expectQuestionScreenTextOwnership(
    screen: tui.Screen,
    state: *const State,
    frame_storage: []const u8,
) !void {
    for (screen.buf) |cell| {
        const text = cell.char.grapheme;
        if (text.len == 0 or std.mem.eql(u8, text, " ")) continue;
        try std.testing.expect(
            sliceBorrowedFromQuestionState(text, state.questions.items) or
                sliceBorrowedFromQuestionOwner(text, frame_storage) or
                sliceBorrowedFromQuestionStatic(text),
        );
    }
}

test "question controller selects, confirms, and serializes answers" {
    var state = try State.initFromJson(
        std.testing.allocator,
        "{\"request_id\":\"call-1\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Pick\",\"options\":[{\"id\":\"a\",\"label\":\"One\"},{\"id\":\"f\",\"label\":\"Other\"}]}]}",
    );
    defer state.deinit();
    var input = TextInput.init(std.testing.allocator, undefined);
    defer input.deinit();
    const enter_key: tui.Key = .{ .codepoint = tui.Key.enter };
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.confirming);
    try std.testing.expectEqual(Action.submit, try state.handleKey(enter_key, &input));
    const response = try state.responseJson(std.testing.allocator, false);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"a\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"selected\":[\"a\"]") != null);
}

test "question controller rejects empty answers and captures Other text" {
    var state = try State.initFromJson(
        std.testing.allocator,
        "{\"request_id\":\"call-2\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Pick\",\"options\":[{\"id\":\"a\",\"label\":\"One\"},{\"id\":\"f\",\"label\":\"Other\"}]}]}",
    );
    defer state.deinit();
    var unicode = try tui.Unicode.init(std.testing.allocator);
    defer unicode.deinit(std.testing.allocator);
    var input = TextInput.init(std.testing.allocator, &unicode);
    defer input.deinit();
    const enter_key: tui.Key = .{ .codepoint = tui.Key.enter };
    const text_key: tui.Key = .{ .codepoint = 'x', .text = "custom" };

    state.confirming = true;
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.confirming);
    try std.testing.expect(state.confirm_error);

    state.confirming = false;
    state.option_cursor = 1;
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.editing_other);
    try input.update(.{ .key_press = text_key });
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.confirming);
    try std.testing.expectEqual(Action.submit, try state.handleKey(enter_key, &input));
    const response = try state.responseJson(std.testing.allocator, false);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"selected\":[\"f\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"other\":\"custom\"") != null);
}

test "question controller keeps all question rows navigable before review" {
    var state = try State.initFromJson(
        std.testing.allocator,
        "{\"request_id\":\"call-3\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"First\",\"options\":[{\"id\":\"a\",\"label\":\"One\"},{\"id\":\"b\",\"label\":\"Two\"}]},{\"id\":\"q2\",\"prompt\":\"Second\",\"options\":[{\"id\":\"a\",\"label\":\"Alpha\"},{\"id\":\"b\",\"label\":\"Beta\"}]}]}",
    );
    defer state.deinit();
    var input = TextInput.init(std.testing.allocator, undefined);
    defer input.deinit();
    const enter_key: tui.Key = .{ .codepoint = tui.Key.enter };
    const down_key: tui.Key = .{ .codepoint = tui.Key.down };
    const shift_tab: tui.Key = .{ .codepoint = tui.Key.tab, .mods = .{ .shift = true } };
    try std.testing.expectEqual(Action.consumed, try state.handleKey(down_key, &input));
    try std.testing.expectEqual(@as(usize, 1), state.question_index);
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.confirming);
    try std.testing.expectEqual(Action.consumed, try state.handleKey(.{ .codepoint = tui.Key.escape }, &input));
    try std.testing.expect(!state.confirming);
    try std.testing.expectEqual(@as(usize, 1), state.question_index);
    try std.testing.expectEqual(Action.consumed, try state.handleKey(shift_tab, &input));
    try std.testing.expectEqual(@as(usize, 0), state.question_index);
}

test "question controller keeps multi-select on the row until review and clears Other" {
    var unicode = try tui.Unicode.init(std.testing.allocator);
    defer unicode.deinit(std.testing.allocator);
    var input = TextInput.init(std.testing.allocator, &unicode);
    defer input.deinit();
    var state = try State.initFromJson(
        std.testing.allocator,
        "{\"request_id\":\"call-multi\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Pick any\",\"multiple\":true,\"options\":[{\"id\":\"a\",\"label\":\"One\"},{\"id\":\"f\",\"label\":\"Other\"}]}]}",
    );
    defer state.deinit();
    const enter_key: tui.Key = .{ .codepoint = tui.Key.enter };
    const right_key: tui.Key = .{ .codepoint = tui.Key.right };
    const tab_key: tui.Key = .{ .codepoint = tui.Key.tab };
    const text_key: tui.Key = .{ .codepoint = 'x', .text = "custom" };

    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(!state.confirming);
    try std.testing.expect(state.questions.items[0].options.items[0].selected);

    try std.testing.expectEqual(Action.consumed, try state.handleKey(right_key, &input));
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(state.editing_other);
    try input.update(.{ .key_press = text_key });
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    try std.testing.expect(!state.confirming);
    try std.testing.expectEqual(@as(usize, 0), state.question_index);
    try std.testing.expectEqual(Action.consumed, try state.handleKey(tab_key, &input));
    try std.testing.expect(state.confirming);

    try std.testing.expectEqual(Action.consumed, try state.handleKey(.{ .codepoint = tui.Key.escape }, &input));
    state.option_cursor = 1;
    try std.testing.expectEqual(Action.consumed, try state.handleKey(enter_key, &input));
    const response = try state.responseJson(std.testing.allocator, false);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"selected\":[\"a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"other\":\"custom\"") == null);
}

test "question controller guards empty panel dimensions and rejects malformed input" {
    try std.testing.expectError(error.InvalidInputRequest, State.initFromJson(
        std.testing.allocator,
        "{\"request_id\":\"call-bad\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Broken\",\"options\":[{\"id\":\"a\",\"label\":\"Only\"}]}]}",
    ));
    var state = State{
        .allocator = std.testing.allocator,
        .request_id = try std.testing.allocator.dupe(u8, "empty"),
    };
    defer state.deinit();
    try std.testing.expectEqual(@as(u16, 0), state.panelHeight(0));
    try std.testing.expectEqual(@as(u16, 0), state.panelHeight(10));
}

test "question panel render cells keep state or frame-owned text through the frame" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var screen = try tui.Screen.init(allocator, .{ .rows = 8, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var state = try State.initFromJson(
        allocator,
        "{\"request_id\":\"call-render\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Direction\",\"options\":[{\"id\":\"a\",\"label\":\"Fast\"},{\"id\":\"b\",\"label\":\"Careful\"}]},{\"id\":\"q2\",\"prompt\":\"Scope\",\"options\":[{\"id\":\"a\",\"label\":\"Local\"},{\"id\":\"b\",\"label\":\"Full\"}]}]}",
    );
    defer state.deinit();
    var input = TextInput.init(allocator, &unicode);
    defer input.deinit();
    var frame_storage: [2048]u8 = undefined;
    var frame_allocator = std.heap.FixedBufferAllocator.init(&frame_storage);
    const win = tui.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
        .unicode = &unicode,
    };
    const styles = DrawStyles{
        .panel = .{},
        .title = .{},
        .prompt = .{},
        .option = .{},
        .selected = .{},
        .hint = .{},
        .input = .{},
        .confirm = .{},
    };

    state.draw(win, &input, styles, frame_allocator.allocator());
    try expectQuestionScreenTextOwnership(screen, &state, frame_storage[0..]);

    state.questions.items[0].options.items[0].selected = true;
    state.confirming = true;
    state.draw(win, &input, styles, frame_allocator.allocator());
    try expectQuestionScreenTextOwnership(screen, &state, frame_storage[0..]);
}

test "question panel sanitizes untrusted text and survives clipped viewports" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var state = try State.initFromJson(
        allocator,
        "{\"request_id\":\"call-safe\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Choose\\n a\\tpath\",\"options\":[{\"id\":\"server-choice\",\"label\":\"Fast\\r\\npath\"},{\"id\":\"safe-choice\",\"label\":\"Careful\"}]}]}",
    );
    defer state.deinit();
    var input = TextInput.init(allocator, &unicode);
    defer input.deinit();
    const styles = DrawStyles{
        .panel = .{},
        .title = .{},
        .prompt = .{},
        .option = .{},
        .selected = .{},
        .hint = .{},
        .input = .{},
        .confirm = .{},
    };

    for ([_]u16{ 1, 2, 3 }) |rows| {
        var screen = try tui.Screen.init(allocator, .{ .rows = rows, .cols = 64, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(allocator);
        const win = tui.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = screen.width,
            .height = screen.height,
            .screen = &screen,
            .unicode = &unicode,
        };
        var frame_storage: [4096]u8 = undefined;
        var frame_allocator = std.heap.FixedBufferAllocator.init(&frame_storage);
        state.draw(win, &input, styles, frame_allocator.allocator());
        for (screen.buf) |cell| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(cell.char.grapheme));
            try std.testing.expect(std.mem.indexOfAny(u8, cell.char.grapheme, "\r\n\t") == null);
        }

        state.confirming = true;
        var confirm_storage: [4096]u8 = undefined;
        var confirm_allocator = std.heap.FixedBufferAllocator.init(&confirm_storage);
        state.draw(win, &input, styles, confirm_allocator.allocator());
    }

    state.questions.items[0].options.items[0].selected = true;
    const response = try state.responseJson(allocator, false);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "server-choice") != null);
}

test "question panel bounds and renders the maximum batch at the viewport edges" {
    const allocator = std.testing.allocator;
    var request = std.array_list.Managed(u8).init(allocator);
    defer request.deinit();
    try request.appendSlice(
        "{\"schema\":\"var1.input_requested.v1\",\"kind\":\"question\",\"request_id\":\"call-max\",\"questions\":[",
    );
    for (0..input_protocol.max_questions) |index| {
        if (index > 0) try request.append(',');
        const question = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"q{d}\",\"prompt\":\"Preference {d}\",\"options\":[{{\"id\":\"a\",\"label\":\"Fast {d}\"}},{{\"id\":\"b\",\"label\":\"Careful {d}\"}},{{\"id\":\"c\",\"label\":\"Thorough {d}\"}},{{\"id\":\"d\",\"label\":\"Minimal {d}\"}},{{\"id\":\"e\",\"label\":\"Other path {d}\"}}]}}",
            .{ index + 1, index + 1, index, index, index, index, index },
        );
        defer allocator.free(question);
        try request.appendSlice(question);
    }
    try request.appendSlice("]}");

    var state = try State.initFromJson(allocator, request.items);
    defer state.deinit();
    try std.testing.expectEqual(input_protocol.max_questions, state.questions.items.len);

    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var input = TextInput.init(allocator, &unicode);
    defer input.deinit();
    const styles = DrawStyles{
        .panel = .{},
        .title = .{},
        .prompt = .{},
        .option = .{},
        .selected = .{},
        .hint = .{},
        .input = .{},
        .confirm = .{},
    };

    for ([_]u16{ 1, 2, 4, 20 }) |rows| {
        var screen = try tui.Screen.init(allocator, .{ .rows = rows, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(allocator);
        const win = tui.Window{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = screen.width,
            .height = screen.height,
            .screen = &screen,
            .unicode = &unicode,
        };
        var frame_storage: [4096]u8 = undefined;
        var frame_allocator = std.heap.FixedBufferAllocator.init(&frame_storage);
        state.confirming = false;
        state.question_index = 0;
        state.option_cursor = 0;
        state.draw(win, &input, styles, frame_allocator.allocator());

        // The active row must remain renderable when the question window has
        // scrolled to the final item in a large align-style batch.
        state.question_index = state.questions.items.len - 1;
        state.option_cursor = state.questions.items[state.question_index].options.items.len - 1;
        state.draw(win, &input, styles, frame_allocator.allocator());

        state.confirming = true;
        state.draw(win, &input, styles, frame_allocator.allocator());
    }
}
