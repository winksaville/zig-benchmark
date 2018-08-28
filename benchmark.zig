// A benchmark framework very very loosely based on
// [google/benchmark](https://github.com/google/benchmark).
//
// Here is some information from intel, but after looking
// at google/benchmark it appears they aren't directly using
// these techniques so for now I'm just using zig's Timer.
// 
// [Benchmark information for X86 from Intel]
//   (https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf)
// [Intel 64 and IA-32 ARchitectures SDM]
//   (https://www.intel.com/content/www/us/en/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html)
//

const builtin = @import("builtin");
const TypeInfo = builtin.TypeInfo;
const TypeId = builtin.TypeId;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Timer = std.os.time.Timer;
const mem = std.mem;
const bufPrint = std.fmt.bufPrint;
const format = std.fmt.format;
const warn = std.debug.warn;
const assert = std.debug.assert;
const assertError = std.debug.assertError;

const ns_per_s = 1000000000;

/// mfence instruction
fn mfence() void {
    asm volatile ("mfence": : :"memory");
}

/// lfence instruction
fn lfence() void {
    asm volatile ("lfence": : :"memory");
}

/// sfence instruction
fn sfence() void {
    asm volatile ("sfence": : :"memory");
}

/// A possible API for a benchmark framework
pub const Benchmark = struct {
    const Self = this;

    const Result = struct {
        run_time_ns: u64,
        iterations: u64,

        // Ascending compare lhs < rhs
        fn asc(lhs: Result, rhs: Result) bool {
            return lhs.run_time_ns < rhs.run_time_ns;
        }

        // Descending compare lhs > rhs
        fn desc(lhs: Result, rhs: Result) bool {
            return lhs.run_time_ns > rhs.run_time_ns;
        }
    };

    pub name: []const u8,
    pub logl: usize,
    pub min_runtime_ns: u64,
    pub repetitions: u64,
    pub max_iterations: u64,
    timer: Timer,
    pAllocator: *Allocator,
    results: ArrayList(Result),

    /// Initialize benchmark framework
    pub fn init(name: []const u8, pAllocator: *Allocator) Self {
        return Self {
            .name = name,
            .logl = 0,
            .min_runtime_ns = ns_per_s / 2,
            .repetitions = 1,
            .max_iterations = 100000000000,
            .timer = undefined,
            .pAllocator = pAllocator,
            .results = ArrayList(Result).init(pAllocator),
        };
    }

    /// Run the benchmark
    pub fn run(pSelf: *Self, comptime T: type) !T {
        if (pSelf.logl >= 1)
            warn("run: logl={} min_runtime_ns={} max_iterations={}\n",
                    pSelf.logl, pSelf.min_runtime_ns, pSelf.max_iterations);

        // Make sure T is a struct
        const info = @typeInfo(T);
        if (TypeId(info) != TypeId.Struct) @compileError("T is not a Struct");

        // Call bm.init if available
        var bm: T = undefined;
        if (comptime defExists("init", info.Struct.defs)) {
            if (comptime @typeOf(T.init).ReturnType == T) {
                bm = T.init();
            } else {
                bm = try T.init();
            }
        }

        var once = true;
        var iterations: u64 = 1;
        var rep: u64 = 0;
        while (rep < pSelf.repetitions) : (rep += 1) {
            var run_time_ns: u64 = 0;

            // Call bm.setup with try if needed
            if (comptime defExists("setup", info.Struct.defs)) {
                if (comptime @typeOf(T.setup).ReturnType == void) {
                    bm.setup();
                } else {
                    try bm.setup();
                }
            }

            // This loop increases iterations until the time is at least min_runtime_ns.
            // uses that iterations count for each subsequent repetition.
            while (iterations <= pSelf.max_iterations) {
                // Run the current iterations
                run_time_ns = try pSelf.runIterations(T, &bm, iterations);

                // If it took >= min_runtime_ns or was very large we'll do the next repeition.
                if ((run_time_ns >= pSelf.min_runtime_ns) or (iterations >= pSelf.max_iterations)) {
                    // Append the result and do the next iteration
                    try pSelf.results.append(
                            Result { .run_time_ns = run_time_ns, .iterations = iterations});
                    break;
                } else {
                    if (pSelf.logl >= 1) {
                        try pSelf.report(
                            Result {.run_time_ns = run_time_ns, .iterations = iterations});
                            warn("\n");
                    }
                    // Increase iterations count
                    var denom: u64 = undefined;
                    var numer: u64 = undefined;
                    if (run_time_ns < 1000) {
                        numer = 1000;
                        denom = 1;
                    } else if (run_time_ns < (pSelf.min_runtime_ns / 10)) {
                        numer = 10;
                        denom = 1;
                    } else {
                        numer = 14;
                        denom = 10;
                    }
                    iterations = (iterations * numer) / denom;
                    if (iterations > pSelf.max_iterations) {
                        iterations = pSelf.max_iterations;
                    }
                    if (pSelf.logl >= 2) {
                        warn("iteratons:{} numer:{} denom:{}\n", iterations, numer, denom);
                    }
                }
            }

            // Call bm.tearDown with try if needed
            if (comptime defExists("tearDown", info.Struct.defs)) {
                if (comptime @typeOf(T.tearDown).ReturnType == void) {
                    bm.tearDown();
                } else {
                    try bm.tearDown();
                }
            }

            // Report the last result
            if (once) {
                once = false;
                try leftJustified(22, "name repetitions:{}", pSelf.repetitions);
                try rightJustified(14, "{}", "iterations");
                try rightJustified(12, "{}", "time");
                try rightJustified(18, "{}", "time/operation");
                warn("\n");
            }
            try pSelf.report(pSelf.results.items[pSelf.results.len - 1]); warn("\n");
        }

        try pSelf.reportStats(pSelf.results);

        return bm;
    }

    /// Run the specified number of iterations returning the time in ns
    fn runIterations(
        pSelf: *Self,
        comptime T: type,
        pBm: *T,
        iterations: u64,
    ) !u64 {
        var timer = try Timer.start();
        var iter = iterations;
        while (iter > 0) : (iter -= 1) {
            const args_len = comptime @typeInfo(@typeOf(T.benchmark)).Fn.args.len;
            switch (comptime args_len) {
                0 => {
                    if (comptime @typeOf(T.benchmark).ReturnType == void) {
                        T.benchmark();
                    } else {
                        try T.benchmark();
                    }
                },
                1 => {
                    if (comptime @typeOf(T.benchmark).ReturnType == void) {
                        pBm.benchmark();
                    } else {
                        try pBm.benchmark();
                    }
                },
                else => {
                    @compileError("Expected T.benchmark to have 0 or 1 parameter");
                },
            }
        }
        return timer.read();
    }

    fn defExists(name: [] const u8, comptime defs: []TypeInfo.Definition) bool {
        for (defs) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                return true;
            }
        }
        return false;
    }

    fn pad(count: usize, char: u8) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            warn("{c}", char);
        }
    }

    fn rightJustified(width: usize, comptime fmt: []const u8, args: ...) !void {
        var buffer: [40]u8 = undefined;
        var str = try bufPrint(buffer[0..], fmt, args);
        if (width > str.len) {
            pad(width - str.len, ' ');
        }
        warn("{}", str[0..]);
    }

    fn leftJustified(width: usize, comptime fmt: []const u8, args: ...) !void {
        var buffer: [40]u8 = undefined;
        var str = try bufPrint(buffer[0..], fmt, args);
        warn("{}", str[0..]);
        if (width > str.len) {
            pad(width - str.len, ' ');
        }
    }

    fn report(pSelf: *Self, result: Result) !void {
        try leftJustified(22, "{s}", pSelf.name);
        try rightJustified(14, "{}", result.iterations);
        try rightJustified(12, "{.3} s",
                @intToFloat(f64, result.run_time_ns)/@intToFloat(f64, ns_per_s));
        try rightJustified(18, "{.3} ns/op",
                @intToFloat(f64, result.run_time_ns)/@intToFloat(f64, result.iterations));
    }

    fn reportStats(pSelf: *Self, results: ArrayList(Result)) !void {
        // Compute sum
        var sum: f64 = 0;
        for (results.toSlice()) |result, i| {
            sum += @intToFloat(f64, result.run_time_ns);
        }
        try pSelf.reportStatsMean(sum, pSelf.results); warn(" mean\n");
        try pSelf.reportStatsMedian(sum, pSelf.results); warn(" median\n");
        try pSelf.reportStatsStdDev(sum, pSelf.results); warn(" stddev\n");
    }

    fn reportStatsMean(pSelf: *Self, sum: f64, results: ArrayList(Result)) !void {
        try pSelf.report(Result {
            .run_time_ns = @floatToInt(u64, sum / @intToFloat(f64, results.len)),
            .iterations = results.items[0].iterations}
        );
    }

    fn reportStatsMedian(pSelf: *Self, sum: f64, results: ArrayList(Result)) !void {
        if (results.len < 3) {
            try pSelf.reportStatsMean(sum, results);
            return;
        }

        try pSelf.report(Result {
            .run_time_ns = @floatToInt(u64, try pSelf.statsMedian(sum, results)),
            .iterations = results.items[0].iterations}
        );
    }

    fn reportStatsStdDev(pSelf: *Self, sum: f64, results: ArrayList(Result)) !void {
        var std_dev: f64 = 0;
        if (results.len <= 1) {
            std_dev = 0;
        } else {
            std_dev = pSelf.statsStdDev(sum, results);
        }

        try pSelf.report(Result {
            .run_time_ns = @floatToInt(u64, std_dev),
            .iterations = results.items[0].iterations}
        );
    }

    fn statsMean(pSelf: *Self, sum: f64, results: ArrayList(Result)) f64 {
            return sum / @intToFloat(f64, results.len);
    }

    fn statsMedian(pSelf: *Self, sum: f64, results: ArrayList(Result)) !f64 {
        if (results.len < 3) {
            return pSelf.statsMean(sum, results);
        }

        // Make a copy and sort it
        var copy = ArrayList(Result).init(pSelf.pAllocator);
        for (results.toSlice()) |result| {
            try copy.append(result);
        }
        std.sort.sort(Result, copy.toSlice(), Result.asc);

        // Determine the median
        var center = copy.len / 2;
        var median: f64 = undefined;
        if ((copy.len & 1) == 1) {
            // Odd number of items, use center
            median = @intToFloat(f64, copy.items[center].run_time_ns);
        } else {
            // Even number of items, use average of items[center] and items[center - 1]
            median = @intToFloat(f64, copy.items[center-1].run_time_ns
                        + copy.items[center].run_time_ns) / 2;
        }
        return median;
    }

    fn statsStdDev(pSelf: *Self, sum: f64, results: ArrayList(Result)) f64 {
        var std_dev: f64 = 0;
        if (results.len <= 1) {
            std_dev = 0;
        } else {
            var sum_of_squares: f64 = 0;
            var mean: f64 = pSelf.statsMean(sum, results);
            for (results.toSlice()) |result| {
                var diff = @intToFloat(f64, result.run_time_ns) - mean;
                var square = diff * diff;
                sum_of_squares += square;
            }
            std_dev = @sqrt(f64, sum_of_squares / @intToFloat(f64, results.len - 1));
        }
        return std_dev;
    }
};

