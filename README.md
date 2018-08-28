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
test "BmSelf.init.setup.tearDown.benchmark.AtomicRmwOp.Add" {
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
```

## Test on my desktop debug
```bash
$ time zig test --release-fast benchmark.zig
Test 1/15 BmNoSelf.lfence...
name repetitions:1        iterations        time    time/operation
BmNoSelf                   196000000     0.562 s       2.867 ns/op
BmNoSelf                   196000000     0.562 s       2.867 ns/op mean
BmNoSelf                   196000000     0.562 s       2.867 ns/op median
BmNoSelf                   196000000     0.000 s       0.000 ns/op stddev
OK
Test 2/15 BmSelf.sfence...
name repetitions:1        iterations        time    time/operation
BmSelf                     384160000     0.645 s       1.679 ns/op
BmSelf                     384160000     0.645 s       1.679 ns/op mean
BmSelf                     384160000     0.645 s       1.679 ns/op median
BmSelf                     384160000     0.000 s       0.000 ns/op stddev
OK
Test 3/15 BmSelf.mfence.init...
name repetitions:1        iterations        time    time/operation
BmEmpty.error               53782400     0.527 s       9.801 ns/op
BmEmpty.error               53782400     0.527 s       9.801 ns/op mean
BmEmpty.error               53782400     0.527 s       9.801 ns/op median
BmEmpty.error               53782400     0.000 s       0.000 ns/op stddev
OK
Test 4/15 BmSelf.init.setup...
name repetitions:3        iterations        time    time/operation
BmEmpty.error           100000000000     0.000 s       0.000 ns/op
BmEmpty.error           100000000000     0.000 s       0.000 ns/op
BmEmpty.error           100000000000     0.000 s       0.000 ns/op
BmEmpty.error           100000000000     0.000 s       0.000 ns/op mean
BmEmpty.error           100000000000     0.000 s       0.000 ns/op median
BmEmpty.error           100000000000     0.000 s       0.000 ns/op stddev
OK
Test 5/15 BmSelf.init.setup.tearDown.AtomicRmwOp.Add...
name repetitions:10       iterations        time    time/operation
BmEmpty.error              105413504     0.560 s       5.316 ns/op
BmEmpty.error              105413504     0.561 s       5.326 ns/op
BmEmpty.error              105413504     0.560 s       5.316 ns/op
BmEmpty.error              105413504     0.562 s       5.328 ns/op
BmEmpty.error              105413504     0.562 s       5.332 ns/op
BmEmpty.error              105413504     0.561 s       5.325 ns/op
BmEmpty.error              105413504     0.563 s       5.338 ns/op
BmEmpty.error              105413504     0.561 s       5.323 ns/op
BmEmpty.error              105413504     0.563 s       5.341 ns/op
BmEmpty.error              105413504     0.561 s       5.320 ns/op
BmEmpty.error              105413504     0.561 s       5.326 ns/op mean
BmEmpty.error              105413504     0.561 s       5.325 ns/op median
BmEmpty.error              105413504     0.001 s       0.009 ns/op stddev
OK
Test 6/15 BmAdd...
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
Test 7/15 BmAdd.Acquire.Release...
name repetitions:10       iterations        time    time/operation
BmAdd                    14000000000     0.505 s       0.036 ns/op
BmAdd                    14000000000     0.551 s       0.039 ns/op
BmAdd                    14000000000     0.557 s       0.040 ns/op
BmAdd                    14000000000     0.527 s       0.038 ns/op
BmAdd                    14000000000     0.517 s       0.037 ns/op
BmAdd                    14000000000     0.512 s       0.037 ns/op
BmAdd                    14000000000     0.527 s       0.038 ns/op
BmAdd                    14000000000     0.510 s       0.036 ns/op
BmAdd                    14000000000     0.563 s       0.040 ns/op
BmAdd                    14000000000     0.523 s       0.037 ns/op
BmAdd                    14000000000     0.529 s       0.038 ns/op mean
BmAdd                    14000000000     0.525 s       0.037 ns/op median
BmAdd                    14000000000     0.021 s       0.001 ns/op stddev
OK
Test 8/15 BmAdd.lfence.sfence...
name repetitions:10       iterations        time    time/operation
BmAdd                      140000000     0.608 s       4.346 ns/op
BmAdd                      140000000     0.609 s       4.347 ns/op
BmAdd                      140000000     0.608 s       4.343 ns/op
BmAdd                      140000000     0.608 s       4.343 ns/op
BmAdd                      140000000     0.607 s       4.338 ns/op
BmAdd                      140000000     0.607 s       4.336 ns/op
BmAdd                      140000000     0.609 s       4.348 ns/op
BmAdd                      140000000     0.607 s       4.339 ns/op
BmAdd                      140000000     0.608 s       4.344 ns/op
BmAdd                      140000000     0.609 s       4.348 ns/op
BmAdd                      140000000     0.608 s       4.343 ns/op mean
BmAdd                      140000000     0.608 s       4.344 ns/op median
BmAdd                      140000000     0.001 s       0.004 ns/op stddev
OK
Test 9/15 BmAdd.volatile...
name repetitions:10       iterations        time    time/operation
BmAdd                     1960000000     0.558 s       0.284 ns/op
BmAdd                     1960000000     0.557 s       0.284 ns/op
BmAdd                     1960000000     0.556 s       0.284 ns/op
BmAdd                     1960000000     0.558 s       0.285 ns/op
BmAdd                     1960000000     0.556 s       0.283 ns/op
BmAdd                     1960000000     0.557 s       0.284 ns/op
BmAdd                     1960000000     0.556 s       0.283 ns/op
BmAdd                     1960000000     0.557 s       0.284 ns/op
BmAdd                     1960000000     0.557 s       0.284 ns/op
BmAdd                     1960000000     0.559 s       0.285 ns/op
BmAdd                     1960000000     0.557 s       0.284 ns/op mean
BmAdd                     1960000000     0.557 s       0.284 ns/op median
BmAdd                     1960000000     0.001 s       0.001 ns/op stddev
OK
Test 10/15 BmNoSelf.error...
OK
Test 11/15 BmSelf.init_error.setup.tearDown...
OK
Test 12/15 BmSelf.init.setup_error.tearDown...
OK
Test 13/15 BmSelf.init.setup.tearDown_error...
OK
Test 14/15 BmSelf.init.setup.tearDown.benchmark_error...
OK
Test 15/15 BmSelf.no_init.no_setup.no_tearDown.benchmark_error...
OK
All tests passed.

real	0m40.472s
user	0m40.347s
sys	0m0.090s
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
