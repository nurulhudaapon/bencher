ARG ZIG_VER=0.16.0

FROM debian:12-slim AS build
ARG ZIG_VER
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN ARCH="$(uname -m)" \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-${ARCH}-linux-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-${ARCH}-linux-${ZIG_VER} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /app
COPY frameworks/shared frameworks/shared
COPY frameworks/zap frameworks/zap

WORKDIR /app/frameworks/zap
RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline \
    && test -x zig-out/bin/bench_zap

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/frameworks/zap/zig-out/bin/bench_zap /bin/framework
EXPOSE 8081
HEALTHCHECK --interval=1s --timeout=2s --retries=30 --start-period=2s \
    CMD curl -fsS "http://127.0.0.1:8081/httpz" >/dev/null || exit 1
ENTRYPOINT ["/bin/framework"]