test "BmNoSelf.lfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmNoSelf", std.debug.global_allocator);
    _ = try bm.run(struct {
        fn benchmark() void {
            lfence();
        }
    });
}

test "BmSelf.sfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmSelf", std.debug.global_allocator);
    _ = try bm.run(struct {
        const Self = this;

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            sfence();
        }
    });
}

test "BmSelf.mfence.init" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
            mfence();
        }
    };

    var bmSelf = try bm.run(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count == 0);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count == 0);
}

test "BmSelf.init.setup" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        fn setup(pSelf: *Self) void {
            pSelf.setup_count += 1;
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }
    };

    bm.repetitions = 3;
    var bmSelf = try bm.run(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count == 3);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count == 0);
}

// Measure @atomicRmw Add operation
test "BmSelf.init.setup.tearDown.AtomicRmwOp.Add" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        fn setup(pSelf: *Self) void {
            pSelf.setup_count += 1;
        }

        // This measures the cost of the atomic rmw add:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   20d897:	c5 f9 6f 8c 24 b0 00 	vmovdqa xmm1,XMMWORD PTR [rsp+0xb0]
        //   20d89e:	00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   20d8a0:	48 85 db             	test   rbx,rbx
        //   20d8a3:	0f 84 8d 00 00 00    	je     20d936 <BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add+0x286>
        //             _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        //   20d8a9:	48 8d 4b ff          	lea    rcx,[rbx-0x1]
        //   20d8ad:	48 89 da             	mov    rdx,rbx
        //   20d8b0:	48 89 d8             	mov    rax,rbx
        //   20d8b3:	48 83 e2 07          	and    rdx,0x7
        //   20d8b7:	74 1b                	je     20d8d4 <BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add+0x224>
        //   20d8b9:	48 f7 da             	neg    rdx
        //   20d8bc:	48 89 d8             	mov    rax,rbx
        //   20d8bf:	90                   	nop
        //   20d8c0:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d8c7:	00 00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   20d8ca:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   20d8ce:	48 83 c2 01          	add    rdx,0x1
        //   20d8d2:	75 ec                	jne    20d8c0 <BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add+0x210>
        //             _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        //   20d8d4:	48 83 f9 07          	cmp    rcx,0x7
        //   20d8d8:	72 5c                	jb     20d936 <BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add+0x286>
        //   20d8da:	66 0f 1f 44 00 00    	nop    WORD PTR [rax+rax*1+0x0]
        //   20d8e0:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d8e7:	00 00 00 
        //   20d8ea:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d8f1:	00 00 00 
        //   20d8f4:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d8fb:	00 00 00 
        //   20d8fe:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d905:	00 00 00 
        //   20d908:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d90f:	00 00 00 
        //   20d912:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d919:	00 00 00 
        //   20d91c:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d923:	00 00 00 
        //   20d926:	f0 48 81 44 24 30 01 	lock add QWORD PTR [rsp+0x30],0x1
        //   20d92d:	00 00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   20d930:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
        //   20d934:	75 aa                	jne    20d8e0 <BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add+0x230>
        //         var ts: posix.timespec = undefined;
        //   20d936:	c5 f9 7f 84 24 b0 00 	vmovdqa XMMWORD PTR [rsp+0xb0],xmm0
        fn benchmark(pSelf: *Self) void {
            _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        }

        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };

    bm.repetitions = 10;
    var bmSelf = try bm.run(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count == 10);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count == 10);
}

