const std = @import("std");
const c = std.c;

// Импортируем сишные функции напрямую из libc руками
extern "c" fn pthread_mutex_init(mutex: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_destroy(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_lock(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(mutex: *c.pthread_mutex_t) c_int;

extern "c" fn pthread_cond_init(cond: *c.pthread_cond_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_cond_destroy(cond: *c.pthread_cond_t) c_int;
extern "c" fn pthread_cond_wait(cond: *c.pthread_cond_t, mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_cond_signal(cond: *c.pthread_cond_t) c_int;
extern "c" fn pthread_cond_broadcast(cond: *c.pthread_cond_t) c_int;

// Тип для маски ядер. На Linux это структура, но по размеру она занимает 128 байт (хватит на 1024 ядра)
const cpu_set_t = extern struct {
    __bits: [128 / @sizeOf(c_ulong)]c_ulong,
};

extern "c" fn pthread_create(thread: *c.pthread_t, attr: ?*const anyopaque, start_routine: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
extern "c" fn pthread_join(thread: c.pthread_t, retval: ?*?*anyopaque) c_int;
extern "c" fn pthread_setaffinity_np(thread: c.pthread_t, cpusetsize: usize, cpuset: *const cpu_set_t) c_int;
extern "c" fn pthread_self() c.pthread_t;

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

pub const CondVar = struct {
    raw: c.pthread_cond_t,

    pub fn init() CondVar {
        var self = CondVar{
            .raw = std.mem.zeroes(c.pthread_cond_t),
        };
        _ = pthread_cond_init(&self.raw, null);
        return self;
    }

    pub fn deinit(self: *CondVar) void {
        _ = pthread_cond_destroy(&self.raw);
    }

    // Передаем твою обертку Mutex. Внутри атомарно отпускаем Си-мьютекс и ждем
    pub fn wait(self: *CondVar, mutex: *Mutex) void {
        _ = pthread_cond_wait(&self.raw, &mutex.raw);
    }

    // Пробуждает один поток
    pub fn signal(self: *CondVar) void {
        _ = pthread_cond_signal(&self.raw);
    }

    // Пробуждает все потоки, которые ждут на этом кондваре
    pub fn broadcast(self: *CondVar) void {
        _ = pthread_cond_broadcast(&self.raw);
    }
};

pub const Thread = struct {
    raw: c.pthread_t,

    // spawn принимает Zig-функцию и указатель на любые данные
    pub fn spawn(context: anytype, comptime f: anytype) !Thread {
        const ContextType = @TypeOf(context);

        const wrapper = struct {
            fn run(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
                if (ContextType == void or ContextType == @TypeOf(null)) {
                    f();
                } else {
                    const ptr: ContextType = @ptrCast(@alignCast(arg));
                    f(ptr);
                }
                return null;
            }
        }.run;

        // Создаем структуру с незаданным (мусорным) состоянием
        var self = Thread{
            .raw = undefined,
        };

        // Зануляем raw-память хэндла потока напрямую побайтово
        // Это обходит проверку типов Zig и работает на любой ОС/libc
        const bytes = @as([*]u8, @ptrCast(&self.raw))[0..@sizeOf(c.pthread_t)];
        @memset(bytes, 0);

        const raw_arg = if (ContextType == void or ContextType == @TypeOf(null)) null else @as(?*anyopaque, @ptrCast(context));

        const res = pthread_create(&self.raw, null, @ptrCast(&wrapper), raw_arg);
        if (res != 0) return error.ThreadSpawnFailed;

        return self;
    }

    pub fn join(self: Thread) void {
        _ = pthread_join(self.raw, null);
    }

    /// Привязывает текущий (этот) поток к конкретному ядру ЦП
    pub fn setAffinity(self: Thread, core_id: u32) !void {
        var cpuset: cpu_set_t = undefined;
        // Полностью очищаем маску ядер
        @memset(@as([*]u8, @ptrCast(&cpuset))[0..@sizeOf(cpu_set_t)], 0);

        // Устанавливаем бит нужного ядра (аналог макроса CPU_SET)
        const word_index = core_id / (@sizeOf(c_ulong) * 8);
        const bit_index = core_id % (@sizeOf(c_ulong) * 8);

        if (word_index >= cpuset.__bits.len) return error.CpuIdOutOfRange;
        cpuset.__bits[word_index] |= (@as(c_ulong, 1) << @intCast(bit_index));

        const res = pthread_setaffinity_np(self.raw, @sizeOf(cpu_set_t), &cpuset);
        if (res != 0) return error.SetCpuAffinityFailed;
    }

    /// Позволяет вызывающему потоку жестко привязать самого себя к ядру
    pub fn setSelfAffinity(core_id: u32) !void {
        const self_thread = Thread{ .raw = pthread_self() };
        try self_thread.setAffinity(core_id);
    }
};

test "pthread wrappers: mutex, condvar, and thread workflow" {
    // Структура для общего состояния между потоками
    const SharedState = struct {
        mutex: Mutex,
        cond: CondVar,
        ready: bool,
        counter: i32,
    };

    // Инициализируем наше состояние
    var state = SharedState{
        .mutex = Mutex.init(),
        .cond = CondVar.init(),
        .ready = false,
        .counter = 0,
    };
    defer state.mutex.deinit();
    defer state.cond.deinit();

    // Локальная функция для фонового потока
    const worker = struct {
        fn run(s: *SharedState) void {
            s.mutex.lock();
            defer s.mutex.unlock();

            // Ждем, пока главный поток не переведет ready в true
            while (!s.ready) {
                s.cond.wait(&s.mutex);
            }

            // Меняем данные под защитой мьютекса
            s.counter += 42;
        }
    }.run;

    // 1. Запускаем поток
    const thread = try Thread.spawn(&state, worker);

    // Даем фоновому потоку время запуститься и уйти в ожидание cond.wait()
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .awake);

    // Проверяем, что счетчик все еще 0 (поток ждет)
    try std.testing.expectEqual(@as(i32, 0), state.counter);

    // 2. Захватываем мьютекс и меняем состояние ready
    state.mutex.lock();
    state.ready = true;
    state.mutex.unlock();

    // Отправляем сигнал, чтобы разбудить поток
    state.cond.signal();

    // 3. Ждем завершения потока
    thread.join();

    // Проверяем, что фоновый поток успешно проснулся и изменил счетчик
    try std.testing.expectEqual(@as(i32, 42), state.counter);
}
