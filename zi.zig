// zi.zig - inspired by kilo.c
// zi = (v+4)i

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;
const time = std.time;
const linux = std.os.linux;
const posix = std.posix;

/// Editor Constants.
const kilo_version = "0.0.1";
const kilo_tab_stop = 8;
const kilo_quit_times = 2;

/// Global IO descriptors.
const stdout = io.getStdOut();
const stdin = io.getStdIn();

/// Key values (primarily actions).
/// Non-exhaustive so additional keys must be handled in _ branch.
const Key = enum(u16) {
    backspace = 127,
    left = 1000,
    down,
    up,
    right,
    del,
    home,
    end,
    page_up,
    page_down,
    to_normal,
    to_insert,
    _, // non-exhaustive for other characters
};

const Mode = enum {
    normal,
    insert,
    // command, // TODO: implement
    // visual, // TODO: implement
};

const Pos = struct {
    x: u32 = 0,
    y: u32 = 0,
};

const Row = struct {
    chars: std.ArrayList(u8),
    render: ?std.ArrayList(u8) = null,
};

const State = struct {
    cpos: Pos = .{},
    dims: Pos = .{},
    offset: Pos = .{},
    nrows: u32 = 0,
    rows: std.ArrayList(Row),
    rx: u32 = 0,
    filename: std.ArrayList(u8),
    status: [80]u8 = undefined,
    status_len: u32 = 0,
    status_time: i64 = 0,
    mode: Mode = .normal,
    dirty: u16 = 0,
    quit_count: u16 = kilo_quit_times,

    /// Set up state by getting window dims and initing text buffers.
    fn init(alloc: mem.Allocator) !State {
        var dims = try getWindowSize();
        dims.y -= 2;
        return State{
            .dims = dims,
            .rows = std.ArrayList(Row).init(alloc),
            .filename = std.ArrayList(u8).init(alloc),
        };
    }

    /// Deinitialize stored text buffers (actual and rendered).
    fn deinit(self: State) void {
        for (self.rows.items) |row| {
            row.chars.deinit();
            if (row.render) |render| render.deinit();
        }
        self.rows.deinit();
        self.filename.deinit();
    }
};

/// Switch terminal to raw mode and return original termios.
fn enableRawMode() !linux.termios {
    var original: linux.termios = undefined;

    if (linux.tcgetattr(stdin.handle, &original) != 0)
        return error.TCGetAttr;

    // TODO: add comments about raw mode flags
    var raw = original;
    raw.iflag = .{
        .BRKINT = false,
        .ICRNL = false,
        .INPCK = false,
        .ISTRIP = false,
        .IXON = false,
    };
    raw.cflag = .{
        .CSIZE = linux.CSIZE.CS8,
    };
    raw.lflag = .{
        .ECHO = false,
        .ICANON = false,
        .IEXTEN = false,
        .ISIG = false,
    };
    raw.oflag = .{ .OPOST = false };

    // wait for at most 0.1 seconds
    raw.cc[@intFromEnum(linux.V.MIN)] = 0;
    raw.cc[@intFromEnum(linux.V.TIME)] = 1;

    if (linux.tcsetattr(stdin.handle, .FLUSH, &raw) != 0)
        return error.TCSetAttr;

    return original;
}

/// Switch terminal back to original termios.
fn disableRawMode(original: linux.termios) void {
    _ = linux.tcsetattr(stdin.handle, .FLUSH, &original);
}

