const std = @import("std");

pub fn Slots(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Element = struct {
            value: T,
            exists: bool,
        };

        allocator: std.mem.Allocator,
        cap: u64,
        slots: []Element,
        free: []i32,
        firstFree: i32,

        // Быстрая побитовая магия вместо деления в рантайме:
        capShift: u6, // Хранит log2(fallback_cap) для сдвига >>
        capMask: u64, // Хранит (fallback_cap - 1) для маски &

        children: ?[]?*Self, // Массив из N дочерних слоттеров

        /// Инициализация оригинального слоттера
        pub fn init(allocator: std.mem.Allocator, capacity: u64, child_count: usize) !Self {
            // Проверки на степени двойки
            if (capacity == 0 or (capacity & (capacity - 1)) != 0) return error.CapacityMustBePowerOfTwo;

            // Проверки твоих ограничений на размеры
            if (capacity < 4096) return error.CapacityTooSmall;

            const slots = try allocator.alloc(Element, capacity);
            errdefer allocator.free(slots);

            const free = try allocator.alloc(i32, capacity);
            errdefer allocator.free(free);

            // Инициализируем список свободных элементов
            for (0..capacity - 1) |i| {
                free[i] = @intCast(i + 1);
            }
            free[capacity - 1] = -1;

            @memset(slots, .{ .value = undefined, .exists = false });

            var children: ?[]?*Self = null;
            if (child_count > 0) {
                children = try allocator.alloc(?*Self, child_count);
                @memset(children.?, null);
            }

            return Self{
                .allocator = allocator,
                .cap = capacity,
                .slots = slots,
                .free = free,
                .firstFree = 0,
                // Считаем параметры для битовой магии за 1 такт:
                .capShift = @intCast(@ctz(capacity)),
                .capMask = capacity - 1,
                .children = children,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.children) |children_slice| {
                for (children_slice) |maybe_child| {
                    if (maybe_child) |child| {
                        child.deinit();
                        self.allocator.destroy(child);
                    }
                }
                self.allocator.free(children_slice);
            }
            self.allocator.free(self.free);
            self.allocator.free(self.slots);
        }

        pub fn add(self: *Self, v: T) !u64 {
            // Быстрый путь: берем из оригинального слоттера
            if (self.firstFree >= 0) {
                const free_idx = @as(usize, @intCast(self.firstFree));
                self.firstFree = self.free[free_idx];

                self.slots[free_idx] = .{
                    .value = v,
                    .exists = true,
                };
                return @intCast(free_idx);
            }

            // Места нет — идем по дочерним
            if (self.children) |children_slice| {
                for (children_slice, 0..) |maybe_child, i| {
                    if (maybe_child == null) {
                        const child_ptr = try self.allocator.create(Self);
                        errdefer self.allocator.destroy(child_ptr);

                        // У дочерних слоттеров размер равен fallback_cap, и дочерних у них больше нет (0)
                        child_ptr.* = try Self.init(self.allocator, self.slots.len, 0);
                        children_slice[i] = child_ptr;
                    }

                    const child = children_slice[i].?;
                    if (child.add(v)) |childLocalIdx| {
                        // Масштабируем глобальный индекс
                        return self.cap + (i * self.slots.len) + childLocalIdx;
                    } else |err| {
                        if (err == error.NoFreeSlots) continue;
                        return err;
                    }
                }
            }

            return error.NoFreeSlots;
        }

        pub fn get(self: Self, idx: u64) ?T {
            if (idx < self.cap) {
                const slot = self.slots[idx];
                if (slot.exists) return slot.value;
                return null;
            }

            if (self.children) |childrenSlice| {
                const offset = idx - self.cap;

                // Вот она, магия без тяжелого деления:
                const childI = offset >> self.capShift; // Сдвиг вместо '/'
                const childrenLocalIdx = offset & self.capMask; // Маска вместо '%'

                if (childI < childrenSlice.len) {
                    if (childrenSlice[childI]) |child| {
                        return child.get(childrenLocalIdx);
                    }
                }
            }
            return null;
        }

        pub fn del(self: *Self, idx: u64) void {
            if (idx < self.cap) {
                self.slots[idx] = .{ .value = undefined, .exists = false };
                self.free[idx] = self.firstFree;
                self.firstFree = @intCast(idx);
                return;
            }

            if (self.children) |childrenSlice| {
                const offset = idx - self.cap;

                // И тут тоже летает за 1 такт:
                const childI = offset >> self.capShift;
                const childLocalIdx = offset & self.capMask;

                if (childI < childrenSlice.len) {
                    if (childrenSlice[childI]) |child| {
                        child.del(childLocalIdx);
                    }
                }
            }
        }
    };
}

