ARG CACHE_BUST=9
ARG ZIG_VER=0.17.0-dev.2131+d08989840

FROM alpine:3.22 AS build
ARG ZIG_VER
ARG CACHE_BUST
RUN apk add --no-cache curl xz patch \
    && echo "cache_bust=${CACHE_BUST}"
# 0.17.0-dev builds live under /builds/; stable releases under /download/.
RUN curl -fsSL "https://ziglang.org/builds/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz" \
        | tar -xJ -C /opt \
    && mv /opt/zig-$(uname -m)-linux-${ZIG_VER} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /app
COPY frameworks/shared frameworks/shared
COPY frameworks/zinc frameworks/zinc

# Populate deps/{aio,url,zinc}: zinc release pulls aio/url as URL deps; we
# rewrite them to sibling path deps so aio can be patched for Zig 0.17 Linux.
WORKDIR /app/frameworks/zinc
ARG ZINC_REF=0.3.0-beta.1
ARG AIO_REF=0.2.0-alpha.2
ARG URL_REF=0.2.0-alpha.2
RUN set -eux; \
    rm -rf deps; \
    mkdir -p deps; \
    curl -fsSL "https://github.com/zon-dev/aio/archive/refs/tags/${AIO_REF}.tar.gz" | tar -xz -C deps; \
    mv "deps/aio-${AIO_REF}" deps/aio; \
    curl -fsSL "https://github.com/zon-dev/url/archive/refs/tags/${URL_REF}.tar.gz" | tar -xz -C deps; \
    mv "deps/url-${URL_REF}" deps/url; \
    curl -fsSL "https://github.com/zon-dev/zinc/archive/refs/tags/${ZINC_REF}.tar.gz" | tar -xz -C deps; \
    mv "deps/zinc-${ZINC_REF}" deps/zinc; \
    printf '%s\n' \
      '.{' \
      '    .name = .zinc,' \
      '    .version = "0.3.0-beta.1",' \
      '    .fingerprint = 0x4d051980cd34bdb8,' \
      '    .minimum_zig_version = "0.16.0",' \
      '    .dependencies = .{' \
      '        .url = .{' \
      '            .path = "../url",' \
      '        },' \
      '        .aio = .{' \
      '            .path = "../aio",' \
      '        },' \
      '    },' \
      '    .paths = .{' \
      '        "src",' \
      '        "LICENSE",' \
      '        "README.md",' \
      '        "build.zig",' \
      '        "build.zig.zon",' \
      '    },' \
      '}' > deps/zinc/build.zig.zon; \
    patch -p1 -d deps/aio < patches/aio-zig017.patch; \
    if [ -f patches/zinc-zig017-compat.patch ]; then patch -p1 -d deps/zinc < patches/zinc-zig017-compat.patch; fi; \
    if [ -f patches/zinc-close-after-write.patch ]; then patch -p1 -d deps/zinc < patches/zinc-close-after-write.patch; fi

RUN zig build -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget=$(uname -m)-linux-musl \
    && test -x zig-out/bin/bench_zinc

FROM alpine:3.22
COPY --from=build /app/frameworks/zinc/zig-out/bin/bench_zinc /bin/framework
EXPOSE 8081
ENTRYPOINT ["/bin/framework"]
