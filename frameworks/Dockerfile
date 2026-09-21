# Shared framework image. Build args: FRAMEWORK, BINARY [, ZIG_VER]
ARG ZIG_VER=0.16.0
ARG FRAMEWORK
ARG BINARY

FROM alpine:3.22 AS build
ARG ZIG_VER
ARG FRAMEWORK
ARG BINARY
RUN apk add --no-cache curl xz \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz" \
        | tar -xJ -C /opt \
    && mv /opt/zig-$(uname -m)-linux-${ZIG_VER} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build
COPY frameworks/shared frameworks/shared
COPY frameworks/${FRAMEWORK} frameworks/${FRAMEWORK}

WORKDIR /build/frameworks/${FRAMEWORK}
RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget=$(uname -m)-linux-musl \
    && test -x "zig-out/bin/${BINARY}"

FROM alpine:3.22
ARG FRAMEWORK
ARG BINARY
COPY --from=build /build/frameworks/${FRAMEWORK}/zig-out/bin/${BINARY} /bin/framework
EXPOSE 8081
ENTRYPOINT ["/bin/framework"]
