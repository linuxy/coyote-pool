const std = @import("std");
const log = std.log.scoped(.example);
const assert = std.debug.assert;

const Coyote = @import("coyote-pool");

const triangle_num: u64 = 3000000000;
const num_additions_per_task = 2000000;
const num_tasks = (triangle_num) / (num_additions_per_task);

pub fn main() void {
    var pool = Coyote.Pool.init(8);
    defer pool.deinit();

    var subsets: []NumberSubset = Coyote.allocator.alloc(NumberSubset, num_tasks) catch unreachable;

    var next: u64 = 0;
    var i: usize = 0;
    var elapsed = std.time.milliTimestamp();
    while(i < num_tasks) : (i += 1) {
        subsets[i].start = next;
        subsets[i].end = subsets[i].start + num_additions_per_task - 1;
        next = subsets[i].end + 1;
        _ = pool.add_work(&addNumberSubset, &subsets[i]); //@ptrCast(*anyopaque, &subsets[i]));
    }

    pool.pause();
    pool._resume();
    pool.wait();

    i = 0;
    var result: u64 = 0;
    while (i < num_tasks) : (i += 1) {
        result += subsets[i].total;
    }
    elapsed = std.time.milliTimestamp() - elapsed;
    log.info("triangle: {} result: {} elapsed: {}ms", .{ (triangle_num * (triangle_num + 1) / 2), result, elapsed});

    
}

const NumberSubset = struct {
    start: u64,
    end: u64,
    total: u64,
};

pub fn addNumberSubset(subset: *NumberSubset) void {
    //var subset = @ptrCast(*NumberSubset, @alignCast(@alignOf(NumberSubset), arg));
    subset.total = 0;
    while (subset.start <= subset.end) : (subset.start += 1) {
        subset.total += subset.start + 1;
    }
}