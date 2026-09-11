const std = @import("std");

/// Creates an index allocator for values of type `T`.
///
/// Indices are dense `u64` values: `add` returns one and `del` hands it back to
/// the free pool for reuse. A root table of `capacity` slots is allocated up
/// front, and up to `child_count` child tables of the same size are created
/// lazily once the root is full, so the allocator can hand out
/// `capacity * (1 + child_count)` values in total.
///
/// `capacity` must be a power of two and at least 4096 (see
/// `error.CapacityMustBePowerOfTwo` and `error.CapacityTooSmall`). Values are
/// stored by copy and no destructor is ever run, so `T` must be trivially
/// copyable and must not own resources.
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

        // Fast bit magic instead of runtime division:
        capShift: u6, // Stores log2(fallback_cap) for the >> shift
        capMask: u64, // Stores (fallback_cap - 1) for the & mask

        children: ?[]?*Self, // Array of N child slotters

        /// Allocates `capacity` slots and the free list, plus `child_count`
        /// child pointers that stay null until `add` needs them.
        ///
        /// `capacity` must be a power of two of at least 4096, and
        /// `child_count` may be zero for a table that never grows. The allocator
        /// must outlive the slotter, since `deinit` frees through it.
        pub fn init(allocator: std.mem.Allocator, capacity: u64, child_count: usize) !Self {
            // Checks for powers of two
            if (capacity == 0 or (capacity & (capacity - 1)) != 0) return error.CapacityMustBePowerOfTwo;

            // Checks for your size constraints
            if (capacity < 4096) return error.CapacityTooSmall;

            const slots = try allocator.alloc(Element, capacity);
            errdefer allocator.free(slots);

            const free = try allocator.alloc(i32, capacity);
            errdefer allocator.free(free);

            // Initialize the free list
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
                // Compute the parameters for the bit magic in 1 cycle:
                .capShift = @intCast(@ctz(capacity)),
                .capMask = capacity - 1,
                .children = children,
            };
        }

        /// Releases the root table, the free list and recursively destroys
        /// every child slotter created by `add`.
        ///
        /// Uses the allocator captured at `init`. Afterwards the slotter is
        /// invalid and must not be used again.
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

        /// Stores `v` by copying it into a free slot and returns that slot's
        /// index.
        ///
        /// The index is stable until it is passed to `del`. When the root table
        /// is full this transparently creates (or reuses) a child table, so it
        /// keeps growing up to `capacity * (1 + child_count)`. Returns
        /// `error.NoFreeSlots` once every table is full; allocation failures
        /// from creating a child propagate out as well.
        pub fn add(self: *Self, v: T) !u64 {
            // Fast path: take from the original slotter
            if (self.firstFree >= 0) {
                const free_idx = @as(usize, @intCast(self.firstFree));
                self.firstFree = self.free[free_idx];

                self.slots[free_idx] = .{
                    .value = v,
                    .exists = true,
                };
                return @intCast(free_idx);
            }

            // No room left, so walk the children
            if (self.children) |children_slice| {
                for (children_slice, 0..) |maybe_child, i| {
                    if (maybe_child == null) {
                        const child_ptr = try self.allocator.create(Self);
                        errdefer self.allocator.destroy(child_ptr);

                        // Child slotters have size equal to fallback_cap and no children of their own (0)
                        child_ptr.* = try Self.init(self.allocator, self.slots.len, 0);
                        children_slice[i] = child_ptr;
                    }

                    const child = children_slice[i].?;
                    if (child.add(v)) |childLocalIdx| {
                        // Scale to a global index
                        return self.cap + (i * self.slots.len) + childLocalIdx;
                    } else |err| {
                        if (err == error.NoFreeSlots) continue;
                        return err;
                    }
                }
            }

            return error.NoFreeSlots;
        }

        /// Returns a copy of the value stored at `idx`, or null if the index is
        /// out of range or not currently allocated (never added or already
        /// deleted).
        ///
        /// Runs in constant time: a shift and mask pick the table, with no
        /// division or modulo.
        pub fn get(self: Self, idx: u64) ?T {
            if (idx < self.cap) {
                const slot = self.slots[idx];
                if (slot.exists) return slot.value;
                return null;
            }

            if (self.children) |childrenSlice| {
                const offset = idx - self.cap;

                // Here it is, the magic without heavy division:
                const childI = offset >> self.capShift; // Shift instead of '/'
                const childrenLocalIdx = offset & self.capMask; // Mask instead of '%'

                if (childI < childrenSlice.len) {
                    if (childrenSlice[childI]) |child| {
                        return child.get(childrenLocalIdx);
                    }
                }
            }
            return null;
        }

        /// Frees the slot at `idx` so a later `add` can reuse it.
        ///
        /// Out-of-range or already-free indices are silently ignored. No
        /// destructor runs, since `T` is treated as plain data. The recycled
        /// index may be handed out again by the very next `add`.
        pub fn del(self: *Self, idx: u64) void {
            if (idx < self.cap) {
                self.slots[idx] = .{ .value = undefined, .exists = false };
                self.free[idx] = self.firstFree;
                self.firstFree = @intCast(idx);
                return;
            }

            if (self.children) |childrenSlice| {
                const offset = idx - self.cap;

                // And here it also flies in 1 cycle:
                const childI = offset >> self.capShift;
                const childLocalIdx = offset & self.capMask;

                if (childI < childrenSlice.len) {
                    if (childrenSlice[childI]) |child| {
                        child.del(childLocalIdx);
                    }
                }
            }
        }

        /// Returns true when no slot in this table is currently allocated.
        ///
        /// Child tables are never consulted: a child has no children of its
        /// own, so the root slot array is the whole story.
        fn isEmpty(self: Self) bool {
            for (self.slots) |slot| {
                if (slot.exists) return false;
            }
            return true;
        }

        /// Releases trailing child tables that hold no live values.
        ///
        /// Only the trailing run of unused children is dropped: the root table
        /// and every child at or below the last child that still holds a value
        /// are left alone, including unused children that appear before it. A
        /// child is unused when every one of its slots has been deleted.
        /// Dropped tables are recreated lazily by `add` if they are needed
        /// again, reusing the same global indices.
        pub fn dropUnused(self: *Self) void {
            const childrenSlice = self.children orelse return;

            // Walk backwards to the last child that still holds a value.
            var keep: usize = childrenSlice.len;
            while (keep > 0) {
                if (childrenSlice[keep - 1]) |child| {
                    if (!child.isEmpty()) break;
                }
                keep -= 1;
            }

            var i = keep;
            while (i < childrenSlice.len) : (i += 1) {
                if (childrenSlice[i]) |child| {
                    child.deinit();
                    self.allocator.destroy(child);
                    childrenSlice[i] = null;
                }
            }
        }
    };
}

