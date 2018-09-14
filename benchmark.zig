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

/// compiler fence, request compiler to not reorder around cfence.
fn cfence() void {
    asm volatile ("": : :"memory");
}

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
    const Self = @This();

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
    pub pre_run_results: ArrayList(Result),
    pub results: ArrayList(Result),
    timer: Timer,
    pAllocator: *Allocator,

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
            .pre_run_results = ArrayList(Result).init(pAllocator),
            .results = ArrayList(Result).init(pAllocator),
        };
    }

    /// Create an instance of T and run it
    pub fn createRun(pSelf: *Self, comptime T: type) !T {
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
        try pSelf.run(&bm);
        return bm;
    }

    pub fn run(pSelf: *Self, bm: var) !void {
        var once = true;
        var iterations: u64 = 1;
        var rep: u64 = 0;
        while (rep < pSelf.repetitions) : (rep += 1) {
            const T = @typeOf(bm.*);
            var run_time_ns: u64 = 0;

            // This loop increases iterations until the time is at least min_runtime_ns.
            // uses that iterations count for each subsequent repetition.
            while (iterations <= pSelf.max_iterations) {
                // Run the current iterations
                run_time_ns = try pSelf.runIterations(T, bm, iterations);

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
                    try pSelf.pre_run_results.append(
                        Result {.run_time_ns = run_time_ns, .iterations = iterations});

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

            // Report Type header once
            if (once) {
                once = false;
                try leftJustified(22, "name repetitions:{}", pSelf.repetitions);
                try rightJustified(14, "{}", "iterations");
                try rightJustified(12, "{}", "time");
                try rightJustified(18, "{}", "time/operation");
                warn("\n");
            }

            // Report results
            try pSelf.report(pSelf.results.items[pSelf.results.len - 1]); warn("\n");
        }

        try pSelf.reportStats(pSelf.results);
    }

    /// Run the specified number of iterations returning the time in ns
    fn runIterations(
        pSelf: *Self,
        comptime T: type,
        pBm: *T,
        iterations: u64,
    ) !u64 {
        const info = @typeInfo(T);

        // Call bm.setup with try if needed
        if (comptime defExists("setup", info.Struct.defs)) {
            if (comptime @typeOf(T.setup).ReturnType == void) {
                pBm.setup();
            } else {
                try pBm.setup();
            }
        }

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
        var duration = timer.read();

        // Call bm.tearDown with try if needed
        if (comptime defExists("tearDown", info.Struct.defs)) {
            if (comptime @typeOf(T.tearDown).ReturnType == void) {
                pBm.tearDown();
            } else {
                try pBm.tearDown();
            }
        }

        return duration;
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

/// Run a benchmark that needs special init handling before running it benchmark
test "BmRun" {
    // Since this is a test print a \n before we run
    warn("\n");

    const X = struct {
        const Self = @This();

        i: u64,
        initial_i: u64,
        init_count: u64,
        setup_count: u64,
        benchmark_count: u64,
        tearDown_count: u64,

        fn init(initial_i: u64) Self {
            return Self {
                .i = 0,
                .initial_i = initial_i,
                .init_count = 1,
                .setup_count = 0,
                .benchmark_count = 0,
                .tearDown_count = 0,
            };
        }
        fn setup(pSelf: *Self) void {
            pSelf.i = pSelf.initial_i;
            pSelf.setup_count += 1;
        }
        fn benchmark(pSelf: *Self) void {
            var pI: *volatile u64 = &pSelf.i;
            pI.* += 1;
            pSelf.benchmark_count += 1;
        }
        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };
    // Create and initialize outside of Benchmark
    const initial_i: u64 = 123;
    var x = X.init(initial_i);

    // Use Benchmark.run to run it
    var bm = Benchmark.init("BmRun", std.debug.global_allocator);
    bm.repetitions = 2;
    try bm.run(&x);

    assert(x.i == (initial_i + bm.results.items[0].iterations));
    assert(x.i == (initial_i + bm.results.items[1].iterations));
    assert(x.init_count == 1);
    assert(x.setup_count - bm.pre_run_results.len == 2);
    assert(x.benchmark_count > 1000000);
    assert(x.tearDown_count - bm.pre_run_results.len == 2);
}

test "BmSimple.cfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmSimple.cfence", std.debug.global_allocator);
    _ = try bm.createRun(struct {
        fn benchmark() void {
            cfence();
        }
    });
}

test "BmSimple.lfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmSimple.lfence", std.debug.global_allocator);
    _ = try bm.createRun(struct {
        fn benchmark() void {
            lfence();
        }
    });
}

test "BmSimple.sfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmSimple.sfence", std.debug.global_allocator);
    _ = try bm.createRun(struct {
        fn benchmark() void {
            sfence();
        }
    });
}

test "BmSimple.mfence" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark and run
    var bm = Benchmark.init("BmSimple.mfence", std.debug.global_allocator);
    _ = try bm.createRun(struct {
        fn benchmark() void {
            mfence();
        }
    });
}

