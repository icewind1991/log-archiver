FROM ekidd/rust-musl-builder AS build

COPY Cargo.toml Cargo.lock ./

# Build with a dummy main to pre-build dependencies
RUN mkdir src && \
 echo "fn main(){}" > src/main.rs && \
 cargo build --release && \
 rm -r src

COPY src/ ./src/
COPY sqlx-data.json ./
RUN sudo chown -R rust:rust .

RUN cargo build --release

FROM scratch

COPY --from=build /home/rust/src/target/x86_64-unknown-linux-musl/release/log-archiver /

CMD ["/log-archiver"]