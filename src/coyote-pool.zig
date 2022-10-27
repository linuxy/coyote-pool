const std = @import("std");
const c = std.c;
const assert = std.debug.assert;

var threads_keepalive: u32 = undefined;
var threads_on_hold: u32 = undefined;

pub var allocator = std.heap.c_allocator;

pub const Semaphore = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    v: u32,

    pub fn init(self: *Semaphore, value: u32) void {
        if(value < 0 or value > 1) {
            std.log.warn("Semaphore.init(): Semaphore can only take values 1 or 0", .{});
            std.os.exit(1);
        }
        
        self.mutex = std.Thread.Mutex{};
        self.cond = std.Thread.Condition{};
        self.v = value;
    }

    pub fn reset(self: *Semaphore) void {
        self.init(0);
    }

    pub fn post(self: *Semaphore) void {
        self.mutex.lock();
        self.v = 1;
        self.cond.signal();
        self.mutex.unlock();
    }

    pub fn post_all(self: *Semaphore) void {
        self.mutex.lock();
        self.v = 1;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn wait(self: *Semaphore) void {
        self.mutex.lock();
        while(self.v != 1)
            self.cond.wait(&self.mutex);

        self.v = 0;
        self.cond.signal();
        self.mutex.unlock();
    }
};

pub const Job = struct {
    prev: ?*Job,
    func: *const anyopaque,
    arg: *anyopaque,
};

pub const JobQueue = struct {
    rwmutex: std.Thread.Mutex,
    front: ?*Job,
    rear: ?*Job,
    has_jobs: *Semaphore,
    len: ?i32,

    pub fn init() *JobQueue {
        var queue = allocator.create(JobQueue) catch unreachable;
        queue.len = 0;
        queue.front = null;
        queue.rear = null;

        queue.has_jobs = allocator.create(Semaphore) catch unreachable;
        queue.rwmutex = std.Thread.Mutex{};
        queue.has_jobs.init(0);

        return queue;
    }

    pub fn clear(self: *JobQueue) void {
        while(self.len.? > 0)
            allocator.destroy(self.pull().?);

        self.front = null;
        self.rear = null;
        self.has_jobs.reset();
        self.len = 0;
    }

    pub fn push(self: *JobQueue, newjob: ?*Job) void {
        self.rwmutex.lock();
        newjob.?.prev = null;

        switch(self.len.?) {
            0 => {
                self.front = newjob;
                self.rear = newjob;
            },
            else => {
                self.rear.?.prev = newjob;
                self.rear = newjob;
            }
        }
        self.len.? += 1;
        self.has_jobs.post();
        self.rwmutex.unlock();
    }

    pub fn pull(self: *JobQueue) ?*Job {
        self.rwmutex.lock();
        var job = self.front;

        switch(self.len.?) {
            0 => {},
            1 => {
                self.front = null;
                self.rear = null;
                self.len = 0;
            },
            else => {
                self.front = job.?.prev;
                self.len.? -= 1;
                self.has_jobs.post();
            }
        }
        self.rwmutex.unlock();
        return job;
    }

    pub fn destroy(self: *JobQueue) void {
        self.clear();
        allocator.destroy(self.has_jobs);
    }
};

pub const Thread = struct {
    id: u32,
    pool: *Pool,
    pthread: std.Thread,

    pub fn init(self: *Thread, pool: *Pool, id: u32) *Thread {
        self.pool = pool;
        self.id = id;

        //std.log.info("Creating thread ID: {}", .{self.id});
        self.pthread = std.Thread.spawn(.{}, do, .{self}) catch unreachable;
        self.pthread.detach();
        return self;
    }

    pub fn destroy(self: *Thread) void {
        allocator.destroy(self);
    }
};

