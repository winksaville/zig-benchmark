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

const std = @import("std");
const Timer = std.os.time.Timer;
const mem = std.mem;
const warn = std.debug.warn;
const assert = std.debug.assert;

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
const BenchmarkFramework = struct {
    const Self = this;

    pub logl: usize,
    pub min_runtime_ns: u64,
    pub repetitions: u64,
    pub max_iterations: u64,
    timer: Timer,

    /// Initialize benchmark framework
    pub fn init() Self {
        return Self {
            .logl = 0,
            .min_runtime_ns = ns_per_s / 2,
            .repetitions = 1,
            .max_iterations = 100000000000,
            .timer = undefined,
        };
    }

    /// Run the benchmark
    pub fn run(pSelf: *Self, comptime T: type) !void {
        if (pSelf.logl >= 1)
            warn("run: logl={} min_runtime_ns={} max_iterations={}\n",
                    pSelf.logl, pSelf.min_runtime_ns, pSelf.max_iterations);

        // Make sure T is a struct
        const info = @typeInfo(T);
        if (TypeId(info) != TypeId.Struct) return error.T_NotStruct;

        // Create a benchmark struct, it has to have an init which returns Self
        var bm = T.init();

        // Call bm.setup with try if needed
        if (comptime @typeOf(T.setup).ReturnType == void) {
            bm.setup();
        } else {
            try bm.setup();
        }

        var iterations: u64 = 1;
        var rep: u64 = 0;
        while (rep < pSelf.repetitions) : (rep += 1) {
            var run_time: u64 = 0;

            // This loop increases iterations until the time is at least min_runtime_ns.
            // uses that iterations count for each subsequent repetition.
            while (iterations <= pSelf.max_iterations) {
                // Run the current iterations
                run_time = try pSelf.runIterations(T, &bm, iterations);

                // If it took >= min_runtime_ns or was very large we'll do the next repeition.
                if ((run_time >= pSelf.min_runtime_ns) or (iterations >= pSelf.max_iterations)) {
                    // Do next repetition
                    break;
                } else {
                    // Increase iterations count
                    if (pSelf.logl >= 1) pSelf.report(run_time, iterations);

                    var denom: u64 = undefined;
                    var numer: u64 = undefined;
                    if (run_time < 1000) {
                        numer = 1000;
                        denom = 1;
                    } else if (run_time < (pSelf.min_runtime_ns / 10)) {
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
                    if (pSelf.logl >= 2) warn("iteratons:{} numer:{} denom:{}\n", iterations, numer, denom);
                }
            }

            // Call bm.tearDown with try if needed
            if (comptime @typeOf(T.tearDown).ReturnType == void) {
                bm.tearDown();
            } else {
                try bm.tearDown();
            }

            // Report the results
            pSelf.report(run_time, iterations);
        }
    }

    /// Run the specified number of iterations returning the time in ns
    fn runIterations(
        pSelf: *Self,
        comptime T: type,
        pBm: *T,
        iterations: u64,
    ) !u64 {
        const info = @typeInfo(T);

        var timer = try Timer.start();
        var iter = iterations;
        while (iter > 0) : (iter -= 1) {
            if (comptime @typeOf(T.benchmark).ReturnType == void) {
                pBm.benchmark();
            } else {
                try pBm.benchmark();
            }
        }
        return timer.read();
    }

    fn report(pSelf: *Self, run_time_ns: u64, iterations: u64) void {
        warn("iterations:{} runtime:{.3}s ns/op:{.3}ns\n",
            iterations,
            @intToFloat(f64, run_time_ns)/@intToFloat(f64, ns_per_s),
            @intToFloat(f64, run_time_ns)/@intToFloat(f64, iterations),
        );
    }
};

test "benchmark.add" {
    // Our benchmark
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u128,

        // Initialize Self
        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        // Setup prior to the first call to Self.benchmark, may return void or !void
        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.scalar(u64);
            pSelf.b = prng.random.scalar(u64);
        }

        // Called on every iteration of the benchmark, may return void or !void
        fn benchmark(pSelf: *Self) void {
            //lfence();
            //@fence(AtomicOrder.Acquire); // Generates no type of fence, expected lfence
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u128 = &pSelf.r;
            pR.* = u128(pA.*) + u128(pB.*);
            //sfence();
            //@fence(AtomicOrder.Release); // Generates no type of fence, expected sfence
            //@fence(AtomicOrder.AcqRel); // Generates no type of fence, expected ??
            //@fence(AtomicOrder.SeqCst); // Generates mfence
            //mfence();
        }

        // TearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != u128(pSelf.a) + u128(pSelf.b)) return error.Failed;
        }
    };

    // Create an instance of the framework and optionally change min_runtime_ns
    var bf = BenchmarkFramework.init();
    //bf.min_runtime_ns = ns_per_s * 3;
    bf.logl = 1;
    bf.repetitions = 5;

    // Since this is a test print a \n before we run
    warn("\n");

    // Run the benchmark
    try bf.run(BmAdd);
}