pub const BufferSlots = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    elementSize: u64,
    cap: u64,

    buf: []u8,
    exists: []bool,
    free: []i32,
    firstFree: i32,

    capShift: u6,
    capMask: u64,

    children: ?[]?*Self,

    /// Инициализация буферного слоттера
    pub fn init(
        allocator: std.mem.Allocator,
        capacity: u64,
        elementSize: u64,
        childCount: usize,
    ) !Self {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) return error.CapacityMustBePowerOfTwo;

        if (capacity < 4096) return error.CapacityTooSmall;
        if (elementSize == 0) return error.ElementSizeCannotBeZero;

        const buf = try allocator.alloc(u8, capacity * elementSize);
        errdefer allocator.free(buf);

        const exists = try allocator.alloc(bool, capacity);
        errdefer allocator.free(exists);
        @memset(exists, false);

        const free = try allocator.alloc(i32, capacity);
        errdefer allocator.free(free);

        for (0..capacity - 1) |i| {
            free[i] = @intCast(i + 1);
        }
        free[capacity - 1] = -1;

        var children: ?[]?*Self = null;
        if (childCount > 0) {
            children = try allocator.alloc(?*Self, childCount);
            @memset(children.?, null);
        }

        return Self{
            .allocator = allocator,
            .elementSize = elementSize,
            .cap = capacity,
            .buf = buf,
            .exists = exists,
            .free = free,
            .firstFree = 0,
            .capShift = @intCast(@ctz(capacity)),
            .capMask = capacity - 1,
            .children = children,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.children) |childrenSlice| {
            for (childrenSlice) |maybeChild| {
                if (maybeChild) |child| {
                    child.deinit();
                    self.allocator.destroy(child);
                }
            }
            self.allocator.free(childrenSlice);
        }
        self.allocator.free(self.free);
        self.allocator.free(self.exists);
        self.allocator.free(self.buf);
    }

    // Тип результата возвращаем в PascalCase, как просит Zig-стайл
    pub const AddResult = struct { idx: u64, slice: []u8 };

    /// Добавление элемента через аллокацию индекса без копирования (Zero-Copy).
    pub fn addSlot(self: *Self) !AddResult {
        if (self.firstFree >= 0) {
            const freeIdx = @as(usize, @intCast(self.firstFree));
            self.firstFree = self.free[freeIdx];

            const start = freeIdx * self.elementSize;
            const end = start + self.elementSize;

            self.exists[freeIdx] = true;

            return AddResult{
                .idx = @intCast(freeIdx),
                .slice = self.buf[start..end],
            };
        }

        if (self.children) |childrenSlice| {
            for (childrenSlice, 0..) |maybeChild, i| {
                if (maybeChild == null) {
                    const childPtr = try self.allocator.create(Self);
                    errdefer self.allocator.destroy(childPtr);

                    childPtr.* = try Self.init(self.allocator, self.cap, self.elementSize, 0);
                    childrenSlice[i] = childPtr;
                }

                const child = childrenSlice[i].?;
                if (child.addSlot()) |res| {
                    return AddResult{
                        .idx = self.cap + (i * self.cap) + res.idx,
                        .slice = res.slice,
                    };
                } else |err| {
                    if (err == error.NoFreeSlots) continue;
                    return err;
                }
            }
        }

        return error.NoFreeSlots;
    }

    /// Добавление элемента путем копирования готового слайса байт
    pub fn alloc(self: *Self) !u64 {
        const res = try self.addSlot();
        return res.idx;
    }

    /// Получение слайса байт по глобальному индексу
    pub fn get(self: Self, idx: u64) ?[]u8 {
        if (idx < self.cap) {
            if (!self.exists[idx]) return null;
            const start = idx * self.elementSize;
            const end = start + self.elementSize;
            return self.buf[start..end];
        }

        if (self.children) |childrenSlice| {
            const offset = idx - self.cap;
            const childI = offset >> self.capShift;
            const childLocalIdx = offset & self.capMask;

            if (childI < childrenSlice.len) {
                if (childrenSlice[childI]) |child| {
                    return child.get(childLocalIdx);
                }
            }
        }
        return null;
    }

    /// Удаление элемента
    pub fn del(self: *Self, idx: u64) void {
        if (idx < self.cap) {
            if (!self.exists[idx]) return;

            self.exists[idx] = false;
            self.free[idx] = self.firstFree;
            self.firstFree = @intCast(idx);
            return;
        }

        if (self.children) |childrenSlice| {
            const offset = idx - self.cap;
            const childI = offset >> self.capShift;
            const childLocalIdx = offset & self.capMask;

            if (childI < childrenSlice.len) {
                if (childrenSlice[childI]) |child| {
                    child.del(childLocalIdx);
                }
            }
        }
    }
};

test "test slots" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var slots = try Slots(u64).init(arena.allocator(), 4096, 1);

    var idx = try slots.add(100);
    const firstIdx = idx;
    try testing.expectEqual(100, try must(slots.get(idx)));

    idx = try slots.add(200);
    try testing.expectEqual(200, try must(slots.get(idx)));
    slots.del(idx);
    try testing.expectEqual(null, slots.get(idx));

    for (0..(4096 * 2 - 1)) |i| {
        idx = try slots.add(i + 500);
        try testing.expectEqual(i + 500, try must(slots.get(idx)));
    }

    try testing.expectError(error.NoFreeSlots, slots.add(100_000_000));

    slots.del(idx);
    try testing.expectEqual(idx, try slots.add(123));
    try testing.expectEqual(123, try must(slots.get(idx)));

    slots.del(firstIdx);
    try testing.expectEqual(firstIdx, try slots.add(321));
    try testing.expectEqual(321, try must(slots.get(firstIdx)));
}

fn must(v: ?u64) !u64 {
    return v orelse return error.MustNotBeOption;
}
