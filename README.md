# Zig benchmark

Explore how to make a micro benchmark.

A benchmark is a sturct with fn's init, setup, tearDown and benchmark:
```
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
```

To keep the benchmark from being optimized to nothing
I'm using volatile pointers. There maybe better solutions
but this kinda works.

## Test on my desktop debug
```bash
$ time zig test --release-fast benchmark.zig
Test 1/1 benchmark.add...runIterations: iterations:1 runtime:0.000s ns/op:74ns
runIterations: iterations:1000 runtime:0.000s ns/op:1ns
runIterations: iterations:10000 runtime:0.000s ns/op:1ns
runIterations: iterations:100000 runtime:0.000s ns/op:1ns
runIterations: iterations:1000000 runtime:0.001s ns/op:1ns
runIterations: iterations:10000000 runtime:0.010s ns/op:1ns
runIterations: iterations:100000000 runtime:0.062s ns/op:1ns
runIterations: iterations:140000000 runtime:0.086s ns/op:1ns
runIterations: iterations:196000000 runtime:0.121s ns/op:1ns
runIterations: iterations:274400000 runtime:0.158s ns/op:1ns
runIterations: iterations:384160000 runtime:0.218s ns/op:1ns
runIterations: iterations:537824000 runtime:0.306s ns/op:1ns
runIterations: iterations:752953600 runtime:0.428s ns/op:1ns
runIterations: iterations:1054135040 runtime:0.595s ns/op:1ns

iterations:1054135040 runtime:0.595s ns/op:1ns
OK
All tests passed.

real	0m5.532s
user	0m5.419s
sys	0m0.101s
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
