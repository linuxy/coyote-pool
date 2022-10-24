const std = @import("std");
const c = std.c;

var threads_keepalive: u32 = undefined;
var threads_on_hold: u32 = undefined;

pub var allocator = std.heap.c_allocator;

pub const pthread_t = c_ulong;

pub const pthread_mutex_t = extern struct {
    size: [__SIZEOF_PTHREAD_MUTEX_T]u8 align(@alignOf(usize)) = [_]u8{0} ** __SIZEOF_PTHREAD_MUTEX_T,
};

pub const pthread_cond_t = extern struct {
    size: [__SIZEOF_PTHREAD_COND_T]u8 align(@alignOf(usize)) = [_]u8{0} ** __SIZEOF_PTHREAD_COND_T,
};

pub const pthread_rwlock_t = extern struct {
    size: [56]u8 align(@alignOf(usize)) = [_]u8{0} ** 56,
};

pub const pthread_condattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};

pub const pthread_mutexattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};

pub const union_pthread_attr_t = extern union {
    __size: [56]u8,
    __align: c_long,
};
pub const pthread_attr_t = union_pthread_attr_t;

pub extern fn pthread_mutex_init(__mutex: [*c]pthread_mutex_t, __mutexattr: [*c]const pthread_mutexattr_t) c_int;
pub extern fn pthread_cond_init(noalias __cond: [*c]pthread_cond_t, noalias __cond_attr: [*c]const pthread_condattr_t) c_int;
pub extern fn pthread_mutex_lock(__mutex: [*c]pthread_mutex_t) c_int;
pub extern fn pthread_mutex_unlock(__mutex: [*c]pthread_mutex_t) c_int;
pub extern fn pthread_kill(__threadid: pthread_t, __signo: c_int) c_int;
pub extern fn pthread_cond_wait(noalias __cond: [*c]pthread_cond_t, noalias __mutex: [*c]pthread_mutex_t) c_int;
pub extern fn pthread_cond_signal(__cond: [*c]pthread_cond_t) c_int;
pub extern fn pthread_cond_broadcast(__cond: [*c]pthread_cond_t) c_int;
pub extern fn pthread_create(noalias __newthread: [*c]pthread_t, noalias __attr: [*c]const pthread_attr_t, __start_routine: ?*const fn (?*anyopaque) callconv(.C) ?*anyopaque, noalias __arg: ?*anyopaque) c_int;
pub extern fn pthread_exit(__retval: ?*anyopaque) noreturn;
pub extern fn pthread_join(__th: pthread_t, __thread_return: [*c]?*anyopaque) c_int;
pub extern fn pthread_detach(__th: pthread_t) c_int;

const __SIZEOF_PTHREAD_COND_T = 48;
const __SIZEOF_PTHREAD_MUTEX_T = 40;

var sigact = std.os.Sigaction{
    .handler = .{.sigaction = thread_hold },
    .mask = std.os.empty_sigset,
    .flags = 0,
};

pub const Semaphore = struct {
    mutex: pthread_mutex_t,
    cond: pthread_cond_t,
    v: u32,

    pub fn init(self: *Semaphore, value: u32) void {
        if(value < 0 or value > 1) {
            std.log.warn("Semaphore.init(): Semaphore can only take values 1 or 0", .{});
            std.os.exit(1);
        }
        _ = pthread_mutex_init(&self.*.mutex, null);
        _ = pthread_cond_init(&self.*.cond, null);
        self.*.v = value;
    }

    pub fn reset(self: *Semaphore) void {
        self.init(0);
    }

    pub fn post(self: *Semaphore) void {
        _ = pthread_mutex_lock(&self.*.mutex);
        self.*.v = 1;
        _ = pthread_cond_signal(&self.*.cond);
        _ = pthread_mutex_unlock(&self.*.mutex);
    }

    pub fn post_all(self: *Semaphore) void {
        _ = pthread_mutex_lock(&self.*.mutex);
        self.*.v = 1;
        _ = pthread_cond_broadcast(&self.*.cond);
        _ = pthread_mutex_unlock(&self.*.mutex);
    }

    pub fn wait(self: *Semaphore) void {
        _ = pthread_mutex_lock(&self.*.mutex);
        while(self.*.v != 1)
            _ = pthread_cond_wait(&self.*.cond, &self.*.mutex);

        self.*.v = 0;
        _ = pthread_cond_signal(&self.*.cond);
        _ = pthread_mutex_unlock(&self.*.mutex);
    }
};