/// The inner loop is optimized away.
test "BmAdd" {
    // Our benchmark
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u64,

        // Initialize Self
        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        // Optional setup prior to the first call to Self.benchmark, may return void or !void
        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.scalar(u64);
            pSelf.b = prng.random.scalar(u64);
        }

        // The entire loop is optimized away and the time is 0.000 s.
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   20e64c:	c5 f9 6f 54 24 30    	vmovdqa xmm2,XMMWORD PTR [rsp+0x30]
        //         while (iter > 0) : (iter -= 1) {
        //   20e652:	48 85 db             	test   rbx,rbx
        //   20e655:	4d 0f 45 f4          	cmovne r14,r12
        //         var ts: posix.timespec = undefined;
        //   20e659:	c5 f8 29 4c 24 30    	vmovaps XMMWORD PTR [rsp+0x30],xmm1
        fn benchmark(pSelf: *Self) void {
            pSelf.r = pSelf.a + pSelf.b;
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) + u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("BmAdd", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.run(BmAdd);
}

/// The inner loop is empty
test "BmAdd.Acquire.Release" {
    // Our benchmark
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u64,

        // Initialize Self
        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        // Optional setup prior to the first call to Self.benchmark, may return void or !void
        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.scalar(u64);
            pSelf.b = prng.random.scalar(u64);
        }

        // Adding @fence Acquire and Release help we are just measure the loop costs:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   20f379:	c5 f9 6f 54 24 20    	vmovdqa xmm2,XMMWORD PTR [rsp+0x20]
        //         while (iter > 0) : (iter -= 1) {
        //   20f37f:	48 85 db             	test   rbx,rbx
        //   20f382:	74 45                	je     20f3c9 <BmAdd.Acquire.Release+0x3a9>
        //             @fence(AtomicOrder.Acquire);
        //   20f384:	48 8d 4b ff          	lea    rcx,[rbx-0x1]
        //   20f388:	48 89 da             	mov    rdx,rbx
        //   20f38b:	48 89 d8             	mov    rax,rbx
        //   20f38e:	48 83 e2 07          	and    rdx,0x7
        //   20f392:	74 16                	je     20f3aa <BmAdd.Acquire.Release+0x38a>
        //   20f394:	48 f7 da             	neg    rdx
        //   20f397:	48 89 d8             	mov    rax,rbx
        //   20f39a:	66 0f 1f 44 00 00    	nop    WORD PTR [rax+rax*1+0x0]
        //         while (iter > 0) : (iter -= 1) {
        //   20f3a0:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   20f3a4:	48 83 c2 01          	add    rdx,0x1
        //   20f3a8:	75 f6                	jne    20f3a0 <BmAdd.Acquire.Release+0x380>
        //   20f3aa:	4d 89 f4             	mov    r12,r14
        //             @fence(AtomicOrder.Acquire);
        //   20f3ad:	48 83 f9 07          	cmp    rcx,0x7
        //   20f3b1:	72 16                	jb     20f3c9 <BmAdd.Acquire.Release+0x3a9>
        //   20f3b3:	66 66 66 66 2e 0f 1f 	data16 data16 data16 nop WORD PTR cs:[rax+rax*1+0x0]
        //   20f3ba:	84 00 00 00 00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   20f3c0:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
        //   20f3c4:	75 fa                	jne    20f3c0 <BmAdd.Acquire.Release+0x3a0>
        //   20f3c6:	4d 89 f4             	mov    r12,r14
        //         var ts: posix.timespec = undefined;
        //   20f3c9:	c5 f8 29 4c 24 20    	vmovaps XMMWORD PTR [rsp+0x20],xmm1
        fn benchmark(pSelf: *Self) void {
            @fence(AtomicOrder.Acquire);
            pSelf.r = pSelf.a + pSelf.b;
            @fence(AtomicOrder.Release);
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) + u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("BmAdd", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.run(BmAdd);
}

