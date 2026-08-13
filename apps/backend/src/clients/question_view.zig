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
        const question = self.questions.items[self.question_index];
        const needed: u16 = if (self.confirming)
            @intCast(@min(self.questions.items.len + 6, @as(usize, std.math.maxInt(u16))))
        else
            @intCast(@min(question.options.items.len + 6, @as(usize, std.math.maxInt(u16))));
        return @min(root_height, @max(@as(u16, 6), needed));
    }

    pub fn handleKey(self: *State, key: tui.Key, input: *TextInput) !Action {
        if (key.matches('c', .{ .ctrl = true })) return .cancel;

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
        if (key.matches(tui.Key.up, .{}) or key.matches(tui.Key.left, .{})) {
            if (self.option_cursor > 0) self.option_cursor -= 1;
            return .consumed;
        }
        if (key.matches(tui.Key.down, .{}) or key.matches(tui.Key.right, .{})) {
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

    pub fn responseJson(self: *const State, allocator: std.mem.Allocator, cancelled: bool) ![]u8 {
        if (cancelled) return input_protocol.serializeResponse(allocator, self.request_id, true, &.{});

        var answers = try allocator.alloc(input_protocol.Answer, self.questions.items.len);
        defer allocator.free(answers);
        var selections = try allocator.alloc([]const []const u8, self.questions.items.len);
        defer {
            for (selections) |selection| allocator.free(selection);
            allocator.free(selections);
        }

        for (self.questions.items, 0..) |question, index| {
            var count: usize = 0;
            for (question.options.items) |option| {
                if (option.selected) count += 1;
            }
            const selection = try allocator.alloc([]const u8, count);
            selections[index] = selection;
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
        if (self.confirming) {
            _ = win.print(&.{.{ .text = " Confirm answers", .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
            _ = win.print(&.{.{ .text = "Enter submit · Esc back", .style = styles.hint }}, .{ .row_offset = 1, .wrap = .none });
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

        const question = self.questions.items[self.question_index];
        var header_buffer: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, " Questions {d}/{d} · Enter select · Space check", .{ self.question_index + 1, self.questions.items.len }) catch " Questions";
        _ = win.print(&.{.{ .text = header, .style = styles.title }}, .{ .row_offset = 0, .wrap = .none });
        const prompt = truncate(question.prompt, @max(@as(usize, 1), @as(usize, win.width -| 2)));
        _ = win.print(&.{.{ .text = prompt, .style = styles.prompt }}, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });

        if (self.editing_other) {
            _ = win.print(&.{.{ .text = "Other: ", .style = styles.option }}, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });
            input.drawWithStyle(win.child(.{ .x_off = 8, .y_off = 3, .width = win.width -| 9, .height = 1 }), styles.input);
            return;
        }

        var col: usize = 1;
        var row: usize = 3;
        for (question.options.items, 0..) |option, index| {
            const label = optionDisplay(self.allocator, option, index, self.option_cursor) catch continue;
            defer self.allocator.free(label);
            const width = @min(label.len + 3, @as(usize, win.width));
            if (col > 1 and col + width >= win.width) {
                col = 1;
                row += 1;
            }
            if (row >= win.height) break;
            _ = win.print(&.{.{ .text = label, .style = if (option.selected) styles.selected else styles.option }}, .{ .row_offset = @intCast(row), .col_offset = @intCast(col), .wrap = .none });
            col += width;
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
    if (value.len <= width) return value;
    if (width <= 1) return value[0..width];
    return value[0 .. width - 1];
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
