// [Benchmark information for X86 from Intel]
//   (https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf)
//
// [Intel 64 and IA-32 ARchitectures SDM]
//   (https://www.intel.com/content/www/us/en/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html)
//
// [google/benchmark]
//   (https://github.com/google/benchmark)

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

const BenchmarkState = struct {
};

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

    min_runtime_ns: u64,
    max_iterations: u64,
    timer: Timer,

    /// Initialize benchmark framework
    pub fn init() Self {
        return Self {
            .min_runtime_ns = ns_per_s / 2,
            .max_iterations = 100000000000,
            .timer = undefined,
        };
    }

    /// Run the benchmark
    pub fn run(pSelf: *Self, comptime T: type) !void {
        var run_time: u64 = 0;
        var iterations: u64 = 1;
        var state = BenchmarkState {};

        // Make sure T is a struct
        const info = @typeInfo(T);
        if (TypeId(info) != TypeId.Struct) return error.T_NotStruct;

        // It has to have an init which returns Self
        var bm = T.init();

        // Call bm.setup with try if needed
        //if (comptime getFnReturnType("setup", info.Struct.defs) == void) {
        if (comptime @typeOf(T.setup).ReturnType == void) {
            bm.setup();
        } else {
            try bm.setup();
        }

        while (iterations < pSelf.max_iterations) {
            run_time = try runIterations(pSelf, T, &bm, iterations);
            //warn("run_time={} min_runtime_ns={}\n", run_time, pSelf.min_runtime_ns);
            if ((run_time >= pSelf.min_runtime_ns) or (iterations >= pSelf.max_iterations)) {
                //warn("done\n");
                break;
            } else {
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
                //warn("iteratons:{} numer:{} denom:{}\n", iterations, numer, denom);
            }
        }
        // Call bm.tearDown with try if needed
        //if (comptime getFnReturnType("tearDown", info.Struct.defs) == void) {
        if (comptime @typeOf(T.tearDown).ReturnType == void) {
            bm.tearDown();
        } else {
            try bm.tearDown();
        }

        warn("\niterations:{} runtime:{.3}s ns/op:{.0}ns\n",
            iterations,
            @intToFloat(f64, run_time)/@intToFloat(f64, ns_per_s),
            @intToFloat(f64, run_time)/@intToFloat(f64, iterations),
        );
    }

    fn getFnReturnType(name: [] const u8, defs: []TypeInfo.Definition) type {
        for (defs) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                return def.data.Fn.return_type;
            }
        }
        return error.NoReturnType;
    }

    /// Run the specified number of iterations returning the time in ns
    fn runIterations(
        pSelf: *Self,
        comptime T: type,
        pBm: *T,
        //pState: *BenchmarkState,
        iterations: u64,
    ) !u64 {
        const info = @typeInfo(T);

        //warn("runIterations: iteratons={}\n", iterations);
        var timer = try Timer.start();
        var iter = iterations;
        while (iter > 0) : (iter -= 1) {
            // Call bm.setup with try if needed
            //lfence();
            //@fence(AtomicOrder.Acquire); // Generates no type of fence, expected lfence
            if (comptime getFnReturnType("benchmark", info.Struct.defs) == void) {
                pBm.benchmark();
            } else {
                try pBm.benchmark();
            }
            //sfence();
            //@fence(AtomicOrder.Release); // Generates no type of fence, expected sfence
            //@fence(AtomicOrder.AcqRel); // Generates no type of fence, expected ??
            //@fence(AtomicOrder.SeqCst); // Generates mfence
        }
        var time = timer.read();
        warn("runIterations: iterations:{} runtime:{.3}s ns/op:{.0}ns\n",
            iterations,
            @intToFloat(f64, time)/@intToFloat(f64, ns_per_s),
            @intToFloat(f64, time)/@intToFloat(f64, iterations),
        );
        return time;
    }
};


test "benchmark.add" {
    const BmAdd = struct {
        const Self = this;

        a: u64,
        b: u64,
        r: u128,

        fn init() Self {
            return Self {
                .a = undefined, .b = undefined, .r = undefined,
            };
        }

        fn setup(pSelf: *Self) !void {
            var timer = try Timer.start();
            const DefaultPrng = std.rand.DefaultPrng;
            var prng = DefaultPrng.init(timer.read());
            pSelf.a = prng.random.range(u64, 0, 10000000);
            pSelf.b = prng.random.range(u64, 0, 10000000);
        }

        fn benchmark(pSelf: *Self) void {
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u128 = &pSelf.r;
            pR.* = pA.* + pB.*;
        }

        fn tearDown(pSelf: *Self) void {
        }
    };

    var bf = BenchmarkFramework.init();
    try bf.run(BmAdd);
}