/// An index allocator whose slots are fixed-size byte buffers.
///
/// Like `Slots(T)` it hands out dense `u64` indices, but each index maps to an
/// `elementSize`-byte slice of one large backing allocation. A root table of
/// `capacity` buffers is allocated up front, and up to `childCount` child
/// tables are grown lazily, giving `capacity * (1 + childCount)` slots in
/// total.
///
/// `capacity` must be a power of two and at least 4096, and `elementSize` must
/// be non-zero. Buffers are never zeroed when a slot is reused.
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

    /// Allocates `capacity * elementSize` bytes of backing storage plus the
    /// bookkeeping arrays, and `childCount` lazily-filled child pointers.
    ///
    /// `capacity` must be a power of two of at least 4096, and `elementSize`
    /// must be non-zero (see the corresponding errors). The backing allocation
    /// is owned by the returned value and freed by `deinit`; the allocator must
    /// outlive the slotter.
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

    /// Releases the backing storage, the bookkeeping arrays and every child
    /// table created by `addSlot`/`alloc`.
    ///
    /// Uses the allocator captured at `init`. Every slice previously returned
    /// by `addSlot` or `get` becomes dangling.
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

    /// Result of `addSlot`: the global index of the reserved slot and a
    /// borrowed, uninitialized slice of `elementSize` bytes to write into.
    pub const AddResult = struct { idx: u64, slice: []u8 };

    /// Reserves a free slot and returns its index together with a borrowed
    /// slice into the backing memory, without copying anything into it.
    ///
    /// The caller writes directly into the returned slice (zero-copy). That
    /// slice aliases the slotter's backing allocation: it must not be freed and
    /// stays valid only until `del(idx)` or `deinit`. Grows into a new child
    /// table when the root is full, and returns `error.NoFreeSlots` when every
    /// table is full.
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

    /// Convenience wrapper around `addSlot` that reserves a slot and returns
    /// only its index, when the in-place slice is not needed right away.
    ///
    /// The slot's bytes are left untouched; fetch them later with `get`.
    /// Returns `error.NoFreeSlots` when full.
    pub fn alloc(self: *Self) !u64 {
        const res = try self.addSlot();
        return res.idx;
    }

    /// Returns the borrowed `elementSize`-byte slice stored at `idx`, or null
    /// if the index is out of range or not currently allocated.
    ///
    /// The slice aliases the slotter's backing memory: mutate it freely, but do
    /// not free it, and treat it as invalid once the slot is deleted or the
    /// slotter deinitialized.
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

    /// Frees the slot at `idx`, making its bytes available for a later
    /// `addSlot` or `alloc`.
    ///
    /// Out-of-range or already-free indices are silently ignored. The previous
    /// contents are not cleared, so a reused slot still holds the old data
    /// until overwritten. Any slice previously obtained for this slot is
    /// invalidated and must not be used afterwards.
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

    /// Returns true when no slot in this table is currently allocated.
    ///
    /// Child tables are never consulted: a child has no children of its own,
    /// so the root `exists` array is the whole story.
    fn isEmpty(self: Self) bool {
        for (self.exists) |exists| {
            if (exists) return false;
        }
        return true;
    }

    /// Releases trailing child tables that hold no live values.
    ///
    /// Only the trailing run of unused children is dropped: the root table and
    /// every child at or below the last child that still holds a value are left
    /// alone, including unused children that appear before it. A child is
    /// unused when every one of its slots has been deleted. Dropped tables are
    /// recreated lazily by `addSlot`/`alloc` if they are needed again, reusing
    /// the same global indices.
    pub fn dropUnused(self: *Self) void {
        const childrenSlice = self.children orelse return;

        // Walk backwards to the last child that still holds a value.
        var keep: usize = childrenSlice.len;
        while (keep > 0) {
            if (childrenSlice[keep - 1]) |child| {
                if (!child.isEmpty()) break;
            }
            keep -= 1;
        }

        var i = keep;
        while (i < childrenSlice.len) : (i += 1) {
            if (childrenSlice[i]) |child| {
                child.deinit();
                self.allocator.destroy(child);
                childrenSlice[i] = null;
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

test "test slots dropUnused" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var slots = try Slots(u64).init(arena.allocator(), 4096, 3);

    // Fill the root and the first two children: 0..4095, 4096..8191 and
    // 8192..12287, all with matching values.
    for (0..4096 * 3) |i| {
        const idx = try slots.add(i);
        try testing.expectEqual(@as(u64, i), idx);
    }

    // A live value in the third child.
    const live = try slots.add(999);
    try testing.expectEqual(@as(u64, 12288), live);

    // Empty out the first child. It is unused but sits below a live child, so
    // later trims must leave it in place.
    for (4096..8192) |idx| {
        slots.del(idx);
    }

    slots.dropUnused();
    try testing.expect(slots.children.?[0] != null);
    try testing.expect(slots.children.?[1] != null);
    try testing.expect(slots.children.?[2] != null);

    // The third child is now unused while the second still holds values: only
    // the trailing third child goes, the empty first child stays.
    slots.del(live);
    slots.dropUnused();
    try testing.expect(slots.children.?[0] != null);
    try testing.expect(slots.children.?[1] != null);
    try testing.expect(slots.children.?[2] == null);

    // With every child unused, they all go.
    for (8192..12288) |idx| {
        slots.del(idx);
    }
    slots.dropUnused();
    try testing.expect(slots.children.?[0] == null);
    try testing.expect(slots.children.?[1] == null);
    try testing.expect(slots.children.?[2] == null);

    // The allocator still works and reuses the first child.
    const reused = try slots.add(7);
    try testing.expectEqual(@as(u64, 4096), reused);
    try testing.expectEqual(7, try must(slots.get(reused)));
}

test "test buffer slots dropUnused" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var slots = try BufferSlots.init(arena.allocator(), 4096, 16, 3);

    // Fill the root and the first two children with 16-byte buffers.
    for (0..4096 * 3) |i| {
        const idx = try slots.alloc();
        try testing.expectEqual(@as(u64, i), idx);
    }

    const live = try slots.alloc();
    try testing.expectEqual(@as(u64, 12288), live);

    for (4096..8192) |idx| {
        slots.del(idx);
    }

    slots.dropUnused();
    try testing.expect(slots.children.?[0] != null);
    try testing.expect(slots.children.?[1] != null);
    try testing.expect(slots.children.?[2] != null);

    slots.del(live);
    slots.dropUnused();
    try testing.expect(slots.children.?[0] != null);
    try testing.expect(slots.children.?[1] != null);
    try testing.expect(slots.children.?[2] == null);

    for (8192..12288) |idx| {
        slots.del(idx);
    }
    slots.dropUnused();
    try testing.expect(slots.children.?[0] == null);
    try testing.expect(slots.children.?[1] == null);
    try testing.expect(slots.children.?[2] == null);

    const reused = try slots.alloc();
    try testing.expectEqual(@as(u64, 4096), reused);
    try testing.expect(slots.get(reused) != null);
}

fn must(v: ?u64) !u64 {
    return v orelse return error.MustNotBeOption;
}
