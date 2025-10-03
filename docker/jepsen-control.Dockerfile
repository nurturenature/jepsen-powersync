#
# Custom PowerSync control
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-control:bookworm AS jepsen-control

# install latest Jepsen
WORKDIR /jepsen
RUN git clone -b main --depth 1 --single-branch https://github.com/jepsen-io/jepsen.git
WORKDIR /jepsen/jepsen/jepsen
RUN lein install
WORKDIR /jepsen
RUN rm -rf jepsen

# Causal Consistency checker
WORKDIR /jepsen
RUN git clone -b main --depth 1 --single-branch https://github.com/nurturenature/jepsen-causal-consistency.git
WORKDIR /jepsen/jepsen-causal-consistency
RUN lein install
WORKDIR /jepsen
RUN rm -rf jepsen-causal-consistency

# PowerSync tests
WORKDIR /jepsen/jepsen-powersync

# caching layer for deps
COPY ./project.clj .
RUN lein deps

# build tests
COPY ./src ./src
RUN lein deps
RUN lein compile
