const std = @import("std");
const log = std.log.scoped(.example);
const assert = std.debug.assert;

const Coyote = @import("coyote-pool");

pub fn main() void {
    var pool = Coyote.Pool.init(10);
    var n: u32 = 0;
    while(n < 10) : (n += 1) {
        _ = pool.add_work(&task, @ptrCast(*anyopaque, &n));
    }
    pool.wait();
    pool.destroy();
}

pub fn task(arg: *anyopaque) void {
    _ = arg;
    std.log.info("Task running!", .{});
}