# Zig 0.16 load-generator image (zrk). Built as zig_web_bench-bencher.
ARG ZIG_VER=0.16.0

FROM alpine:3.22 AS build
ARG ZIG_VER
RUN apk add --no-cache curl xz git \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz" \
        | tar -xJ -C /opt \
    && mv /opt/zig-$(uname -m)-linux-${ZIG_VER} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build
COPY bench/runner/build.zig bench/runner/build.zig.zon bench/runner/
COPY bench/runner/src bench/runner/src
WORKDIR /build/bench/runner
RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget=$(uname -m)-linux-musl

FROM alpine:3.22
COPY --from=build /build/bench/runner/zig-out/bin/bencher /bin/bencher
COPY bench/runner/src/benchfig.zon /bench/benchfig.zon
WORKDIR /bench
VOLUME ["/out"]
ENTRYPOINT ["/bin/bencher"]
CMD ["/out/results.zon"]
