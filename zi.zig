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

// editor constants
const kilo_version = "0.0.1";
const tab_stop = 8;

const Key = enum(u16) {
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

// struct definitions
const Pos = struct {
    x: u32 = 0,
    y: u32 = 0,
};

const Row = struct {
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),
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

    fn init(allocator: mem.Allocator) !State {
        var dims = try getWindowSize();
        dims.y -= 2;
        return State{
            .dims = dims,
            .rows = std.ArrayList(Row).init(allocator),
            .filename = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: State) void {
        for (self.rows.items) |row| {
            row.chars.deinit();
            row.render.deinit();
        }
        self.rows.deinit();
        self.filename.deinit();
    }
};

// terminal mode switching
fn enableRawMode() !linux.termios {
    var original: linux.termios = undefined;
    const stdin_handle = io.getStdIn().handle;

    if (linux.tcgetattr(stdin_handle, &original) != 0)
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

    raw.cc[@intFromEnum(linux.V.MIN)] = 0;
    raw.cc[@intFromEnum(linux.V.TIME)] = 1;

    if (linux.tcsetattr(stdin_handle, .FLUSH, &raw) != 0)
        return error.TCSetAttr;

    return original;
}

fn disableRawMode(original: linux.termios) void {
    _ = linux.tcsetattr(io.getStdIn().handle, .FLUSH, &original);
}

// input functions
// get a character from the system and process them to be useable
// modes are not handled here
fn readKey(state_p: *State) !Key {
    const stdin = io.getStdIn().reader();
    var buffer: [1]u8 = undefined;
    _ = try stdin.read(&buffer);

    // handle escape sequences
    if (buffer[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        if (try stdin.read(seq[0..1]) != 1) return .to_normal;
        if (try stdin.read(seq[1..2]) != 1) return .to_normal;

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') { // page up/down
                const l3 = try stdin.read(seq[2..3]);
                if (l3 != 1) return .to_normal;

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
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return .home,
                'F' => return .end,
                else => {},
            }
        }

        return .to_normal;
    }

    // TODO: handle movement in visual mode
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

    return @enumFromInt(buffer[0]);
}

