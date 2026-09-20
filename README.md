### Zig Web Framework Benchmark

This is a benchmark suite for Zig web server libraries.

### Prerequisites

- Docker (for Docker mode)
- Zig compiler (0.17+ for the site / host orchestrator)

### Running the benchmarks

```bash
zig build run -- httpz zap          # frameworks only
BENCH_PLATFORM=linux-x86_64 zig build run
```

Results are written to `app/results.zon` (imported by the site).

### Server Libraries

- [Zig Standard Library HTTP Server](https://github.com/ziglang/zig)
- [Zap](https://github.com/zigzap/zap)
- [HTTPz](https://github.com/karlseguin/http.zig)
- [zzz](https://github.com/tardy-org/zzz)
- [Zinc](https://github.com/zon-dev/zinc/)

