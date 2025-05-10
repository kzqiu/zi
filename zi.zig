// kilo.zig - inspired by kilo.c

const std = @import("std");
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const posix = std.posix;

// editor constants
const kilo_version = "0.0.1";

const key = enum(u16) {
    left = 1000,
    down,
    up,
    right,
    del,
    home,
    end,
    page_up,
    page_down,
    _, // non-exhaustive for other characters
};

const mode = enum {
    normal,
    insert,
    visual,
};

// struct definitions
const pos = struct {
    x: u16 = 0,
    y: u16 = 0,
};

// TODO: add a mode enum field
const state = struct {
    dims: pos,
    cpos: pos,
};

fn initState() !state {
    return state{
        .dims = try getWindowSize(),
        .cpos = .{},
    };
}

// terminal mode switching
fn enableRawMode() !linux.termios {
    var original: linux.termios = undefined;
    const stdin_handle = io.getStdIn().handle;

    if (linux.tcgetattr(stdin_handle, &original) != 0) {
        return error.TCGetAttr;
    }

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

    if (linux.tcsetattr(stdin_handle, .FLUSH, &raw) != 0) {
        return error.TCSetAttr;
    }

    return original;
}

fn disableRawMode(original: linux.termios) void {
    _ = linux.tcsetattr(io.getStdIn().handle, .FLUSH, &original);
}

// input functions
fn readKey() !key {
    const stdin = io.getStdIn().reader();
    var buffer: [1]u8 = undefined;
    _ = try stdin.read(&buffer);

    // handle escape sequences
    if (buffer[0] == '\x1b') {
        var seq: [3]u8 = undefined;

        const l1 = try stdin.read(seq[0..1]);
        if (l1 != 1) return @enumFromInt('\x1b');

        const l2 = try stdin.read(seq[1..2]);
        if (l2 != 1) return @enumFromInt('\x1b');

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') { // page up/down
                const l3 = try stdin.read(seq[2..3]);
                if (l3 != 1) return @enumFromInt('\x1b');

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

        return @enumFromInt('\x1b');
    }

    return @enumFromInt(buffer[0]);
}

fn moveCursor(state_p: *state, k: key) void {
    switch (k) {
        .left => {
            if (state_p.cpos.x > 0) state_p.cpos.x -= 1;
        },
        .down => {
            if (state_p.cpos.y < state_p.dims.y - 1) state_p.cpos.y += 1;
        },
        .up => {
            if (state_p.cpos.y > 0) state_p.cpos.y -= 1;
        },
        .right => {
            if (state_p.cpos.x < state_p.dims.x - 1) state_p.cpos.x += 1;
        },
        .page_up, .page_down, .home, .end, .del => unreachable,
        _ => unreachable,
    }
}

fn processKeypress(state_p: *state) !bool {
    const k = try readKey();

    switch (k) {
        .left, .right, .up, .down => moveCursor(state_p, k),
        .home => state_p.cpos.x = 0,
        .end => state_p.cpos.x = state_p.dims.x - 1,
        .page_up, .page_down => {
            var count = state_p.dims.y;
            var dir = key.down;
            if (k == key.page_up) dir = key.up;
            while (count > 0) : (count -= 1) moveCursor(state_p, dir);
        },
        .del => {},
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

// output functions
fn drawRows(state_p: *state, append_buffer: *std.ArrayList(u8)) !void {
    const dims = state_p.dims;
    var y: u16 = 0;

    while (y < dims.y) : (y += 1) {
        if (y == dims.y / 3) {
            const welcome = "Kilo editor -- version " ++ kilo_version;
            const wl = @min(welcome.len, dims.x);

            // center welcome message
            var padding: u16 = (dims.x - wl) / 2;
            if (padding != 0) {
                try append_buffer.append('~');
                padding -= 1;
            }
            var i: u16 = 0;
            while (i < padding) : (i += 1) try append_buffer.append(' ');
            try append_buffer.appendSlice(welcome[0..wl]);
        } else try append_buffer.append('~');

        // erase to the right of cursor on current row (default arg: 0)
        try append_buffer.appendSlice("\x1b[K");
        if (y < dims.y - 1) try append_buffer.appendSlice("\r\n");
    }
}

fn refreshScreen(state_p: *state) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var append_buffer = std.ArrayList(u8).init(allocator);
    defer append_buffer.deinit();

    // (?25l) show cursor, (H) move cursor to top left
    try append_buffer.appendSlice("\x1b[?25l\x1b[H");

    try drawRows(state_p, &append_buffer);

    // TODO: asdf
    var buf: [32]u8 = undefined;
    const cursor_pos = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{
        state_p.cpos.y + 1,
        state_p.cpos.x + 1,
    });

    try append_buffer.appendSlice(cursor_pos);

    // (?25h) hide cursor
    try append_buffer.appendSlice("\x1b[?25h");

    _ = try io.getStdOut().write(append_buffer.items);
}

fn getCursorPos() !pos {
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

    var it = std.mem.tokenizeAny(u8, buffer[2..i], ";R");

    return .{
        .x = try std.fmt.parseInt(u16, it.next().?, 10),
        .y = try std.fmt.parseInt(u16, it.next().?, 10),
    };
}

fn getWindowSize() !pos {
    var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

    if (linux.ioctl(io.getStdOut().handle, posix.T.IOCGWINSZ, @intFromPtr(&window_size)) != 0 or window_size.col == 0) {
        // move cursor to bottom right
        _ = try io.getStdOut().write("\x1b[999C\x1b[999B");
        return try getCursorPos();
    }

    return .{ .x = window_size.col, .y = window_size.row };
}

pub fn main() !void {
    const original = try enableRawMode();
    defer disableRawMode(original);
    var cur_state = try initState();

    while (true) {
        try refreshScreen(&cur_state);
        const done = try processKeypress(&cur_state);
        if (done) break;
    }
}