// All of the BmPoor.xxx tests endup with no loops at all and take zero time,
// but are "correct" do test that combinations of init, setup and tearDown work.
//
// Here is a sample of the code from a release-fast build, NOTE there is no loop at all:
//                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
//   20d6c7:	c5 f9 6f 8c 24 90 00 	vmovdqa xmm1,XMMWORD PTR [rsp+0x90]
//   20d6ce:	00 00 
//         var ts: posix.timespec = undefined;
//   20d6d0:	c5 f9 7f 84 24 90 00 	vmovdqa XMMWORD PTR [rsp+0x90],xmm0
//   20d6d7:	00 00 

test "BmPoor.init" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmPoor.init", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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
        }
    };

    var bmSelf = try bm.createRun(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count == 0);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count == 0);
}

test "BmPoor.init.setup" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmPoor.init.setup", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }
    };

    bm.repetitions = 3;
    var bmSelf = try bm.createRun(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count - bm.pre_run_results.len == 3);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count == 0);
}

test "BmPoor.init.setup.tearDown" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmPoor.init.setup.tearDown", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

        fn benchmark(pSelf: *Self) void {
            pSelf.benchmark_count += 1;
        }

        fn tearDown(pSelf: *Self) void {
            pSelf.tearDown_count += 1;
        }
    };

    bm.repetitions = 3;
    var bmSelf = try bm.createRun(BmSelf);
    assert(bmSelf.init_count == 1);
    assert(bmSelf.setup_count - bm.pre_run_results.len == 3);
    assert(bmSelf.benchmark_count > 1000000);
    assert(bmSelf.tearDown_count - bm.pre_run_results.len == 3);
}

