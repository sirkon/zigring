const std = @import("std");
const c = std.c; // Пакет для связи с C/Posix

// Импортируем сишные функции напрямую из libc руками
extern "c" fn pthread_mutex_init(mutex: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_destroy(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_lock(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(mutex: *c.pthread_mutex_t) c_int;

pub const Mutex = struct {
    raw: c.pthread_mutex_t,

    pub fn init() Mutex {
        var self = Mutex{
            // Корректно зануляем память под структуру Си
            .raw = std.mem.zeroes(c.pthread_mutex_t),
        };
        // Инициализируем мьютекс с дефолтными атрибутами (null)
        _ = pthread_mutex_init(&self.raw, null);
        return self;
    }

    pub fn deinit(self: *Mutex) void {
        _ = pthread_mutex_destroy(&self.raw);
    }

    pub fn lock(self: *Mutex) void {
        // Обычная блокировка: если занято, поток засыпает в ядре ОС
        _ = pthread_mutex_lock(&self.raw);
    }

    pub fn unlock(self: *Mutex) void {
        _ = pthread_mutex_unlock(&self.raw);
    }
};
