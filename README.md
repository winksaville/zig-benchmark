# Zig benchmark

Explore how to make a micro benchmark in zig.

A benchmark framework very very loosely based on
[google/benchmark](https://github.com/google/benchmark).

Here is some information from intel, but after looking
at google/benchmark it appears they aren't directly using
these techniques so for now I'm just using zig's Timer.

[Benchmark information for X86 from Intel]
  (https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf)
[Intel 64 and IA-32 ARchitectures SDM]
  (https://www.intel.com/content/www/us/en/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html)

## Introduction
A benchmark is a struct with fn's init, setup, benchmark and tearDown.
- init is called to create an instance.
 - returns Self
- setup is called once before benchmark is called.
 - May return void or !void
- benchmark is called for each iteration.
 - May return void or !void
- tearDown is called after all iterations.
 - May return void or !void

## Example

To keep the fn benchmark from being optimized to nothing
I'm using volatile pointers. There maybe better solutions
but this kinda works.
```
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

        // Called for ever iteration of the benchmark
        fn benchmark(pSelf: *Self) void {
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u128 = &pSelf.r;
            pR.* = pA.* + pB.*;
        }

        // TearDown called after the last call to Self.benchmark, may return void or !void
        fn tearDown(pSelf: *Self) !void {
            if (pSelf.r != pSelf.a + pSelf.b) return error.Failed;
        }
    };

    // Create an instance of the framework and optionally change min_runtime_ns
    var bf = BenchmarkFramework.init();
    //bf.min_runtime_ns = ns_per_s * 3;
    bf.logl = 1;

    // Since this is a test print a \n before we run
    warn("\n");

    // Run the benchmark
    try bf.run(BmAdd);
}
```

## Test on my desktop debug
```bash
$ time zig test --release-fast benchmark.zig
Test 1/1 benchmark.add...
run: logl=1 min_runtime_ns=500000000 max_iterations=100000000000
iterations:1 runtime:0.000s ns/op:95.000ns
iterations:1000 runtime:0.000s ns/op:1.558ns
iterations:10000 runtime:0.000s ns/op:1.444ns
iterations:100000 runtime:0.000s ns/op:1.972ns
iterations:1000000 runtime:0.001s ns/op:1.471ns
iterations:10000000 runtime:0.013s ns/op:1.336ns
iterations:100000000 runtime:0.061s ns/op:0.611ns
iterations:140000000 runtime:0.085s ns/op:0.610ns
iterations:196000000 runtime:0.120s ns/op:0.610ns
iterations:274400000 runtime:0.156s ns/op:0.567ns
iterations:384160000 runtime:0.218s ns/op:0.566ns
iterations:537824000 runtime:0.303s ns/op:0.563ns
iterations:752953600 runtime:0.424s ns/op:0.563ns
iterations:1054135040 runtime:0.595s ns/op:0.565ns
iterations:1054135040 runtime:0.595s ns/op:0.565ns
OK
All tests passed.

real	0m5.518s
user	0m5.407s
sys	0m0.095s
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
