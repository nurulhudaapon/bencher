# Zig 0.16 load-generator image (zrk). Built as zig_web_bench-bencher.
ARG ZIG_VER=0.16.0

FROM debian:12-slim AS build
ARG ZIG_VER
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN ARCH="$(uname -m)" \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-${ARCH}-linux-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-${ARCH}-linux-${ZIG_VER} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /build
COPY bench/runner/build.zig bench/runner/build.zig.zon bench/runner/
COPY bench/runner/src bench/runner/src
WORKDIR /build/bench/runner
RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/bench/runner/zig-out/bin/bencher /bin/bencher
COPY bench/runner/src/benchfig.zon /bench/benchfig.zon
WORKDIR /bench
VOLUME ["/out"]
ENTRYPOINT ["/bin/bencher"]
CMD ["/out/results.zon"]