/// Get key input and return instruction.
fn readKey(state_p: *State) !Key {
    var buffer: [1]u8 = undefined;
    if (try stdin.read(&buffer) == 0) return @enumFromInt('\x00'); // no-op

    // handle escape sequences
    if (buffer[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        if (try stdin.read(seq[0..1]) != 1 or try stdin.read(seq[1..2]) != 1)
            return .to_normal;

        // if is escape sequence (not just escape key)
        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') { // page up/down
                if (try stdin.read(seq[2..3]) != 1) return .to_normal;

                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1', '7' => return .home,
                        '3' => return .del,
                        '4', '8' => return .end,
                        '5' => return .page_up,
                        '6' => return .page_down,
                        else => {},
                    }
                }
            } else { // arrow keys
                switch (seq[1]) {
                    'A' => return .up,
                    'B' => return .down,
                    'C' => return .right,
                    'D' => return .left,
                    'H' => return .home,
                    'F' => return .end,
                    else => {},
                }
            }
        } else if (seq[0] == 'O') { // other terminals
            switch (seq[1]) {
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        }

        return .to_normal;
    }

    if (state_p.mode == Mode.normal) {
        switch (buffer[0]) {
            'h' => return .left,
            'j' => return .down,
            'k' => return .up,
            'l' => return .right,
            'i' => return .to_insert,
            else => {},
        }
    }

    // return characters normally
    return @enumFromInt(buffer[0]);
}

/// Move cursor to rendered location.
/// Does not directly move cursor but sets location for rerendering.
fn moveCursor(state_p: *State, k: Key) void {
    // get row length if in file
    var row_len: ?usize = if (state_p.cpos.y < state_p.nrows)
        state_p.rows.items[state_p.cpos.y].chars.items.len
    else
        null;

    switch (k) {
        .left => {
            if (state_p.cpos.x != 0) {
                state_p.cpos.x -= 1;
            } else if (state_p.cpos.y > 0) {
                // go to end of prev line
                state_p.cpos.y -= 1;
                state_p.cpos.x = @intCast(state_p.rows.items[state_p.cpos.y].chars.items.len);
            }
        },
        .right => {
            if (row_len != null) {
                if (state_p.cpos.x < row_len.?) {
                    state_p.cpos.x += 1;
                } else if (state_p.cpos.x == row_len.?) {
                    // go to start of next line
                    state_p.cpos.y += 1;
                    state_p.cpos.x = 0;
                }
            }
        },
        .down => {
            if (state_p.cpos.y < state_p.nrows) state_p.cpos.y += 1;
        },
        .up => {
            if (state_p.cpos.y != 0) state_p.cpos.y -= 1;
        },
        else => unreachable,
    }

    // check that the row of new position is valid
    row_len = if (state_p.cpos.y < state_p.nrows)
        state_p.rows.items[state_p.cpos.y].chars.items.len
    else
        null;

    const new_row_len: u32 = if (row_len == null) 0 else @intCast(row_len.?);

    if (state_p.cpos.x > new_row_len) state_p.cpos.x = new_row_len;
}

/// Change editor mode.
fn changeMode(state_p: *State, mode_k: Key) !void {
    state_p.mode = switch (mode_k) {
        .to_normal => Mode.normal,
        .to_insert => Mode.insert,
        else => unreachable,
    };
}

