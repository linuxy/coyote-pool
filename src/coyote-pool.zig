const std = @import("std");
const c = std.c;

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
        self.*.v = value;
    }

    pub fn reset(self: *Semaphore) void {
        self.init(0);
    }

    pub fn post(self: *Semaphore) void {
        self.mutex.lock();
        self.*.v = 1;
        self.cond.signal();
        self.mutex.unlock();
    }

    pub fn post_all(self: *Semaphore) void {
        self.mutex.lock();
        self.*.v = 1;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn wait(self: *Semaphore) void {
        self.mutex.lock();
        while(self.*.v != 1)
            self.cond.wait(&self.mutex);

        self.*.v = 0;
        self.cond.signal();
        self.mutex.unlock();
    }
};

pub const Job = struct {
    prev: ?*Job,
    func: *const fn (*anyopaque) void,
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
        queue.*.len.? = 0;
        queue.*.front = null;
        queue.*.rear = null;

        queue.*.has_jobs = allocator.create(Semaphore) catch unreachable;
        queue.*.rwmutex = std.Thread.Mutex{};
        queue.*.has_jobs.init(0);

        return queue;
    }

    pub fn clear(self: *JobQueue) void {
        while(self.*.len.? > 0)
            allocator.destroy(self.pull().?);

        self.*.front = null;
        self.*.rear = null;
        self.*.has_jobs.reset();
        self.*.len = 0;
    }

    pub fn push(self: *JobQueue, newjob: ?*Job) void {
        self.*.rwmutex.lock();
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
        self.*.rwmutex.unlock();
    }

    pub fn pull(self: *JobQueue) ?*Job {
        self.*.rwmutex.lock();
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
        self.*.rwmutex.unlock();
        return job;
    }

    pub fn destroy(self: *JobQueue) void {
        self.clear();
        allocator.destroy(self.*.has_jobs);
    }
};

pub fn thread_hold(sig: i32, sig_info: *const std.os.siginfo_t, ctx_ptr: ?*const anyopaque) callconv(.C) void {
    _ = sig;
    _ = sig_info;
    _ = ctx_ptr;
    threads_on_hold = 1;
    while(threads_on_hold > 0)
        std.time.sleep(0);
}

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

pub fn do(arg: ?*anyopaque) callconv(.C) void {
    var self = @ptrCast(*Thread, @alignCast(@alignOf(Thread), arg));
    
    std.log.info("Working on thread ID: {}", .{std.Thread.getCurrentId()});

    //Mark as alive
    self.*.pool.*.thread_count_lock.lock();
    self.*.pool.*.num_threads_alive += 1;
    self.*.pool.*.thread_count_lock.unlock();

    while(threads_keepalive > 0) {
        while(threads_on_hold > 0)
            std.time.sleep(0);
        
        self.*.pool.*.jobqueue.*.has_jobs.wait();

        if(threads_keepalive > 0) {

            //Mark as working
            self.*.pool.*.thread_count_lock.lock();
            self.*.pool.*.num_threads_working += 1;
            self.*.pool.*.thread_count_lock.unlock();

            var job = self.*.pool.*.jobqueue.pull();
            if(job != null) {
                @call(.{}, job.?.func, .{job.?.arg});
                allocator.destroy(job.?);
            }
            //Finish working
            self.*.pool.*.thread_count_lock.lock();
            self.*.pool.*.num_threads_working -= 1;
            if (self.*.pool.*.num_threads_working < 1) {
                self.*.pool.*.threads_idle.signal();
            }
            self.*.pool.*.thread_count_lock.unlock();
        }
    }

    self.*.pool.*.thread_count_lock.lock();
    self.*.pool.*.num_threads_alive -= 1;
    self.*.pool.*.thread_count_lock.unlock();
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
        pool.*.num_threads_alive = 0;
        pool.*.num_threads_working = 0;

        //Create job queue
        pool.*.jobqueue = JobQueue.init();

        //Create threads
        pool.*.threads = allocator.alloc(Thread, num_threads) catch unreachable;

        pool.*.thread_count_lock = std.Thread.Mutex{};
        pool.*.threads_idle = std.Thread.Condition{};

        var n: u32 = 0;
        while(n < num_threads) : (n += 1) {
            pool.*.threads[n] = pool.*.threads[n].init(pool, n).*;
        }
        
        while(pool.*.num_threads_alive != num_threads) {
            //
        }

        return pool;
    }

    pub fn add_work(self: *Pool, func: anytype, arg: anytype) u32 {
        var newjob: *Job = allocator.create(Job) catch unreachable;

        newjob.*.func = func;
        newjob.*.arg = arg;

        self.jobqueue.push(newjob);

        return 0;
    }

    pub fn wait(self: *Pool) void {
        self.thread_count_lock.lock();
        while(self.*.jobqueue.len.? > 0 or self.*.num_threads_working > 0) {
            self.threads_idle.wait(&self.thread_count_lock);
        }
        self.thread_count_lock.unlock();
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
        return self.*.num_threads_working;
    }
};