/// This measures lfence sfence in the loop
test "BmAdd.lfence.sfence" {
    // Our benchmark
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u64,

        // Initialize Self
        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        // Optional setup prior to the first call to Self.benchmark, may return void or !void
        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.scalar(u64);
            pSelf.b = prng.random.scalar(u64);
        }

        // Add lfence/sfence doesn't help here we're just measuring lfence/sfence:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   2100e9:	c5 f9 6f 54 24 20    	vmovdqa xmm2,XMMWORD PTR [rsp+0x20]
        //         while (iter > 0) : (iter -= 1) {
        //   2100ef:	48 85 db             	test   rbx,rbx
        //   2100f2:	74 1b                	je     21010f <BmAdd.lfence.sfence+0x39f>
        //   2100f4:	48 89 d8             	mov    rax,rbx
        //   2100f7:	66 0f 1f 84 00 00 00 	nop    WORD PTR [rax+rax*1+0x0]
        //   2100fe:	00 00 
        //     asm volatile ("lfence": : :"memory");
        //   210100:	0f ae e8             	lfence 
        //     asm volatile ("sfence": : :"memory");
        //   210103:	0f ae f8             	sfence 
        //         while (iter > 0) : (iter -= 1) {
        //   210106:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   21010a:	75 f4                	jne    210100 <BmAdd.lfence.sfence+0x390>
        //   21010c:	4d 89 f4             	mov    r12,r14
        //         var ts: posix.timespec = undefined;
        //   21010f:	c5 f8 29 4c 24 20    	vmovaps XMMWORD PTR [rsp+0x20],xmm1
        fn benchmark(pSelf: *Self) void {
            lfence();
            pSelf.r = pSelf.a + pSelf.b;
            sfence();
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) + u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("BmAdd", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.run(BmAdd);
}