/// The inner loop is optimized away.
test "BmPoor.add" {
    // Our benchmark
    const BmAdd = struct {
        const Self = @This();

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

        fn benchmark(pSelf: *Self) void {
            pSelf.r = (pSelf.a +% pSelf.b);
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) +% u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("BmAdd", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.createRun(BmAdd);
}

// Measure @atomicRmw Add operation
test "Bm.AtomicRmwOp.Add" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("Bm.AtomicRmwOp.Add", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

        benchmark_count: u64,

        fn init() Self {
            return Self {
                .benchmark_count = 0,
            };
        }

        // This measures the cost of the atomic rmw add with loop unrolling:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   210811:	c5 f9 6f 8c 24 90 00 	vmovdqa xmm1,XMMWORD PTR [rsp+0x90]
        //   210818:	00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   21081a:	48 85 db             	test   rbx,rbx
        //   21081d:	0f 84 93 00 00 00    	je     2108b6 <Bm.AtomicRmwOp.Add+0x266>
        //             _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        //   210823:	48 8d 4b ff          	lea    rcx,[rbx-0x1]
        //   210827:	48 89 da             	mov    rdx,rbx
        //   21082a:	48 89 d8             	mov    rax,rbx
        //   21082d:	48 83 e2 07          	and    rdx,0x7
        //   210831:	74 21                	je     210854 <Bm.AtomicRmwOp.Add+0x204>
        //   210833:	48 f7 da             	neg    rdx
        //   210836:	48 89 d8             	mov    rax,rbx
        //   210839:	0f 1f 80 00 00 00 00 	nop    DWORD PTR [rax+0x0]
        //   210840:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   210847:	00 00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   21084a:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   21084e:	48 83 c2 01          	add    rdx,0x1
        //   210852:	75 ec                	jne    210840 <Bm.AtomicRmwOp.Add+0x1f0>
        //             _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        //   210854:	48 83 f9 07          	cmp    rcx,0x7
        //   210858:	72 5c                	jb     2108b6 <Bm.AtomicRmwOp.Add+0x266>
        //   21085a:	66 0f 1f 44 00 00    	nop    WORD PTR [rax+rax*1+0x0]
        //   210860:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   210867:	00 00 00 
        //   21086a:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   210871:	00 00 00 
        //   210874:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   21087b:	00 00 00 
        //   21087e:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   210885:	00 00 00 
        //   210888:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   21088f:	00 00 00 
        //   210892:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   210899:	00 00 00 
        //   21089c:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   2108a3:	00 00 00 
        //   2108a6:	f0 48 81 44 24 08 01 	lock add QWORD PTR [rsp+0x8],0x1
        //   2108ad:	00 00 00 
        //         while (iter > 0) : (iter -= 1) {
        //   2108b0:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
        //   2108b4:	75 aa                	jne    210860 <Bm.AtomicRmwOp.Add+0x210>
        //         var ts: posix.timespec = undefined;
        //   2108b6:	c5 f9 7f 84 24 90 00 	vmovdqa XMMWORD PTR [rsp+0x90],xmm0
        //   2108bd:	00 00 
        fn benchmark(pSelf: *Self) void {
            _ = @atomicRmw(u64, &pSelf.benchmark_count, AtomicRmwOp.Add, 1, AtomicOrder.Release);
        }
    };

    bm.repetitions = 10;
    var bmSelf = try bm.createRun(BmSelf);
}

/// Use volatile to actually measure r = a +% b
test "Bm.volatile.add" {
    // Our benchmark
    const BmAdd = struct {
        const Self = @This();

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

        // Using volatile we actually measure the cost of loading, adding and storing:
        //                 self.start_time = @intCast(u64, ts.tv_sec) * u64(ns_per_s) + @intCast(u64, ts.tv_nsec);
        //   211559:	c5 f9 6f 54 24 30    	vmovdqa xmm2,XMMWORD PTR [rsp+0x30]
        //         while (iter > 0) : (iter -= 1) {
        //   21155f:	48 85 db             	test   rbx,rbx
        //   211562:	0f 84 b6 00 00 00    	je     21161e <Bm.volatile.add+0x42e>
        //             pR.* = (pA.* +% pB.*);
        //   211568:	48 8d 4b ff          	lea    rcx,[rbx-0x1]
        //   21156c:	48 89 da             	mov    rdx,rbx
        //   21156f:	48 89 d8             	mov    rax,rbx
        //   211572:	48 83 e2 07          	and    rdx,0x7
        //   211576:	74 21                	je     211599 <Bm.volatile.add+0x3a9>
        //   211578:	48 f7 da             	neg    rdx
        //   21157b:	48 89 d8             	mov    rax,rbx
        //   21157e:	66 90                	xchg   ax,ax
        //   211580:	48 8b 74 24 10       	mov    rsi,QWORD PTR [rsp+0x10]
        //   211585:	48 03 74 24 08       	add    rsi,QWORD PTR [rsp+0x8]
        //   21158a:	48 89 74 24 18       	mov    QWORD PTR [rsp+0x18],rsi
        //         while (iter > 0) : (iter -= 1) {
        //   21158f:	48 83 c0 ff          	add    rax,0xffffffffffffffff
        //   211593:	48 83 c2 01          	add    rdx,0x1
        //   211597:	75 e7                	jne    211580 <Bm.volatile.add+0x390>
        //             pR.* = (pA.* +% pB.*);
        //   211599:	48 83 f9 07          	cmp    rcx,0x7
        //   21159d:	72 7f                	jb     21161e <Bm.volatile.add+0x42e>
        //   21159f:	90                   	nop
        //   2115a0:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115a5:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115aa:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115af:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115b4:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115b9:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115be:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115c3:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115c8:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115cd:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115d2:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115d7:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115dc:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115e1:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115e6:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115eb:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115f0:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   2115f5:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   2115fa:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   2115ff:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //   211604:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //   211609:	48 8b 4c 24 10       	mov    rcx,QWORD PTR [rsp+0x10]
        //   21160e:	48 03 4c 24 08       	add    rcx,QWORD PTR [rsp+0x8]
        //         while (iter > 0) : (iter -= 1) {
        //   211613:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
        //             pR.* = (pA.* +% pB.*);
        //   211617:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        //         while (iter > 0) : (iter -= 1) {
        //   21161c:	75 82                	jne    2115a0 <Bm.volatile.add+0x3b0>
        //         var ts: posix.timespec = undefined;
        //   21161e:	c5 f8 29 4c 24 30    	vmovaps XMMWORD PTR [rsp+0x30],xmm1
        fn benchmark(pSelf: *Self) void {
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u64 = &pSelf.r;
            pR.* = (pA.* +% pB.*);
        }

        // Optional tearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != (u64(pSelf.a) +% u64(pSelf.b))) return error.Failed;
        }
    };

    // Since this is a test print a \n before we run
    warn("\n");

    // Create an instance of Benchmark, set 10 iterations and run
    var bm = Benchmark.init("Bm.Add", std.debug.global_allocator);
    bm.repetitions = 10;
    _ = try bm.createRun(BmAdd);
}

test "BmError.benchmark" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark() can return an error
    var bm = Benchmark.init("BmNoSelf.error", std.debug.global_allocator);
    assertError(bm.createRun(struct {
        fn benchmark() !void {
            return error.TestError;
        }
    }), error.TestError);
}

test "BmError.benchmark.pSelf" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmError.benchmark.pSelf", std.debug.global_allocator);
    assertError(bm.createRun(struct {
        const Self = @This();

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) !void {
            return error.BenchmarkError;
        }
    }), error.BenchmarkError);
}

test "BmError.init_error.setup.tearDown" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmError.init_error.setup.tearDown", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

    assertError(bm.createRun(BmSelf), error.InitError);
}

test "BmError.init.setup_error.tearDown" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmError.init.setup_error.tearDown", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

    assertError(bm.createRun(BmSelf), error.SetupError);
}

test "BmError.init.setup.tearDown_error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmError.init.setup.tearDown_error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

    assertError(bm.createRun(BmSelf), error.TearDownError);
}

test "BmError.init.setup.tearDown.benchmark_error" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("BmError.init.setup.tearDown.benchmark_error", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = @This();

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

    assertError(bm.createRun(BmSelf), error.BenchmarkError);
}

