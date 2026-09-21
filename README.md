### Zig Web Server Libraries Benchmark

Benchmarks Zig web server libraries for performance.

### Run

```bash
bash bench/run.sh              # all frameworks
bash bench/run.sh httpz zap    # specific frameworks
```

Results will be written to `app/results.zon`.

### Adding new benchmarks

1. Create `frameworks/<name>/` that has endpoints similar to an existing one like.
2. Put catalog metadata in `build.zig.zon` under `.meta` following existing examples.  
3. Add `<name>` to `.frameworks` in `bench/runner/src/benchfig.zon`.
4. Regenerate compose and commit it: `bash bench/run.sh --write-compose`
5. Smoke-test: `bash bench/run.sh <name>`
