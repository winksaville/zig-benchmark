# Zig benchmark

Explore how to make a micro benchmark. It's kinda
working but when building with --release-fast it
appears there is only a single iteration.

## Test on my desktop debug
```bash
$ time zig test benchmark.zig 
Test 1/1 benchmark.add...runIterations: iteratons=1
runIterations:- iteratons=1
run_time=2405 min_runtime_ns=500000000
iteratons:10 numer:10 denom:1
runIterations: iteratons=10
runIterations:- iteratons=10
run_time=5194 min_runtime_ns=500000000
iteratons:100 numer:10 denom:1
runIterations: iteratons=100
runIterations:- iteratons=100
run_time=4724 min_runtime_ns=500000000
iteratons:1000 numer:10 denom:1
runIterations: iteratons=1000
runIterations:- iteratons=1000
run_time=9240 min_runtime_ns=500000000
iteratons:10000 numer:10 denom:1
runIterations: iteratons=10000
runIterations:- iteratons=10000
run_time=45070 min_runtime_ns=500000000
iteratons:100000 numer:10 denom:1
runIterations: iteratons=100000
runIterations:- iteratons=100000
run_time=422225 min_runtime_ns=500000000
iteratons:1000000 numer:10 denom:1
runIterations: iteratons=1000000
runIterations:- iteratons=1000000
run_time=4029723 min_runtime_ns=500000000
iteratons:10000000 numer:10 denom:1
runIterations: iteratons=10000000
runIterations:- iteratons=10000000
run_time=39460941 min_runtime_ns=500000000
iteratons:100000000 numer:10 denom:1
runIterations: iteratons=100000000
runIterations:- iteratons=100000000
run_time=382739125 min_runtime_ns=500000000
iteratons:140000000 numer:14 denom:10
runIterations: iteratons=140000000
runIterations:- iteratons=140000000
run_time=539442031 min_runtime_ns=500000000
done
iterations:140000000 runtime:539442031
OK
All tests passed.

real	0m1.493s
user	0m1.436s
sys	0m0.046s
```

## Test on my desktop release-fast

Notice at max iterations only takes 3452 which
is the about the same time as 1 iteration. So
it looks like zig/llvm is optimizing away the
loop!!!

```bash
$ time zig test --release-fast benchmark.zig 
Test 1/1 benchmark.add...runIterations: iteratons=1
runIterations:- iteratons=1
run_time=3205 min_runtime_ns=500000000
iteratons:10 numer:10 denom:1
runIterations: iteratons=10
runIterations:- iteratons=10
run_time=4465 min_runtime_ns=500000000
iteratons:100 numer:10 denom:1
runIterations: iteratons=100
runIterations:- iteratons=100
run_time=3885 min_runtime_ns=500000000
iteratons:1000 numer:10 denom:1
runIterations: iteratons=1000
runIterations:- iteratons=1000
run_time=3835 min_runtime_ns=500000000
iteratons:10000 numer:10 denom:1
runIterations: iteratons=10000
runIterations:- iteratons=10000
run_time=4088 min_runtime_ns=500000000
iteratons:100000 numer:10 denom:1
runIterations: iteratons=100000
runIterations:- iteratons=100000
run_time=4991 min_runtime_ns=500000000
iteratons:1000000 numer:10 denom:1
runIterations: iteratons=1000000
runIterations:- iteratons=1000000
run_time=3750 min_runtime_ns=500000000
iteratons:10000000 numer:10 denom:1
runIterations: iteratons=10000000
runIterations:- iteratons=10000000
run_time=4283 min_runtime_ns=500000000
iteratons:100000000 numer:10 denom:1
runIterations: iteratons=100000000
runIterations:- iteratons=100000000
run_time=3581 min_runtime_ns=500000000
iteratons:1000000000 numer:10 denom:1
runIterations: iteratons=1000000000
runIterations:- iteratons=1000000000
run_time=4071 min_runtime_ns=500000000
iteratons:10000000000 numer:10 denom:1
runIterations: iteratons=10000000000
runIterations:- iteratons=10000000000
run_time=3452 min_runtime_ns=500000000
iteratons:100000000000 numer:10 denom:1
iterations:100000000000 runtime:3452
OK
All tests passed.

real	0m3.313s
user	0m3.243s
sys	0m0.055s
```

## Clean
Remove `zig-cache/` directory
```bash
$ rm -rf ./zig-cache/
```
