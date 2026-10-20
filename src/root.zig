const std = @import("std");

pub const Memory = struct {
    data: [1 << 16]u8 = [_]u8{0} ** (1 << 16),

    pub fn read(self: *Memory, address: u16) u8 {
        return self.data[address];
    }

    pub fn write(self: *Memory, address: u16, value: u8) void {
        self.data[address] = value;
    }
};

pub const Instruction = struct {
    pub const Op = enum { lda, sta, inx, nop };
    pub const Mode = enum { immediate, zero_page, absolute, implied };

    op: Op,
    mode: Mode = .implied,
    cycles: u8,

    pub fn decode(opcode: u8) error{UnsupportedOpcode}!Instruction {
        return switch (opcode) {
            0xA9 => .{ .op = .lda, .mode = .immediate, .cycles = 2 },
            0xA5 => .{ .op = .lda, .mode = .zero_page, .cycles = 3 },
            0xAD => .{ .op = .lda, .mode = .absolute, .cycles = 4 },
            0x8D => .{ .op = .sta, .mode = .absolute, .cycles = 4 },
            0xE8 => .{ .op = .inx, .cycles = 2 },
            0xEA => .{ .op = .nop, .cycles = 2 },
            else => error.UnsupportedOpcode,
        };
    }
};

/// The bus must provide read(*Bus, u16) u8 and write(*Bus, u16, u8) void.
/// Register defaults are a test state, not a hardware reset sequence.
pub fn Cpu(comptime Bus: type) type {
    return struct {
        const Self = @This();

        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        sp: u8 = 0,
        pc: u16 = 0,
        p: u8 = 0,
        bus: *Bus,

        fn fetch8(self: *Self) u8 {
            const value = self.bus.read(self.pc);
            self.pc +%= 1;
            return value;
        }

        fn fetch16(self: *Self) u16 {
            const lo: u16 = self.fetch8();
            const hi: u16 = self.fetch8();
            return lo | (hi << 8);
        }

        fn operand(self: *Self, comptime mode: Instruction.Mode) u8 {
            return switch (mode) {
                .immediate => self.fetch8(),
                .zero_page => self.bus.read(self.fetch8()),
                .absolute => self.bus.read(self.fetch16()),
                .implied => unreachable,
            };
        }

        fn setZN(self: *Self, value: u8) void {
            const zero: u8 = 0x02;
            const negative: u8 = 0x80;
            const z: u8 = if (value == 0) zero else 0;
            self.p = (self.p & ~(zero | negative)) | z | (value & negative);
        }

        fn lda(self: *Self, value: u8) void {
            self.a = value;
            self.setZN(value);
        }

        /// Execute one instruction and return its cycle count.
        /// Unsupported opcodes consume the opcode byte before returning an error.
        /// This does not model cycle-by-cycle bus activity or interrupts.
        pub fn step(self: *Self) error{UnsupportedOpcode}!u8 {
            const instruction = try Instruction.decode(self.fetch8());

            switch (instruction.op) {
                .lda => {
                    // Select at runtime, then pass a comptime-known mode.
                    const value = switch (instruction.mode) {
                        .immediate => self.operand(.immediate),
                        .zero_page => self.operand(.zero_page),
                        .absolute => self.operand(.absolute),
                        .implied => unreachable,
                    };
                    self.lda(value);
                },
                .sta => {
                    // Only absolute addressing is currently supported for STA.
                    const address = self.fetch16();
                    self.bus.write(address, self.a);
                },
                .inx => {
                    self.x +%= 1;
                    self.setZN(self.x);
                },
                .nop => {},
            }

            return instruction.cycles;
        }
    };
}

pub const CPU = Cpu(Memory);

test "LDA reads immediate, zero-page and little-endian absolute operands" {
    var memory: Memory = .{};
    var cpu: CPU = .{ .bus = &memory, .pc = 0x8000, .p = 0x7d };
    const program = [_]u8{
        0xA9, 0x00, // LDA #$00
        0xA5, 0xFF, // LDA $FF
        0xAD, 0x34, 0x12, // LDA $1234
    };
    @memcpy(memory.data[0x8000..][0..program.len], &program);
    memory.data[0x00ff] = 0x80;
    memory.data[0x1234] = 0x42;

    try std.testing.expectEqual(@as(u8, 2), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x00), cpu.a);
    try std.testing.expectEqual(@as(u8, 0x7f), cpu.p);
    try std.testing.expectEqual(@as(u16, 0x8002), cpu.pc);

    try std.testing.expectEqual(@as(u8, 3), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x80), cpu.a);
    try std.testing.expectEqual(@as(u8, 0xfd), cpu.p);
    try std.testing.expectEqual(@as(u16, 0x8004), cpu.pc);

    try std.testing.expectEqual(@as(u8, 4), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqual(@as(u8, 0x7d), cpu.p);
    try std.testing.expectEqual(@as(u16, 0x8007), cpu.pc);
}

test "STA writes the accumulator without changing flags" {
    var memory: Memory = .{};
    var cpu: CPU = .{ .bus = &memory, .a = 0x42, .p = 0xff };
    @memcpy(memory.data[0..3], &[_]u8{ 0x8D, 0x34, 0x12 });

    try std.testing.expectEqual(@as(u8, 4), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x42), memory.data[0x1234]);
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqual(@as(u8, 0xff), cpu.p);
    try std.testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "INX updates sign and zero flags and wraps at 255" {
    var memory: Memory = .{};
    var cpu: CPU = .{ .bus = &memory, .x = 0x7f, .p = 0x7f };
    @memcpy(memory.data[0..2], &[_]u8{ 0xE8, 0xE8 });

    try std.testing.expectEqual(@as(u8, 2), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x80), cpu.x);
    try std.testing.expectEqual(@as(u8, 0xfd), cpu.p);

    cpu.x = 0xff;
    try std.testing.expectEqual(@as(u8, 2), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0), cpu.x);
    try std.testing.expectEqual(@as(u8, 0x7f), cpu.p);
}

test "instruction fetch wraps PC across the end of memory" {
    var memory: Memory = .{};
    var cpu: CPU = .{ .bus = &memory, .pc = 0xffff };
    memory.data[0xffff] = 0xA9;
    memory.data[0x0000] = 0x42;

    try std.testing.expectEqual(@as(u8, 2), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqual(@as(u16, 1), cpu.pc);

    cpu.pc = 0xfffe;
    memory.data[0xfffe] = 0xAD;
    memory.data[0xffff] = 0x34;
    memory.data[0x0000] = 0x12;
    memory.data[0x1234] = 0x81;

    try std.testing.expectEqual(@as(u8, 4), try cpu.step());
    try std.testing.expectEqual(@as(u8, 0x81), cpu.a);
    try std.testing.expectEqual(@as(u16, 1), cpu.pc);
}

test "NOP only advances PC and unsupported opcodes report an error" {
    var memory: Memory = .{};
    var cpu: CPU = .{
        .bus = &memory,
        .a = 0x12,
        .x = 0x34,
        .y = 0x56,
        .sp = 0xab,
        .p = 0xcd,
    };
    memory.data[0] = 0xEA;
    memory.data[1] = 0x02;
    const before = cpu;

    try std.testing.expectEqual(@as(u8, 2), try cpu.step());
    var expected = before;
    expected.pc = 1;
    try std.testing.expectEqualDeep(expected, cpu);

    try std.testing.expectError(error.UnsupportedOpcode, cpu.step());
    expected.pc = 2;
    try std.testing.expectEqualDeep(expected, cpu);
}
