const std = @import("std");
const c = std.c; // Все типы Си теперь тут

pub const PthreadMutex = struct {
    raw: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),

    pub fn init() PthreadMutex {
        var self = PthreadMutex{};
        _ = c.pthread_mutex_init(&self.raw, null);
        return self;
    }

    pub fn deinit(self: *PthreadMutex) void {
        _ = c.pthread_mutex_destroy(&self.raw);
    }

    pub fn lock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_lock(&self.raw);
    }

    pub fn unlock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_unlock(&self.raw);
    }
};