/// Execute instruction from input.
fn processKeypress(alloc: mem.Allocator, state_p: *State) !bool {
    const k = try readKey(state_p);

    switch (k) {
        .left, .right, .up, .down => moveCursor(state_p, k),
        .home => state_p.cpos.x = 0,
        .end => if (state_p.cpos.y < state_p.nrows) {
            state_p.cpos.x = @intCast(state_p.rows.items[state_p.cpos.y].chars.items.len);
        },
        .page_up, .page_down => {
            if (k == .page_up) {
                state_p.cpos.y = state_p.offset.y;
            } else {
                state_p.cpos.y = state_p.offset.y + state_p.dims.y - 1;
                if (state_p.cpos.y > state_p.nrows) state_p.cpos.y = state_p.nrows;
            }

            var count = state_p.dims.y;
            var dir = Key.down;
            if (k == Key.page_up) dir = Key.up;
            while (count > 0) : (count -= 1) moveCursor(state_p, dir);
        },
        .del, .backspace => {
            if (k == .del) moveCursor(state_p, .right);
            try deleteChar(alloc, state_p);
        },
        .to_normal, .to_insert => try changeMode(state_p, k),
        _ => {
            // non-enum elements are handled directly as u16 values
            // we only want to handle u8 values here though
            // ensure that special keys are handled above!
            const c = @intFromEnum(k);
            switch (c) {
                // TODO: change this once we have commands
                'q' & 0x1f => { // ctrl + q
                    if (state_p.dirty != 0 and state_p.quit_count > 0) {
                        try setStatusMsg(state_p, "File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{state_p.quit_count});
                        state_p.quit_count -= 1;
                        return false;
                    }

                    _ = try stdout.write("\x1b[2J\x1b[H");
                    return true;
                },
                'h' & 0x1f => try deleteChar(alloc, state_p),
                '\r' => try insertNewLine(alloc, state_p),
                's' & 0x1f => {
                    try saveEditor(alloc, state_p);
                },
                '\x00', 'l' & 0x1f => {
                    return false;
                }, // no-op
                else => if (state_p.mode == Mode.insert) {
                    const char: u8 = @intCast(c);
                    try insertChar(alloc, state_p, char);
                },
            }
        },
    }

    state_p.quit_count = kilo_quit_times;
    return false;
}

/// Convert cursor x-pos to actual rendered x-pos.
fn rowCurXtoRX(row_p: *Row, cx: u32) u32 {
    var rx: u32 = 0;
    var i: usize = 0;

    while (i < cx) : (i += 1) {
        if (row_p.chars.items[i] == '\t')
            rx += kilo_tab_stop - 1 - rx % kilo_tab_stop;
        rx += 1;
    }

    return rx;
}

/// Modify row in place and render wide chars from raw lines.
fn renderRow(alloc: mem.Allocator, row_p: *Row) !void {
    if (row_p.render) |render| render.deinit();

    var new_render = std.ArrayList(u8).init(alloc);
    const chars = row_p.chars.items;
    var char_idx: usize = 0;
    var render_idx: usize = 0;

    // iterate over original characters
    while (char_idx < chars.len) : (char_idx += 1) {
        // render each tab according to tab stop
        if (chars[char_idx] == '\t') {
            // minimum of 1 space per tab
            try new_render.append(' ');
            render_idx += 1;

            while (render_idx % kilo_tab_stop != 0) : (render_idx += 1)
                try new_render.append(' ');
        } else {
            try new_render.append(chars[char_idx]);
            render_idx += 1;
        }
    }

    row_p.render = new_render;
}

/// Insert a row into file buffer.
fn insertRow(alloc: mem.Allocator, state_p: *State, idx: usize, line: []const u8) !void {
    if (idx < 0 or idx > state_p.nrows) return;

    var new_row = Row{
        .chars = std.ArrayList(u8).init(alloc),
        .render = null,
    };

    try new_row.chars.appendSlice(line);
    try renderRow(alloc, &new_row);
    try state_p.rows.insert(idx, new_row);

    state_p.nrows += 1;
    state_p.dirty += 1;
}

/// Delete row from file buffer.
fn deleteRow(state_p: *State, idx: usize) !void {
    if (idx < 0 or idx >= state_p.nrows) return;
    state_p.rows.items[idx].chars.deinit();
    if (state_p.rows.items[idx].render) |render| render.deinit();

    _ = state_p.rows.orderedRemove(idx);

    state_p.nrows -= 1;
    state_p.dirty += 1;
}

/// Insert character into a row at idx.
fn rowInsertChar(alloc: mem.Allocator, state_p: *State, row_p: *Row, idx: usize, char: u8) !void {
    const at = if (idx < 0 or idx > row_p.chars.items.len) row_p.chars.items.len else idx;
    try row_p.chars.insert(at, char);
    try renderRow(alloc, row_p);
    state_p.dirty += 1;
}

/// Append string to end of given row.
/// Used mostly when creating new/deleting row.
fn rowAppendString(alloc: mem.Allocator, state_p: *State, row_p: *Row, s: []const u8) !void {
    try row_p.chars.appendSlice(s);
    try renderRow(alloc, row_p);
    state_p.dirty += 1;
}

/// Insert character.
fn insertChar(alloc: mem.Allocator, state_p: *State, char: u8) !void {
    // TODO: current behavior when inserting at end is to continue trying to insert char
    // may want to have user create new line and then start inserting as separate chars
    if (state_p.cpos.y == state_p.nrows) try insertRow(alloc, state_p, 0, "");
    try rowInsertChar(alloc, state_p, &state_p.rows.items[state_p.cpos.y], state_p.cpos.x, char);
    state_p.cpos.x += 1;
}

/// Inserts new line into file buffer.
/// If performed in middle of line, it will carry over content.
fn insertNewLine(alloc: mem.Allocator, state_p: *State) !void {
    if (state_p.cpos.x == 0) {
        try insertRow(alloc, state_p, state_p.cpos.y, "");
    } else {
        const row_p = &state_p.rows.items[state_p.cpos.y];
        try insertRow(alloc, state_p, state_p.cpos.y + 1, row_p.chars.items[state_p.cpos.x..]);
        row_p.chars.shrinkRetainingCapacity(state_p.cpos.x);
        try renderRow(alloc, row_p);
    }

    state_p.cpos.y += 1;
    state_p.cpos.x = 0;
}

/// Delete character in specific row.
fn rowDeleteChar(alloc: mem.Allocator, state_p: *State, row_p: *Row, idx: usize) !void {
    if (idx < 0 or idx >= row_p.chars.items.len) return;
    _ = row_p.chars.orderedRemove(idx);
    try renderRow(alloc, row_p);
    state_p.dirty += 1;
}

/// Delete character.
fn deleteChar(alloc: mem.Allocator, state_p: *State) !void {
    const cx = state_p.cpos.x;
    const cy = state_p.cpos.y;
    if (cy == state_p.nrows or cx == 0 and cy == 0) return;

    if (cx > 0) {
        try rowDeleteChar(alloc, state_p, &state_p.rows.items[cy], cx - 1);
        state_p.cpos.x -= 1;
    } else {
        state_p.cpos.x = @intCast(state_p.rows.items[cy - 1].chars.items.len);
        try rowAppendString(alloc, state_p, &state_p.rows.items[cy - 1], state_p.rows.items[cy].chars.items);
        try deleteRow(state_p, cy);
        state_p.cpos.y -= 1;
    }
}

/// Convert rows to a single string.
/// SAFETY: Make sure to free buffer after using the buffer in caller!
fn rowsToString(alloc: mem.Allocator, state_p: *State) ![]u8 {
    // first get size of buffer to allocate
    var total_len: usize = 0;
    for (state_p.rows.items) |r| total_len += r.chars.items.len + 1;
    const buf = try alloc.alloc(u8, total_len);

    // now copy the memory from the rows to the buffer
    var pos: usize = 0;
    for (state_p.rows.items) |r| {
        const len: usize = r.chars.items.len;
        @memcpy(buf[pos .. pos + len], r.chars.items);
        buf[pos + len] = '\n';
        pos += len + 1;
    }

    return buf;
}

/// Open editor and load lines from provided file.
fn openEditor(alloc: mem.Allocator, state_p: *State, path: [:0]const u8) !void {
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();

    try state_p.filename.appendSlice(path);
    var reader = std.io.bufferedReader(file.reader());
    var stream = reader.reader();

    // temporary line buffer
    var line = std.ArrayList(u8).init(alloc);
    defer line.deinit();
    const writer = line.writer();

    while (stream.streamUntilDelimiter(writer, '\n', null)) {
        defer line.clearRetainingCapacity();
        try insertRow(alloc, state_p, state_p.nrows, mem.trim(u8, line.items, "\r\n"));
    } else |err| switch (err) {
        error.EndOfStream => {}, // do nothing
        else => return err,
    }

    state_p.dirty = 0;
}

/// Save changes from file buffer to file.
fn saveEditor(alloc: mem.Allocator, state_p: *State) !void {
    if (state_p.filename.items.len == 0) return;

    const buf = try rowsToString(alloc, state_p);
    defer alloc.free(buf);

    const f = try fs.cwd().createFile(
        state_p.filename.items,
        .{ .truncate = true, .mode = 0o666 },
    );
    defer f.close();

    try f.writeAll(buf);
    state_p.dirty = 0;
    try setStatusMsg(state_p, "{d} bytes written to disk", .{buf.len});
}

/// Scroll editor window to cursor location.
fn scrollEditor(state_p: *State) void {
    const y = state_p.cpos.y;
    state_p.rx = 0;

    // use special function to handle wide chars like tabs (cur x vs renderd x)
    if (y < state_p.nrows)
        state_p.rx = rowCurXtoRX(&state_p.rows.items[y], state_p.cpos.x);

    const x = state_p.rx;

    if (y < state_p.offset.y)
        state_p.offset.y = y;

    if (y >= state_p.offset.y + state_p.dims.y)
        state_p.offset.y = y - state_p.dims.y + 1;

    if (x < state_p.offset.x)
        state_p.offset.x = x;

    if (x >= state_p.offset.x + state_p.dims.x)
        state_p.offset.x = x - state_p.dims.x + 1;
}

/// Draw file rows.
/// Empty rows are rendered with '~'.
/// TODO: add line number rendering max line number width with 2 space padding
fn drawRows(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    const dims = state_p.dims;
    var y: u32 = 0;

    // render each row
    while (y < dims.y) : (y += 1) {
        const file_row = y + state_p.offset.y;

        if (file_row >= state_p.nrows) {
            // draw welcome if file is empty/no file is specified
            if (state_p.nrows == 0 and y == dims.y / 3) {
                const welcome = "zi = (v+4)i -- version " ++ kilo_version;
                const len = @min(welcome.len, dims.x);

                var padding: u32 = (dims.x - len) / 2;

                if (padding != 0) {
                    try append_buffer.append('~');
                    padding -= 1;
                }

                var i: u32 = 0;
                while (i < padding) : (i += 1) try append_buffer.append(' ');
                try append_buffer.appendSlice(welcome[0..len]);
            } else { // start remaining lines with '~'
                try append_buffer.append('~');
            }
        } else {
            // row to render
            const line = state_p.rows.items[file_row].render.?.items;
            const offset: usize = @intCast(state_p.offset.x);
            const scols: usize = @intCast(state_p.dims.x);

            // clamp length of row to window size
            const len = if (line.len < offset)
                0
            else if (line.len - offset > scols)
                scols
            else
                line.len - offset;

            if (len != 0) try append_buffer.appendSlice(line[offset .. offset + len]);
        }

        // erase to the right of cursor on current row (default arg: 0)
        try append_buffer.appendSlice("\x1b[K\r\n");
    }
}

/// Draw status bar.
fn drawStatus(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    // (7m) invert colors and draw mode with padding on both sides
    try append_buffer.appendSlice("\x1b[7m ");
    try append_buffer.appendSlice(@tagName(state_p.mode));
    try append_buffer.append(' ');

    var status: [80]u8 = undefined;
    var rstatus: [80]u8 = undefined;

    const name = if (state_p.filename.items.len == 0)
        "[No Name]"
    else
        state_p.filename.items;

    const name_s = if (state_p.dirty == 0)
        try fmt.bufPrint(&status, "{s}", .{name})
    else
        try fmt.bufPrint(&status, "{s} (modified)", .{name});
    const row_s = try fmt.bufPrint(
        &rstatus,
        " {d}/{d} ",
        .{ state_p.cpos.y + 1, state_p.nrows },
    );

    const mode_len: usize = 8;
    var name_len: usize = name_s.len;
    const row_len: usize = row_s.len;
    var i: usize = mode_len;

    // ensure that filename fits on screen with mode and row counts
    if (name_len > state_p.dims.x - mode_len - row_len)
        name_len = @intCast(state_p.dims.x - mode_len - row_len);

    // add padding between mode and filename
    while (i < (state_p.dims.x - name_len) / 2) : (i += 1)
        try append_buffer.append(' ');

    // add file name
    try append_buffer.appendSlice(name_s[0..name_len]);

    i += name_len;

    // print end of line (line numbers)
    while (i < state_p.dims.x) : (i += 1) {
        if (state_p.dims.x - i == row_len) {
            try append_buffer.appendSlice(row_s);
            break;
        }
        try append_buffer.append(' ');
    }

    try append_buffer.appendSlice("\x1b[m\r\n");
}

/// Draw status message bar.
fn drawMsgBar(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    // clear status bar
    try append_buffer.appendSlice("\x1b[K");
    var len = state_p.status_len;
    if (len > state_p.dims.x) len = state_p.dims.x;

    // draw message if less than 5 seconds old
    if (len != 0 and time.milliTimestamp() - state_p.status_time < 5000)
        try append_buffer.appendSlice(state_p.status[0..len]);
}

/// Refresh screen and draw all regions.
/// Allocates new append buffer each time.
fn refreshScreen(alloc: mem.Allocator, state_p: *State) !void {
    scrollEditor(state_p);

    var append_buffer = std.ArrayList(u8).init(alloc);
    defer append_buffer.deinit();

    // (?25l) show cursor, (H) move cursor to top left
    try append_buffer.appendSlice("\x1b[?25l\x1b[H");

    try drawRows(state_p, &append_buffer);
    try drawStatus(state_p, &append_buffer);
    try drawMsgBar(state_p, &append_buffer);

    var buf: [32]u8 = undefined;
    const cursor_pos = try fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{
        state_p.cpos.y - state_p.offset.y + 1,
        state_p.rx - state_p.offset.x + 1,
    });

    try append_buffer.appendSlice(cursor_pos);

    const cursor_style = if (state_p.mode == Mode.insert) "\x1b[6 q" else "\x1b[2 q";

    try append_buffer.appendSlice(cursor_style);

    // (?25h) hide cursor
    try append_buffer.appendSlice("\x1b[?25h");

    _ = try stdout.write(append_buffer.items);
}

