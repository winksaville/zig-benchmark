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
- init
 - Called once to create an instance of the benchmark to run
 - May return Self or !Self
 - Optional
- setup
 - Called once each repetition before benchmark is called
 - May return void or !void
 - Optional
- benchmark
 - Called for each iteration
 - May return void or !void
 - **Required**
- tearDown
 - Called once each repetition and after benchmark is called
 - May return void or !void
 - Optional

## Example

```
// Measure @atomicRmw Add operation
test "Bm.AtomicRmwOp.Add" {
    // Since this is a test print a \n before we run
    warn("\n");

    // Test fn benchmark(pSelf) can return an error
    var bm = Benchmark.init("Bm.AtomicRmwOp.Add", std.debug.global_allocator);
    const BmSelf = struct {
        const Self = this;

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
    var bmSelf = try bm.run(BmSelf);
}
```

## Test on my desktop debug
```bash
$ zig test --release-fast benchmark.zig 
Test 1/16 BmSimple.cfence...
name repetitions:1        iterations        time    time/operation
BmSimple.cfence           1960000000     0.554 s       0.283 ns/op
BmSimple.cfence           1960000000     0.554 s       0.283 ns/op mean
BmSimple.cfence           1960000000     0.554 s       0.283 ns/op median
BmSimple.cfence           1960000000     0.000 s       0.000 ns/op stddev
OK
Test 2/16 BmSimple.lfence...
name repetitions:1        iterations        time    time/operation
BmSimple.lfence            196000000     0.563 s       2.874 ns/op
BmSimple.lfence            196000000     0.563 s       2.874 ns/op mean
BmSimple.lfence            196000000     0.563 s       2.874 ns/op median
BmSimple.lfence            196000000     0.000 s       0.000 ns/op stddev
OK
Test 3/16 BmSimple.sfence...
name repetitions:1        iterations        time    time/operation
BmSimple.sfence            384160000     0.645 s       1.680 ns/op
BmSimple.sfence            384160000     0.645 s       1.680 ns/op mean
BmSimple.sfence            384160000     0.645 s       1.680 ns/op median
BmSimple.sfence            384160000     0.000 s       0.000 ns/op stddev
OK
Test 4/16 BmSimple.mfence...
name repetitions:1        iterations        time    time/operation
BmSimple.mfence             53782400     0.532 s       9.885 ns/op
BmSimple.mfence             53782400     0.532 s       9.885 ns/op mean
BmSimple.mfence             53782400     0.532 s       9.885 ns/op median
BmSimple.mfence             53782400     0.000 s       0.000 ns/op stddev
OK
Test 5/16 BmPoor.init...
name repetitions:1        iterations        time    time/operation
BmPoor.init             100000000000     0.000 s       0.000 ns/op
BmPoor.init             100000000000     0.000 s       0.000 ns/op mean
BmPoor.init             100000000000     0.000 s       0.000 ns/op median
BmPoor.init             100000000000     0.000 s       0.000 ns/op stddev
OK
Test 6/16 BmPoor.init.setup...
name repetitions:3        iterations        time    time/operation
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op mean
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op median
BmPoor.init.setup       100000000000     0.000 s       0.000 ns/op stddev
OK
Test 7/16 BmPoor.init.setup.tearDown...
name repetitions:3        iterations        time    time/operation
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op mean
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op median
BmPoor.init.setup.tearDown  100000000000     0.000 s       0.000 ns/op stddev
OK
Test 8/16 BmPoor.add...
name repetitions:10       iterations        time    time/operation
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op
BmAdd                   100000000000     0.000 s       0.000 ns/op mean
BmAdd                   100000000000     0.000 s       0.000 ns/op median
BmAdd                   100000000000     0.000 s       0.000 ns/op stddev
OK
Test 9/16 Bm.AtomicRmwOp.Add...
name repetitions:10       iterations        time    time/operation
Bm.AtomicRmwOp.Add         105413504     0.560 s       5.311 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.336 ns/op
Bm.AtomicRmwOp.Add         105413504     0.561 s       5.325 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.333 ns/op
Bm.AtomicRmwOp.Add         105413504     0.561 s       5.324 ns/op
Bm.AtomicRmwOp.Add         105413504     0.563 s       5.338 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.332 ns/op
Bm.AtomicRmwOp.Add         105413504     0.561 s       5.321 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.332 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.328 ns/op
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.328 ns/op mean
Bm.AtomicRmwOp.Add         105413504     0.562 s       5.330 ns/op median
Bm.AtomicRmwOp.Add         105413504     0.001 s       0.008 ns/op stddev
OK
Test 10/16 Bm.volatile.add...
name repetitions:10       iterations        time    time/operation
Bm.Add                    1960000000     0.556 s       0.284 ns/op
Bm.Add                    1960000000     0.559 s       0.285 ns/op
Bm.Add                    1960000000     0.564 s       0.288 ns/op
Bm.Add                    1960000000     0.559 s       0.285 ns/op
Bm.Add                    1960000000     0.560 s       0.286 ns/op
Bm.Add                    1960000000     0.558 s       0.285 ns/op
Bm.Add                    1960000000     0.560 s       0.286 ns/op
Bm.Add                    1960000000     0.559 s       0.285 ns/op
Bm.Add                    1960000000     0.560 s       0.286 ns/op
Bm.Add                    1960000000     0.560 s       0.286 ns/op
Bm.Add                    1960000000     0.560 s       0.286 ns/op mean
Bm.Add                    1960000000     0.560 s       0.286 ns/op median
Bm.Add                    1960000000     0.002 s       0.001 ns/op stddev
OK
Test 11/16 BmError.benchmark...
OK
Test 12/16 BmError.benchmark.pSelf...
OK
Test 13/16 BmError.init_error.setup.tearDown...
OK
Test 14/16 BmError.init.setup_error.tearDown...
OK
Test 15/16 BmError.init.setup.tearDown_error...
OK
Test 16/16 BmError.init.setup.tearDown.benchmark_error...
OK
All tests passed.
```

## Assember output

It's generally a good idea to look at the generated assembler code so you
"know" what is being measured. Because of great optimization zig & llvm do it may
not be what you expect.
```
$ objdump --source -d -M intel ./zig-cache/test > benchmark.fast.asm
```

Here is the loop for BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add
and you see the loop is unrolled by a factor of 8 so the loop costs are
relatively close to zero:
```
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
```

But here is a simple r = a + b expression inside the benchmark loop
and we see that the loop has actually been completely optimized away:
```
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
```

So be very careful you know what's being measured.

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