pub fn do(arg: ?*anyopaque) void {
    var self = @ptrCast(*Thread, @alignCast(@alignOf(Thread), arg));
    
    //std.log.info("Working on thread ID: {}", .{std.Thread.getCurrentId()});

    //Mark as alive
    self.pool.thread_count_lock.lock();
    self.pool.num_threads_alive += 1;
    self.pool.thread_count_lock.unlock();

    while(threads_keepalive > 0) {
        while(threads_on_hold > 0)
            std.time.sleep(0);
        
        self.pool.jobqueue.has_jobs.wait();

        if(threads_keepalive > 0) {

            //Mark as working
            self.pool.thread_count_lock.lock();
            self.pool.num_threads_working += 1;
            self.pool.thread_count_lock.unlock();

            var job = self.pool.jobqueue.pull();
            if(job != null) {
                callVarArgs(void, job.?.func, .{job.?.arg});
                allocator.destroy(job.?);
            }
            //Finish working
            self.pool.thread_count_lock.lock();
            self.pool.num_threads_working -= 1;
            if (self.pool.num_threads_working < 1) {
                self.pool.threads_idle.signal();
            }
            self.pool.thread_count_lock.unlock();
        }
    }

    self.pool.thread_count_lock.lock();
    self.pool.num_threads_alive -= 1;
    self.pool.thread_count_lock.unlock();
}

pub const Pool = struct {
    threads: []Thread,
    num_threads_alive: u32,
    num_threads_working: u32,
    thread_count_lock: std.Thread.Mutex, 
    threads_idle: std.Thread.Condition,
    jobqueue: *JobQueue,

    pub fn init(num_threads: u32) *Pool {
        threads_on_hold = 0;
        threads_keepalive = 1;

        if(num_threads < 0 )
            num_threads = 0;

        //Create new pool
        var pool = allocator.create(Pool) catch unreachable; 
        pool.num_threads_alive = 0;
        pool.num_threads_working = 0;

        //Create job queue
        pool.jobqueue = JobQueue.init();

        //Create threads
        pool.threads = allocator.alloc(Thread, num_threads) catch unreachable;

        pool.thread_count_lock = std.Thread.Mutex{};
        pool.threads_idle = std.Thread.Condition{};

        var n: u32 = 0;
        while(n < num_threads) : (n += 1) {
            pool.threads[n] = pool.threads[n].init(pool, n).*;
        }
        
        while(pool.num_threads_alive != num_threads) {
            //
        }

        return pool;
    }

    pub fn add_work(self: *Pool, func: anytype, arg: anytype) !void {
        var newjob: *Job = allocator.create(Job) catch unreachable;

        newjob.func = @ptrCast(*const anyopaque, &func);
        newjob.arg = arg;

        self.jobqueue.push(newjob);
    }

    pub fn wait(self: *Pool) void {
        self.thread_count_lock.lock();
        while(self.jobqueue.len.? > 0 or self.num_threads_working > 0) {
            self.threads_idle.wait(&self.thread_count_lock);
        }
        self.thread_count_lock.unlock();
    }

    pub fn deinit(self: *Pool) void {
        threads_keepalive = 0;

        var time_elapsed = std.time.milliTimestamp();
        const TIMEOUT = time_elapsed + 1000;

        while(time_elapsed < TIMEOUT and self.num_threads_alive > 0) {
            self.jobqueue.has_jobs.post_all();
            time_elapsed = std.time.milliTimestamp();
        }

        while(self.num_threads_alive > 0) {
            self.jobqueue.has_jobs.post_all();
            std.time.sleep(0);
        }

        self.jobqueue.destroy();

        allocator.free(self.threads);
        allocator.destroy(self);
    }

    pub fn pause(self: *Pool) void {
        threads_on_hold = 1;
        _ = self;
    }

    pub fn _resume(self: *Pool) void {
        threads_on_hold = 0;
        _ = self;
    }

    pub fn num_threads_working(self: *Pool) u32 {
        return self.num_threads_working;
    }
};

//varargs thanks to https://github.com/suirad/zig-varargs
const VA_Errors = error{
    CountUninitialized,
    NoMoreArgs,
};