/// Use volatile to actually measure r = a + b
test "BmAdd.volatile" {
    // Our benchmark
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u64,

        // Initialize Self
        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        // Optional setup prior to the first call to Self.benchmark, may return void or !void
        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.scalar(u64);
            pSelf.b = prng.random.scalar(u64);
        }

        // Using volatile we are actually measure the cost of loading adding and storing:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   210e49:	c5 f9 6f 54 24 30    	vmovdqa xmm2,XMMWORD PTR [rsp+0x30]
        //         while (iter > 0) : (iter -= 1) {
        //   210e4f:	48 85 db             	test   rbx,rbx
        //   210e52:	0f 84 b6 00 00 00    	je     210f0e <BmAdd.volatile+0x42e>
        //             pR.* = (pA.* + pB.*);
        //   210e58:	48 8d 4b ff          	lea    rcx,[rbx-0x1]
        //   210e5c:	48 89 da             	mov    rdx,rbx
        //   210e5f:	48 89 d8             	mov    rax,rbx
        //   210e62:	48 83 e2 07          	and    rdx,0x7
        //   210e66:	74 21                	je     210e89 <BmAdd.volatile+0x3a9>
        //   210e68:	48 f7 da             	neg    rdx
        //   210e6b:	48 89 d8             	mov    rax,rbx
        //   210e6e:	66 90                	xchg   ax,ax
        //   210e70:	48 8b 74 24 10       	mov    rsi,QWORD PTR [rsp+0x10]
        //   210e75:	48 03 74 24 08       	add    rsi,QWORD PTR [rsp+0x8]
        //   210e7a:	48 89 74 24 18       	mov    QWORD PTR [rsp+0x18],rsi
        //         while (iter > 0) : (iter -= 1) {
        //   210e7f:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   210e83:	48 83 c2 01          	add    rdx,0x1
        //   210e87:	75 e7                	jne    210e70 <BmAdd.volatile+0x390>
        //             pR.* = (pA.* + pB.*);
        //   210e89:	48 83 f9 07          	cmp    rcx,0x7
        //   210e8d:	72 7f                	jb     210f0e <BmAdd.volatile+0x42e>
        //   210e8f:	90                   	nop
        //   210e90:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210e95:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210e9a:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210e9f:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210ea4:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210ea9:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210eae:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210eb3:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210eb8:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210ebd:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210ec2:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210ec7:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210ecc:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210ed1:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210ed6:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210edb:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210ee0:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210ee5:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210eea:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210eef:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   210ef4:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   210ef9:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   210efe:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //         while (iter > 0) : (iter -= 1) {
        //   210f03:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
        //             pR.* = (pA.* + pB.*);
        //   210f07:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //         while (iter > 0) : (iter -= 1) {
        //   210f0c:	75 82                	jne    210e90 <BmAdd.volatile+0x3b0>
        //         var ts: posix.timespec = undefined;
        //   210f0e:	c5 f8 29 4c 24 30    	vmovaps XMMWORD PTR [rsp+0x30],xmm1
        fn benchmark(pSelf: *Self) void {
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u64 = &pSelf.r;
            pR.* = (pA.* + pB.*);
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) + u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("BmAdd", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.run(BmAdd);
}

