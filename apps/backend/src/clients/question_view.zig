const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const input_protocol = VAR1.shared.protocol.input;

const TextInput = tui.widgets.TextInput;

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
        var parsed = try std.json.parseFromSlice(input_protocol.Request, allocator, request_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.request_id.len == 0 or parsed.value.questions.len == 0 or
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
                self.advanceOrConfirm();
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
            const option = &question.options.items[self.option_cursor];
            option.selected = !option.selected;
            if (!option.selected and std.mem.eql(u8, option.id, "f")) {
                if (question.other_text) |value| self.allocator.free(value);
                question.other_text = null;
            }
            return .consumed;
        }
        if (key.matches(tui.Key.enter, .{})) {
            const current = &question.options.items[self.option_cursor];
            if (!question.multiple) {
                for (question.options.items) |*option| option.selected = false;
            }
            current.selected = true;
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

    pub fn draw(self: *const State, win: tui.Window, input: *TextInput, styles: DrawStyles) void {
        win.fill(.{ .style = styles.panel });
        if (win.width == 0 or win.height == 0 or self.questions.items.len == 0) return;
        if (self.confirming) {
            _ = win.print(&.{.{ .text = " Confirm answers", .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
            _ = win.print(&.{.{ .text = "Enter submit · Esc back", .style = styles.hint }}, .{ .row_offset = 1, .wrap = .none });
            _ = win.print(&.{.{ .text = "────────────────────────────────────────────────────────────────", .style = styles.hint }}, .{ .row_offset = 2, .wrap = .none });
            var row: usize = 3;
            for (self.questions.items) |question| {
                if (row >= win.height) break;
                const summary = formatAnswerSummary(self.allocator, question) catch continue;
                defer self.allocator.free(summary);
                _ = win.print(&.{.{ .text = summary, .style = styles.confirm }}, .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });
                row += 1;
            }
            if (self.confirm_error and row < win.height) {
                _ = win.print(&.{.{ .text = "Choose an answer and complete every selected Other option.", .style = styles.hint }}, .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });
            }
            return;
        }

        const active_index = @min(self.question_index, self.questions.items.len - 1);
        var header_buffer: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, " Questions {d}/{d} · ↑/↓ question · ←/→ option · Tab next", .{ active_index + 1, self.questions.items.len }) catch " Questions";
        _ = win.print(&.{.{ .text = header, .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
        _ = win.print(&.{.{ .text = "────────────────────────────────────────────────────────────────", .style = styles.hint }}, .{ .row_offset = 1, .wrap = .none });

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
            self.drawQuestionRow(win, question, question_index == active_index, row, styles);
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
    ) void {
        if (row >= win.height or win.width == 0) return;
        const prompt_width = @min(@as(usize, 28), @max(@as(usize, 10), @as(usize, win.width) / 3));
        var prompt_buffer: [256]u8 = undefined;
        const prompt_limit = prompt_width -| 2;
        const prompt = truncate(question.prompt, prompt_limit);
        const prompt_text = std.fmt.bufPrint(&prompt_buffer, "{s} {s}", .{ if (active) "›" else " ", prompt }) catch prompt;
        _ = win.print(&.{.{ .text = prompt_text, .style = if (active) styles.selected else styles.prompt }}, .{ .row_offset = @intCast(row), .col_offset = 1, .wrap = .none });

        var col: usize = prompt_width + 3;
        for (question.options.items, 0..) |option, option_index| {
            if (col >= win.width) break;
            const label = optionDisplay(self.allocator, option, option_index, if (active) self.option_cursor else std.math.maxInt(usize)) catch continue;
            defer self.allocator.free(label);
            const available = @as(usize, win.width) - col;
            const visible_label = truncate(label, available);
            if (visible_label.len == 0) break;
            _ = win.print(&.{.{ .text = visible_label, .style = if (active and option_index == self.option_cursor) styles.selected else if (option.selected) styles.confirm else styles.option }}, .{ .row_offset = @intCast(row), .col_offset = @intCast(col), .wrap = .none });
            col += @min(available, label.len + 2);
        }
    }
};

fn optionDisplay(allocator: std.mem.Allocator, option: Option, index: usize, cursor: usize) ![]u8 {
    const marker = if (option.selected) "✓" else if (index == cursor) "›" else " ";
    return std.fmt.allocPrint(allocator, "{s} {s}) {s}", .{ marker, option.id, option.label });
}

fn formatAnswerSummary(allocator: std.mem.Allocator, question: Question) ![]u8 {
    var selected = std.array_list.Managed(u8).init(allocator);
    defer selected.deinit();
    try selected.writer().print("{s}: ", .{question.prompt});
    var first = true;
    for (question.options.items) |option| {
        if (!option.selected) continue;
        if (!first) try selected.writer().writeAll(", ");
        first = false;
        try selected.writer().writeAll(option.label);
        if (std.mem.eql(u8, option.id, "f")) {
            if (question.other_text) |value| try selected.writer().print(" = {s}", .{value});
        }
    }
    if (first) try selected.writer().writeAll("(none)");
    return selected.toOwnedSlice();
}

fn truncate(value: []const u8, width: usize) []const u8 {
    if (width == 0 or value.len == 0) return value[0..0];
    var byte_index: usize = 0;
    var codepoints: usize = 0;
    while (byte_index < value.len and codepoints < width) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[byte_index]) catch 1;
        if (byte_index + sequence_len > value.len) break;
        byte_index += sequence_len;
        codepoints += 1;
    }
    return value[0..byte_index];
}

test "question controller selects, confirms, and serializes answers" {
    var state = try State.initFromJson(std.testing.allocator,
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
    var state = try State.initFromJson(std.testing.allocator,
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
    var state = try State.initFromJson(std.testing.allocator,
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