/// Set status message.
/// TODO: handle rendering command buffer
fn setStatusMsg(state_p: *State, comptime format: []const u8, args: anytype) !void {
    const s = try fmt.bufPrint(&state_p.status, format, args);
    state_p.status_len = @intCast(s.len);
    state_p.status_time = time.milliTimestamp();
}

/// Get current cursor position.
/// Used to determine window size using only escape sequences.
fn getCursorPos() !Pos {
    // retrieve cursor location
    // buffer becomes \x1b[XXX;YYYR.. so we need to parse
    _ = try stdout.write("\x1b[6n");

    var buffer: [32]u8 = undefined;
    var i: u8 = 0;

    while (i < buffer.len - 1) : (i += 1) {
        const len = try stdin.read(buffer[i .. i + 1]);
        if (len != 1 or buffer[i] == 'R') break;
    }

    // ensure that escape sequence is well-formed
    if (buffer[0] != '\x1b' or buffer[1] != '[') return error.BadValue;

    var it = mem.tokenizeAny(u8, buffer[2..i], ";R");

    return .{
        .x = try fmt.parseInt(u32, it.next().?, 10),
        .y = try fmt.parseInt(u32, it.next().?, 10),
    };
}

/// Attempt to get current window size.
/// Trys using ioctl or else escape sequences.
fn getWindowSize() !Pos {
    var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

    if (linux.ioctl(stdout.handle, posix.T.IOCGWINSZ, @intFromPtr(&window_size)) != 0 or window_size.col == 0) {
        // move cursor to bottom right
        _ = try stdout.write("\x1b[999C\x1b[999B");
        return try getCursorPos();
    }

    return .{ .x = window_size.col, .y = window_size.row };
}

/// Entry point to program.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // set up tui by changing terminal to raw mode
    const original = try enableRawMode();
    defer disableRawMode(original);

    // set up editor state (file buffers)
    var state = try State.init(alloc);
    defer state.deinit();

    // use only the first file
    if (os.argv.len >= 2) {
        // convert from sentinel terminated string to slice
        const path: [:0]const u8 = mem.span(os.argv[1]);
        try openEditor(alloc, &state, path);
    }

    // initial message
    try setStatusMsg(&state, "HELP: Ctrl-Q = quit | Ctrl-S = save", .{});

    // render/action loop
    while (true) {
        try refreshScreen(alloc, &state);
        const done = try processKeypress(alloc, &state);
        if (done) break;
    }
}