test "BmNoSelf.error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark() can return an error
    var bm = Benchmark.init("BmNoSelf.error", std.debug.global_allocator);
    assertError(bm.run(struct {
        fn benchmark() !void {
            return error.TestError;
        }
    }), error.TestError);
}

test "BmSelf.init_error.setup.tearDown" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() !Self {
            return error.InitError;
        }

        fn setup(pSelf: *Self) void {
            pSelf.setup_count += 1;
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }

        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };

    assertError(bm.run(BmSelf), error.InitError);
}

test "BmSelf.init.setup_error.tearDown" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        fn setup(pSelf: *Self) !void {
            pSelf.setup_count += 1;
            return error.SetupError;
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }

        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };

    assertError(bm.run(BmSelf), error.SetupError);
}

test "BmSelf.init.setup.tearDown_error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        fn setup(pSelf: *Self) void {
            pSelf.setup_count += 1;
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }

        fn tearDown(pSelf: *Self) !void {
            return error.TearDownError;
        }
    };

    assertError(bm.run(BmSelf), error.TearDownError);
}

test "BmSelf.init.setup.tearDown.benchmark_error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init() Self {
            return Self {
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }

        fn setup(pSelf: *Self) void {
            pSelf.setup_count += 1;
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) !void {
            return error.BenchmarkError;
        }

        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };

    assertError(bm.run(BmSelf), error.BenchmarkError);
}

test "BmSelf.no_init.no_setup.no_tearDown.benchmark_error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmEmpty.error", std.debug.global_allocator);
    assertError(bm.run(struct {
        const Self = this;

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) !void {
            return error.BenchmarkError;
        }
    }), error.BenchmarkError);
}
