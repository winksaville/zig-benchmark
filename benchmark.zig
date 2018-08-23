// [Benchmark information for X86 from Intel]
//   (https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf)
//
// [Intel 64 and IA-32 ARchitectures SDM]
//   (https://www.intel.com/content/www/us/en/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html)
//
// [google/benchmark]
//   (https://github.com/google/benchmark)

const builtin = @import("builtin");

const std = @import("std");
const Timer = std.os.time.Timer;
const warn = std.debug.warn;
const assert = std.debug.assert;

const ns_per_s = 1000000000;

const BenchmarkState = struct {
};

/// A possible API for a benchmark framework
const BenchmarkFramework = struct {
    const Self = this;

    min_runtime_ns: u64,
    max_iterations: u64,
    timer: Timer,

    /// Initialize framework
    pub fn init() Self {
        return Self {
            .min_runtime_ns = ns_per_s / 2,
            .max_iterations = 100000000000,
            .timer = undefined,
        };
    }

    /// Run the benchmark
    pub fn run(pSelf: *Self, benchmarkFn: fn (*BenchmarkState) void) !void {
        var run_time: u64 = 0;
        var iterations: u64 = 1;
        var state = BenchmarkState {};

        while (iterations < pSelf.max_iterations) {
            run_time = try runIterations(pSelf, &state, iterations, benchmarkFn);
            warn("run_time={} min_runtime_ns={}\n", run_time, pSelf.min_runtime_ns);
            if ((run_time >= pSelf.min_runtime_ns) or (iterations >= pSelf.max_iterations)) {
                warn("done\n");
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
                warn("iteratons:{} numer:{} denom:{}\n", iterations, numer, denom);
            }
        }
        warn("iterations:{} runtime:{}\n", iterations, run_time);
    }

    /// Run the specified number of iterations returning the time in ns
    fn runIterations(
        pSelf: *Self,
        pState: *BenchmarkState,
        iterations: u64,
        benchmarkFn: fn (*BenchmarkState) void,
    ) !u64 {
        warn("runIterations: iteratons={}\n", iterations);
        var timer = try Timer.start();
        var iter = iterations;
        while (iter > 0) : (iter -= 1) {
            benchmarkFn(pState);
        }
        warn("runIterations:- iteratons={}\n", iterations);
        return timer.read();
    }
};

const DefaultPrng = std.rand.DefaultPrng;

var a: u64 = undefined;
var b: u64 = undefined;
var r: u128 = undefined;

fn bmAdd(pState: *BenchmarkState) void {
    r = a * b;
}


test "benchmark.add" {
    var prng = DefaultPrng.init(1234);
    a = prng.random.range(u64, 0, 10000000);
    b = prng.random.range(u64, 0, 10000000);
    var bf = BenchmarkFramework.init();
    try bf.run(bmAdd);
    assert(r == a * b);
}