pub fn Job(comptime Func: anytype) type {
    return struct {
        prev: ?*Job(Func),
        arg: std.meta.ArgsTuple(@TypeOf(Func)) = undefined,
    };
}

pub fn JobQueue(comptime Func: anytype) type {
    return struct {
        const Self = @This();

        rwmutex: pthread_mutex_t,
        front: ?*Job(Func),
        rear: ?*Job(Func),
        has_jobs: *Semaphore,
        len: ?i32,

        pub fn init() *Self {
            var queue = allocator.create(Self) catch unreachable;
            queue.*.len.? = 0;
            queue.*.front = null;
            queue.*.rear = null;

            queue.*.has_jobs = allocator.create(Semaphore) catch unreachable;
            _ = pthread_mutex_init(&queue.*.rwmutex, null);
            queue.*.has_jobs.init(0);

            return queue;
        }

        pub fn clear(self: *Self) void {
            while(self.*.len.? > 0)
                allocator.destroy(self.pull().?);

            self.*.front = null;
            self.*.rear = null;
            self.*.has_jobs.reset();
            self.*.len = 0;
        }

        pub fn push(self: *Self, newjob: ?*Job(Func)) void {
            _ = pthread_mutex_lock(&self.*.rwmutex);
            newjob.?.prev = null;

            switch(self.*.len.?) {
                0 => {
                    self.*.front = newjob;
                    self.*.rear = newjob;
                },
                else => {
                    self.*.rear.?.prev = newjob;
                    self.*.rear = newjob;
                }
            }
            self.*.len.? += 1;
            self.*.has_jobs.*.post();
            _ = pthread_mutex_unlock(&self.*.rwmutex);
        }

        pub fn pull(self: *Self) ?*Job(Func) {
            _ = pthread_mutex_lock(&self.*.rwmutex);
            var job = self.*.front;

            switch(self.*.len.?) {
                0 => {},
                1 => {
                    self.*.front = null;
                    self.*.rear = null;
                    self.*.len = 0;
                },
                else => {
                    self.*.front = job.?.prev;
                    self.*.len.? -= 1;
                    self.*.has_jobs.post();
                }
            }
            _ = pthread_mutex_unlock(&self.*.rwmutex);
            return job;
        }

        pub fn destroy(self: *Self) void {
            self.clear();
            allocator.destroy(self.*.has_jobs);
        }
    };
}

pub fn thread_hold(sig: i32, sig_info: *const std.os.siginfo_t, ctx_ptr: ?*const anyopaque) callconv(.C) void {
    _ = sig;
    _ = sig_info;
    _ = ctx_ptr;
    threads_on_hold = 1;
    while(threads_on_hold > 0)
        std.os.nanosleep(0, 1);
}

pub const Thread = struct {
    id: u32,
    pool: *Pool,
    pthread: pthread_t,

    pub fn init(self: *Thread, pool: *Pool, id: u32) *Thread {
        self.pool = pool;
        self.id = id;

        //std.log.info("Creating thread ID: {}", .{self.id});
        _ = pthread_create(&self.pthread, null, do, self);
        _ = pthread_detach(self.pthread);
        return self;
    }

    pub fn destroy(self: *Thread) void {
        allocator.destroy(self);
    }
};