pub inline fn callVarArgs(comptime T: type, func: *const anyopaque, args: anytype) T {
    // comptime: validate args
    comptime {
        if (@bitSizeOf(T) > @bitSizeOf(usize)) {
            @compileError("Return type is larger than usize: " ++ @typeName(T));
        }
        const args_info = @typeInfo(@TypeOf(args));
        if (args_info != .Struct or args_info.Struct.is_tuple == false) {
            @compileError("Expected args to be a tuple");
        }
    }

    // comptime: accounting
    // count number of fp and gp args so we can push them on the stack
    //      if needed and in reverse order
    // also do type checking
    comptime var gp_args = 0;
    comptime var fp_args = 0;

    comptime {
        var index = args.len;
        while (index > 0) : (index -= 1) {
            const arg_type = @TypeOf(args[index - 1]);
            const arg_info = @typeInfo(arg_type);
            switch (arg_info) {
                .Int, .ComptimeInt, .Optional, .Pointer => {
                    if (@bitSizeOf(arg_type) > @bitSizeOf(usize)) {
                        @compileError("Arg type is larger than usize: " ++ @typeName(arg_type));
                    } else if (arg_info == .Optional) {
                        const child = arg_info.Optional.child;
                        const child_info = @typeInfo(child);
                        if (child_info != .Pointer) {
                            @compileError("Optional args should only be pointers");
                        }
                    }

                    gp_args += 1;
                },

                .Float => fp_args += 1,

                else => @compileError("Unsupported arg type: " ++ @typeName(arg_type)),
            }
        }
    }

    const fp_total: usize = fp_args;
    comptime var stack_growth: usize = 0;
    comptime var index = args.len;

    // reverse loop of args so you can push later args onto the stack in order
    inline while (index > 0) : (index -= 1) {
        const varg = args[index - 1];
        const arg_info = @typeInfo(@TypeOf(varg));
        switch (arg_info) {
            .Int, .ComptimeInt, .Optional, .Pointer => {
                const arg: usize = if (arg_info == .Optional or arg_info == .Pointer)
                    @as(usize, @ptrToInt(varg))
                else
                    @as(usize, varg);

                pushInt(gp_args, arg);
                if (gp_args > 6)
                    stack_growth += @sizeOf(usize);
                gp_args -= 1;
            },

            .Float => {
                const arg = @floatCast(f64, varg);
                pushFloat(fp_args, arg);
                fp_args -= 1;
            },

            else => @compileError("Unsupported arg type: " ++ @typeName(varg)),
        }
    }

    // call fn
    asm volatile ("call *(%[func])"
        :
        : [func] "{r10}" (&func),
          [fp_total] "{rax}" (fp_total),
    );

    // realign stack
    if (stack_growth > 0) {
        asm volatile ("add %%r10, %%rsp"
            :
            : [stack_growth] "{r10}" (stack_growth),
        );
    }

    // handle return type
    if (T == void) {
        return;
    }

    const ret = asm volatile (""
        : [ret] "={rax}" (-> T),
    );

    return ret;
}

inline fn pushInt(comptime index: usize, arg: usize) void {
    switch (index) {
        1 => asm volatile (""
            :
            : [arg] "{rdi}" (arg),
        ),
        2 => asm volatile (""
            :
            : [arg] "{rsi}" (arg),
        ),
        3 => asm volatile (""
            :
            : [arg] "{rdx}" (arg),
        ),
        4 => asm volatile (""
            :
            : [arg] "{rcx}" (arg),
        ),
        5 => asm volatile (""
            :
            : [arg] "{r8}" (arg),
        ),
        6 => asm volatile (""
            :
            : [arg] "{r9}" (arg),
        ),
        else => {
            asm volatile ("push %%r10"
                :
                : [arg] "{r10}" (arg),
            );
        },
    }
}

inline fn pushFloat(comptime index: usize, arg: f64) void {
    switch (index) {
        1 => asm volatile (""
            :
            : [arg] "{xmm0}" (arg),
        ),
        2 => asm volatile (""
            :
            : [arg] "{xmm1}" (arg),
        ),
        3 => asm volatile (""
            :
            : [arg] "{xmm2}" (arg),
        ),
        4 => asm volatile (""
            :
            : [arg] "{xmm3}" (arg),
        ),
        5 => asm volatile (""
            :
            : [arg] "{xmm4}" (arg),
        ),
        6 => asm volatile (""
            :
            : [arg] "{xmm5}" (arg),
        ),
        7 => asm volatile (""
            :
            : [arg] "{xmm6}" (arg),
        ),
        8 => asm volatile (""
            :
            : [arg] "{xmm7}" (arg),
        ),
        else => @panic("TODO: stack floats"),
    }
}