fn moveCursor(state_p: *State, k: Key) void {
    var row_len: ?usize = if (state_p.cpos.y >= state_p.nrows)
        null
    else
        state_p.rows.items[state_p.cpos.y].chars.items.len;

    switch (k) {
        .left => {
            if (state_p.cpos.x != 0) {
                state_p.cpos.x -= 1;
            } else if (state_p.cpos.y > 0) {
                state_p.cpos.y -= 1;
                state_p.cpos.x = @intCast(state_p.rows.items[state_p.cpos.y].chars.items.len);
            }
        },
        .right => {
            if (row_len != null and state_p.cpos.x < row_len.?) {
                state_p.cpos.x += 1;
            } else if (row_len != null and state_p.cpos.x == row_len.?) {
                state_p.cpos.y += 1;
                state_p.cpos.x = 0;
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

    row_len = if (state_p.cpos.y >= state_p.nrows)
        null
    else
        state_p.rows.items[state_p.cpos.y].chars.items.len;

    const new_row_len: u32 = if (row_len == null) 0 else @intCast(row_len.?);

    if (state_p.cpos.x > new_row_len) state_p.cpos.x = new_row_len;
}

// get keypresses and execute actions
fn processKeypress(state_p: *State) !bool {
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
        .del => {},
        .to_normal => state_p.mode = Mode.normal,
        .to_insert => state_p.mode = Mode.insert,
        _ => {
            const c = @intFromEnum(k);
            switch (c) {
                // TODO: change this once we have commands
                'q' & 0x1f => { // ctrl + q
                    _ = try io.getStdOut().write("\x1b[2J\x1b[H");
                    return true;
                },
                else => {},
            }
        },
    }

    return false;
}

fn rowCurXtoRX(row_p: *Row, cx: u32) u32 {
    var rx: u32 = 0;
    var i: usize = 0;

    while (i < cx) : (i += 1) {
        if (row_p.chars.items[i] == '\t')
            rx += tab_stop - 1 - rx % tab_stop;
        rx += 1;
    }

    return rx;
}

fn renderRow(allocator: mem.Allocator, row_p: *Row) !void {
    var new_render = std.ArrayList(u8).init(allocator);
    const chars = row_p.chars.items;
    var char_idx: usize = 0;
    var render_idx: usize = 0;

    while (char_idx < chars.len) : (char_idx += 1) {
        if (chars[char_idx] == '\t') {
            try new_render.append(' ');
            render_idx += 1;
            while (render_idx % tab_stop != 0) : (render_idx += 1) {
                try new_render.append(' ');
            }
        } else {
            try new_render.append(chars[char_idx]);
            render_idx += 1;
        }
    }

    row_p.render = new_render;
}

fn appendRow(allocator: mem.Allocator, state_p: *State, line: []const u8) !void {
    var new_line = std.ArrayList(u8).init(allocator);
    try new_line.appendSlice(line);

    // TODO: make render an optional and initialize as null
    var new_row = Row{ .chars = new_line, .render = undefined };
    try renderRow(allocator, &new_row);

    try state_p.rows.append(new_row);

    state_p.nrows += 1;
}

fn openEditor(allocator: mem.Allocator, state_p: *State, path: [:0]const u8) !void {
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();
    try state_p.filename.appendSlice(path);

    var reader = std.io.bufferedReader(file.reader());
    var stream = reader.reader();

    while (try stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024)) |line| {
        try appendRow(allocator, state_p, mem.trim(u8, line, "\r\n"));
    }
}

fn scrollEditor(state_p: *State) void {
    const y = state_p.cpos.y;

    state_p.rx = 0;

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

// output functions
fn drawRows(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    const dims = state_p.dims;
    var y: u32 = 0;

    while (y < dims.y) : (y += 1) {
        const file_row = y + state_p.offset.y;
        if (file_row >= state_p.nrows) {
            if (state_p.nrows == 0 and y == dims.y / 3) {
                const welcome = "zi = (v+4)i -- version " ++ kilo_version;
                const len = @min(welcome.len, dims.x);

                // center welcome message
                var padding: u32 = (dims.x - len) / 2;
                if (padding != 0) {
                    try append_buffer.append('~');
                    padding -= 1;
                }

                var i: u32 = 0;
                while (i < padding) : (i += 1) try append_buffer.append(' ');
                try append_buffer.appendSlice(welcome[0..len]);
            } else try append_buffer.append('~');
        } else {
            const line = state_p.rows.items[file_row].render.items;

            const offset: usize = @intCast(state_p.offset.x);
            const scols: usize = @intCast(state_p.dims.x);
            const len = if (line.len < offset) 0 else if (line.len - offset > scols) scols else line.len - offset;

            // append row
            if (len != 0) try append_buffer.appendSlice(line[offset .. offset + len]);
        }

        // erase to the right of cursor on current row (default arg: 0)
        try append_buffer.appendSlice("\x1b[K\r\n");
    }
}

fn drawStatus(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    try append_buffer.appendSlice("\x1b[7m ");
    try append_buffer.appendSlice(@tagName(state_p.mode));
    try append_buffer.append(' ');

    var status: [80]u8 = undefined;
    var rstatus: [80]u8 = undefined;

    const name = if (state_p.filename.items.len == 0) "[No Name]" else state_p.filename.items;
    const name_s = try fmt.bufPrint(&status, "{s}", .{name});
    const row_s = try fmt.bufPrint(&rstatus, "{d}/{d} ", .{ state_p.cpos.y + 1, state_p.nrows });

    const mode_len: usize = 8;
    var name_len: usize = name_s.len;
    const row_len: usize = row_s.len;
    var i: usize = mode_len; // mode takes up 8 chars (6 + 2 padding)

    if (name_len > state_p.dims.x - mode_len - row_len) name_len = @intCast(state_p.dims.x - mode_len - row_len);

    // add padding before title
    while (i < (state_p.dims.x - name_len) / 2) : (i += 1) try append_buffer.append(' ');

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

fn drawMsgBar(state_p: *State, append_buffer: *std.ArrayList(u8)) !void {
    try append_buffer.appendSlice("\x1b[K");
    var len = state_p.status_len;
    if (len > state_p.dims.x) len = state_p.dims.x;
    if (len != 0 and time.milliTimestamp() - state_p.status_time < 5000)
        try append_buffer.appendSlice(state_p.status[0..len]);
}

fn refreshScreen(allocator: mem.Allocator, state_p: *State) !void {
    scrollEditor(state_p);

    var append_buffer = std.ArrayList(u8).init(allocator);
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

    // (?25h) hide cursor
    try append_buffer.appendSlice("\x1b[?25h");

    _ = try io.getStdOut().write(append_buffer.items);
}

fn setStatusMsg(state_p: *State, comptime format: []const u8, args: anytype) !void {
    const s = try fmt.bufPrint(&state_p.status, format, args);
    state_p.status_len = @intCast(s.len);
    state_p.status_time = time.milliTimestamp();
}

fn getCursorPos() !Pos {
    const stdin = io.getStdIn().reader();

    // retrieve cursor location
    // buffer becomes \x1b[XXX;YYYR.. so we need to parse
    _ = try io.getStdOut().write("\x1b[6n");

    var buffer: [32]u8 = undefined;
    var i: u8 = 0;

    while (i < buffer.len - 1) : (i += 1) {
        const len = try stdin.read(buffer[i .. i + 1]);
        if (len != 1 or buffer[i] == 'R') break;
    }

    if (buffer[0] != '\x1b' or buffer[1] != '[') return error.BadValue;

    var it = mem.tokenizeAny(u8, buffer[2..i], ";R");

    return .{
        .x = try fmt.parseInt(u32, it.next().?, 10),
        .y = try fmt.parseInt(u32, it.next().?, 10),
    };
}

fn getWindowSize() !Pos {
    var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

    if (linux.ioctl(io.getStdOut().handle, posix.T.IOCGWINSZ, @intFromPtr(&window_size)) != 0 or window_size.col == 0) {
        // move cursor to bottom right
        _ = try io.getStdOut().write("\x1b[999C\x1b[999B");
        return try getCursorPos();
    }

    return .{ .x = window_size.col, .y = window_size.row };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // set up tui
    const original = try enableRawMode();
    defer disableRawMode(original);

    // set up file buffer/editor state
    var state = try State.init(allocator);
    defer state.deinit();

    if (os.argv.len >= 2) {
        // convert from sentinel terminated string to slice
        const path: [:0]const u8 = mem.span(os.argv[1]);
        try openEditor(allocator, &state, path);
    }

    try setStatusMsg(&state, "HELP: Ctrl-Q = quit", .{});

    while (true) {
        try refreshScreen(allocator, &state);
        const done = try processKeypress(&state);
        if (done) break;
    }
}