pub fn do(arg: ?*anyopaque) callconv(.C) ?*anyopaque {
    var self = @ptrCast(*Thread, @alignCast(@alignOf(Thread), arg));
    
    std.log.info("Working on thread ID: {}", .{std.Thread.getCurrentId()});
    std.os.sigaction(std.os.SIG.USR1, &sigact, null) catch unreachable;

    //Mark as alive
    _ = pthread_mutex_lock(&self.*.pool.*.thread_count_lock);
    self.*.pool.*.num_threads_alive += 1;
    _ = pthread_mutex_unlock(&self.*.pool.*.thread_count_lock);

    while(threads_keepalive > 0) {
        self.*.pool.*.jobqueue.*.has_jobs.wait();

        if(threads_keepalive > 0) {

            //Mark as working
            _ = pthread_mutex_lock(&self.*.pool.*.thread_count_lock);
            self.*.pool.*.num_threads_working += 1;
            _ = pthread_mutex_unlock(&self.*.pool.*.thread_count_lock);

            var job = self.*.pool.*.jobqueue.pull();
            if(job != null) {
                @call(.{}, job.?.func, .{job.?.arg});
                allocator.destroy(job.?);
            }
            //Finish working
            _ = pthread_mutex_lock(&self.*.pool.*.thread_count_lock);
            self.*.pool.*.num_threads_working -= 1;
            if (self.*.pool.*.num_threads_working < 1) {
                _ = pthread_cond_signal(&self.*.pool.*.threads_idle);
            }
            _ = pthread_mutex_unlock(&self.*.pool.*.thread_count_lock);
        }
    }

    _ = pthread_mutex_lock(&self.*.pool.*.thread_count_lock);
    self.*.pool.*.num_threads_alive -= 1;
    _ = pthread_mutex_unlock(&self.*.pool.*.thread_count_lock);

    return null;
}

pub const Pool = struct {
    threads: []Thread,
    num_threads_alive: u32,
    num_threads_working: u32,
    thread_count_lock: pthread_mutex_t, 
    threads_idle: pthread_cond_t,
    jobqueue: []*anyopaque,

    pub fn init(num_threads: u32) *Pool {
        threads_on_hold = 0;
        threads_keepalive = 1;

        if(num_threads < 0 )
            num_threads = 0;

        //Create new pool
        var pool = allocator.create(Pool) catch unreachable; 
        pool.*.num_threads_alive = 0;
        pool.*.num_threads_working = 0;

        //Create job queue
        //pool.*.jobqueue = JobQueue.init();

        //Create threads
        pool.*.threads = allocator.alloc(Thread, num_threads) catch unreachable;

        _ = pthread_mutex_init(&pool.*.thread_count_lock, null);
        _ = pthread_cond_init(&pool.*.threads_idle, null);

        var n: u32 = 0;
        while(n < num_threads) : (n += 1) {
            pool.*.threads[n] = pool.*.threads[n].init(pool, n).*;
        }
        
        while(pool.*.num_threads_alive != num_threads) {
            //
        }

        return pool;
    }

    pub fn add_work(self: *Pool, comptime func: anytype, arg: anytype) u32 {
        var newjob: *Job(func) = allocator.create(Job(func)) catch unreachable;

        newjob.*.func = func;
        newjob.*.arg = arg;

        self.jobqueue.push(newjob);

        return 0;
    }

    pub fn wait(self: *Pool) void {
        _ = pthread_mutex_lock(&self.thread_count_lock);
        while(self.*.jobqueue.len.? > 0 or self.*.num_threads_working > 0) {
            _ = pthread_cond_wait(&self.threads_idle, &self.thread_count_lock);
        }
        _ = pthread_mutex_unlock(&self.thread_count_lock);
    }

    pub fn deinit(self: *Pool) void {
        threads_keepalive = 0;

        var time_elapsed = std.time.milliTimestamp();
        const TIMEOUT = time_elapsed + 1000;

        while(time_elapsed < TIMEOUT and self.*.num_threads_alive > 0) {
            self.jobqueue.has_jobs.post_all();
            time_elapsed = std.time.milliTimestamp();
        }

        while(self.num_threads_alive > 0) {
            self.jobqueue.has_jobs.post_all();
            std.os.nanosleep(0, 1);
        }

        self.jobqueue.destroy();

        allocator.free(self.threads);
        allocator.destroy(self);
    }

    pub fn pause(self: *Pool) void {
        var n: u32 = 0;
        while(n < self.num_threads_alive) : (n += 1) {
            _ = pthread_kill(self.*.threads[n].pthread, std.os.SIG.INT);
        }
        std.os.nanosleep(0, 1);
    }

    pub fn _resume(self: *Pool) void {
        threads_on_hold = 0;
        _ = self;
    }

    pub fn num_threads_working(self: *Pool) u32 {
        return self.*.num_threads_working;
    }
};