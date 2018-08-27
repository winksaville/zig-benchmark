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
    var bf = BenchmarkFramework.init(std.debug.global_allocator);
    //bf.min_runtime_ns = ns_per_s * 3;
    bf.logl = 0;
    bf.repetitions = 10;

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
name repetitions:10   iterations        time   time/iterations
add                   1054135040     0.595 s       0.564 ns/op
add                   1054135040     0.596 s       0.565 ns/op
add                   1054135040     0.594 s       0.563 ns/op
add                   1054135040     0.595 s       0.564 ns/op
add                   1054135040     0.594 s       0.563 ns/op
add                   1054135040     0.594 s       0.563 ns/op
add                   1054135040     0.594 s       0.563 ns/op
add                   1054135040     0.592 s       0.562 ns/op
add                   1054135040     0.595 s       0.565 ns/op
add                   1054135040     0.594 s       0.563 ns/op
add                   1054135040     0.594 s       0.564 ns/op mean
add                   1054135040     0.594 s       0.563 ns/op median
add                   1054135040     0.001 s       0.001 ns/op stddev
OK
All tests passed.

real	0m17.206s
user	0m17.090s
sys	0m0.093s

$ objdump --source -d -M intel ./zig-cache/test > benchmark.fast.asm
```

Below is the loop in asm, it's generally a good idea to look
at the generated assembler code so you get "know" what is
being measured. Because of great optimization zig & llvm do
it may not be what you expect.
```
        while (iter > 0) : (iter -= 1) {
  20affc:	4d 85 ff             	test   r15,r15
  20afff:	0f 84 8d 01 00 00    	je     20b192 <benchmark.add+0x952>
            pR.* = u128(pA.*) + u128(pB.*);
  20b005:	49 8d 4f ff          	lea    rcx,[r15-0x1]
  20b009:	4c 89 fa             	mov    rdx,r15
  20b00c:	4c 89 f8             	mov    rax,r15
  20b00f:	48 83 e2 07          	and    rdx,0x7
  20b013:	74 3b                	je     20b050 <benchmark.add+0x810>
  20b015:	48 f7 da             	neg    rdx
  20b018:	4c 89 f8             	mov    rax,r15
  20b01b:	0f 1f 44 00 00       	nop    DWORD PTR [rax+rax*1+0x0]
  20b020:	48 8b b4 24 10 01 00 	mov    rsi,QWORD PTR [rsp+0x110]
  20b027:	00 
  20b028:	31 ff                	xor    edi,edi
  20b02a:	48 03 b4 24 08 01 00 	add    rsi,QWORD PTR [rsp+0x108]
  20b031:	00 
  20b032:	40 0f 92 c7          	setb   dil
  20b036:	48 89 b4 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rsi
  20b03d:	00 
  20b03e:	48 89 bc 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdi
  20b045:	00 
        while (iter > 0) : (iter -= 1) {
  20b046:	48 83 c0 ff          	add    rax,0xffffffffffffffff
  20b04a:	48 83 c2 01          	add    rdx,0x1
  20b04e:	75 d0                	jne    20b020 <benchmark.add+0x7e0>
            pR.* = u128(pA.*) + u128(pB.*);
  20b050:	48 83 f9 07          	cmp    rcx,0x7
  20b054:	0f 82 38 01 00 00    	jb     20b192 <benchmark.add+0x952>
  20b05a:	66 0f 1f 44 00 00    	nop    WORD PTR [rax+rax*1+0x0]
  20b060:	48 8b 8c 24 10 01 00 	mov    rcx,QWORD PTR [rsp+0x110]
  20b067:	00 
  20b068:	31 d2                	xor    edx,edx
  20b06a:	48 03 8c 24 08 01 00 	add    rcx,QWORD PTR [rsp+0x108]
  20b071:	00 
  20b072:	0f 92 c2             	setb   dl
  20b075:	48 89 8c 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rcx
  20b07c:	00 
  20b07d:	48 89 94 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdx
  20b084:	00 
  20b085:	31 c9                	xor    ecx,ecx
  20b087:	48 8b 94 24 10 01 00 	mov    rdx,QWORD PTR [rsp+0x110]
  20b08e:	00 
  20b08f:	48 03 94 24 08 01 00 	add    rdx,QWORD PTR [rsp+0x108]
  20b096:	00 
  20b097:	48 89 94 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rdx
  20b09e:	00 
  20b09f:	0f 92 c1             	setb   cl
  20b0a2:	48 89 8c 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rcx
  20b0a9:	00 
  20b0aa:	48 8b 8c 24 10 01 00 	mov    rcx,QWORD PTR [rsp+0x110]
  20b0b1:	00 
  20b0b2:	31 d2                	xor    edx,edx
  20b0b4:	48 03 8c 24 08 01 00 	add    rcx,QWORD PTR [rsp+0x108]
  20b0bb:	00 
  20b0bc:	0f 92 c2             	setb   dl
  20b0bf:	48 89 8c 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rcx
  20b0c6:	00 
  20b0c7:	48 89 94 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdx
  20b0ce:	00 
  20b0cf:	48 8b 8c 24 10 01 00 	mov    rcx,QWORD PTR [rsp+0x110]
  20b0d6:	00 
  20b0d7:	31 d2                	xor    edx,edx
  20b0d9:	48 03 8c 24 08 01 00 	add    rcx,QWORD PTR [rsp+0x108]
  20b0e0:	00 
  20b0e1:	0f 92 c2             	setb   dl
  20b0e4:	48 89 8c 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rcx
  20b0eb:	00 
  20b0ec:	48 89 94 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdx
  20b0f3:	00 
  20b0f4:	31 c9                	xor    ecx,ecx
  20b0f6:	48 8b 94 24 10 01 00 	mov    rdx,QWORD PTR [rsp+0x110]
  20b0fd:	00 
  20b0fe:	48 03 94 24 08 01 00 	add    rdx,QWORD PTR [rsp+0x108]
  20b105:	00 
  20b106:	48 89 94 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rdx
  20b10d:	00 
  20b10e:	0f 92 c1             	setb   cl
  20b111:	48 89 8c 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rcx
  20b118:	00 
  20b119:	48 8b 8c 24 10 01 00 	mov    rcx,QWORD PTR [rsp+0x110]
  20b120:	00 
  20b121:	31 d2                	xor    edx,edx
  20b123:	48 03 8c 24 08 01 00 	add    rcx,QWORD PTR [rsp+0x108]
  20b12a:	00 
  20b12b:	0f 92 c2             	setb   dl
  20b12e:	48 89 8c 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rcx
  20b135:	00 
  20b136:	48 89 94 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdx
  20b13d:	00 
  20b13e:	48 8b 8c 24 10 01 00 	mov    rcx,QWORD PTR [rsp+0x110]
  20b145:	00 
  20b146:	31 d2                	xor    edx,edx
  20b148:	48 03 8c 24 08 01 00 	add    rcx,QWORD PTR [rsp+0x108]
  20b14f:	00 
  20b150:	0f 92 c2             	setb   dl
  20b153:	48 89 8c 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rcx
  20b15a:	00 
  20b15b:	48 89 94 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rdx
  20b162:	00 
  20b163:	31 c9                	xor    ecx,ecx
  20b165:	48 8b 94 24 10 01 00 	mov    rdx,QWORD PTR [rsp+0x110]
  20b16c:	00 
  20b16d:	48 03 94 24 08 01 00 	add    rdx,QWORD PTR [rsp+0x108]
  20b174:	00 
  20b175:	48 89 94 24 18 01 00 	mov    QWORD PTR [rsp+0x118],rdx
  20b17c:	00 
  20b17d:	0f 92 c1             	setb   cl
        while (iter > 0) : (iter -= 1) {
  20b180:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
            pR.* = u128(pA.*) + u128(pB.*);
  20b184:	48 89 8c 24 20 01 00 	mov    QWORD PTR [rsp+0x120],rcx
  20b18b:	00 
        while (iter > 0) : (iter -= 1) {
  20b18c:	0f 85 ce fe ff ff    	jne    20b060 <benchmark.add+0x820>
        var ts: posix.timespec = undefined;
  20b192:	c5 f9 29 8c 24 a0 02 	vmovapd XMMWORD PTR [rsp+0x2a0],xmm1
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
