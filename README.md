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
iterations:1 runtime:0.000s ns/op:96.000ns
iterations:1000 runtime:0.000s ns/op:1.828ns
iterations:10000 runtime:0.000s ns/op:1.683ns
iterations:100000 runtime:0.000s ns/op:1.676ns
iterations:1000000 runtime:0.002s ns/op:1.668ns
iterations:10000000 runtime:0.013s ns/op:1.286ns
iterations:100000000 runtime:0.061s ns/op:0.611ns
iterations:140000000 runtime:0.085s ns/op:0.610ns
iterations:196000000 runtime:0.114s ns/op:0.580ns
iterations:274400000 runtime:0.155s ns/op:0.565ns
iterations:384160000 runtime:0.217s ns/op:0.565ns
iterations:537824000 runtime:0.304s ns/op:0.565ns
iterations:752953600 runtime:0.426s ns/op:0.566ns
iterations:1054135040 runtime:0.598s ns/op:0.568ns
iterations:1054135040 runtime:0.598s ns/op:0.568ns
OK
All tests passed.

real	0m6.508s
user	0m6.390s
sys	0m0.103s

$ objdump --source -d -M intel ./zig-cache/test > benchmark.fast.asm
```

Below is the loop in asm, it's generally a good idea to look
at the generated assembler code so you get "know" what is
being measured. Because of great optimization zig & llvm do
it may not be what you expect.
```
        while (iter > 0) : (iter -= 1) {
  208a53:	4d 85 ff             	test   r15,r15
  208a56:	0f 84 1e 01 00 00    	je     208b7a <benchmark.add+0x5aa>
            //lfence();
            //@fence(AtomicOrder.Acquire); // Generates no type of fence, expected lfence
            var pA: *volatile u64 = &pSelf.a;
            var pB: *volatile u64 = &pSelf.b;
            var pR: *volatile u128 = &pSelf.r;
            pR.* = u128(pA.*) + u128(pB.*);
  208a5c:	49 8d 4f ff          	lea    rcx,[r15-0x1]
  208a60:	4c 89 fa             	mov    rdx,r15
  208a63:	4c 89 f8             	mov    rax,r15
  208a66:	48 83 e2 07          	and    rdx,0x7
  208a6a:	74 37                	je     208aa3 <benchmark.add+0x4d3>
  208a6c:	48 f7 da             	neg    rdx
  208a6f:	4c 89 f8             	mov    rax,r15
  208a72:	66 66 66 66 66 2e 0f 	data16 data16 data16 data16 nop WORD PTR cs:[rax+rax*1+0x0]
  208a79:	1f 84 00 00 00 00 00 
  208a80:	48 8b 74 24 08       	mov    rsi,QWORD PTR [rsp+0x8]
  208a85:	31 ff                	xor    edi,edi
  208a87:	48 03 34 24          	add    rsi,QWORD PTR [rsp]
  208a8b:	40 0f 92 c7          	setb   dil
  208a8f:	48 89 74 24 10       	mov    QWORD PTR [rsp+0x10],rsi
  208a94:	48 89 7c 24 18       	mov    QWORD PTR [rsp+0x18],rdi
        while (iter > 0) : (iter -= 1) {
  208a99:	48 83 c0 ff          	add    rax,0xffffffffffffffff
  208a9d:	48 83 c2 01          	add    rdx,0x1
  208aa1:	75 dd                	jne    208a80 <benchmark.add+0x4b0>
            pR.* = u128(pA.*) + u128(pB.*);
  208aa3:	48 83 f9 07          	cmp    rcx,0x7
  208aa7:	0f 82 cd 00 00 00    	jb     208b7a <benchmark.add+0x5aa>
  208aad:	0f 1f 00             	nop    DWORD PTR [rax]
  208ab0:	48 8b 4c 24 08       	mov    rcx,QWORD PTR [rsp+0x8]
  208ab5:	31 d2                	xor    edx,edx
  208ab7:	48 03 0c 24          	add    rcx,QWORD PTR [rsp]
  208abb:	0f 92 c2             	setb   dl
  208abe:	48 89 4c 24 10       	mov    QWORD PTR [rsp+0x10],rcx
  208ac3:	48 89 54 24 18       	mov    QWORD PTR [rsp+0x18],rdx
  208ac8:	31 c9                	xor    ecx,ecx
  208aca:	48 8b 54 24 08       	mov    rdx,QWORD PTR [rsp+0x8]
  208acf:	48 03 14 24          	add    rdx,QWORD PTR [rsp]
  208ad3:	48 89 54 24 10       	mov    QWORD PTR [rsp+0x10],rdx
  208ad8:	0f 92 c1             	setb   cl
  208adb:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
  208ae0:	48 8b 4c 24 08       	mov    rcx,QWORD PTR [rsp+0x8]
  208ae5:	31 d2                	xor    edx,edx
  208ae7:	48 03 0c 24          	add    rcx,QWORD PTR [rsp]
  208aeb:	0f 92 c2             	setb   dl
  208aee:	48 89 4c 24 10       	mov    QWORD PTR [rsp+0x10],rcx
  208af3:	48 89 54 24 18       	mov    QWORD PTR [rsp+0x18],rdx
  208af8:	48 8b 4c 24 08       	mov    rcx,QWORD PTR [rsp+0x8]
  208afd:	31 d2                	xor    edx,edx
  208aff:	48 03 0c 24          	add    rcx,QWORD PTR [rsp]
  208b03:	0f 92 c2             	setb   dl
  208b06:	48 89 4c 24 10       	mov    QWORD PTR [rsp+0x10],rcx
  208b0b:	48 89 54 24 18       	mov    QWORD PTR [rsp+0x18],rdx
  208b10:	31 c9                	xor    ecx,ecx
  208b12:	48 8b 54 24 08       	mov    rdx,QWORD PTR [rsp+0x8]
  208b17:	48 03 14 24          	add    rdx,QWORD PTR [rsp]
  208b1b:	48 89 54 24 10       	mov    QWORD PTR [rsp+0x10],rdx
  208b20:	0f 92 c1             	setb   cl
  208b23:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
  208b28:	48 8b 4c 24 08       	mov    rcx,QWORD PTR [rsp+0x8]
  208b2d:	31 d2                	xor    edx,edx
  208b2f:	48 03 0c 24          	add    rcx,QWORD PTR [rsp]
  208b33:	0f 92 c2             	setb   dl
  208b36:	48 89 4c 24 10       	mov    QWORD PTR [rsp+0x10],rcx
  208b3b:	48 89 54 24 18       	mov    QWORD PTR [rsp+0x18],rdx
  208b40:	48 8b 4c 24 08       	mov    rcx,QWORD PTR [rsp+0x8]
  208b45:	31 d2                	xor    edx,edx
  208b47:	48 03 0c 24          	add    rcx,QWORD PTR [rsp]
  208b4b:	0f 92 c2             	setb   dl
  208b4e:	48 89 4c 24 10       	mov    QWORD PTR [rsp+0x10],rcx
  208b53:	48 89 54 24 18       	mov    QWORD PTR [rsp+0x18],rdx
  208b58:	31 c9                	xor    ecx,ecx
  208b5a:	48 8b 54 24 08       	mov    rdx,QWORD PTR [rsp+0x8]
  208b5f:	48 03 14 24          	add    rdx,QWORD PTR [rsp]
  208b63:	48 89 54 24 10       	mov    QWORD PTR [rsp+0x10],rdx
  208b68:	0f 92 c1             	setb   cl
        while (iter > 0) : (iter -= 1) {
  208b6b:	48 83 c0 f8          	add    rax,0xfffffffffffffff8
            pR.* = u128(pA.*) + u128(pB.*);
  208b6f:	48 89 4c 24 18       	mov    QWORD PTR [rsp+0x18],rcx
        while (iter > 0) : (iter -= 1) {
  208b74:	0f 85 36 ff ff ff    	jne    208ab0 <benchmark.add+0x4e0>
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
