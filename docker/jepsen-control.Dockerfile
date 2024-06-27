#
# Custom PowerSync control
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-control AS jepsen-control

# Causal Consistency checker
WORKDIR /jepsen
RUN git clone -b main --depth 1 --single-branch https://github.com/nurturenature/jepsen-causal-consistency.git
WORKDIR /jepsen/jepsen-causal-consistency
RUN lein install

# PowerSync tests
WORKDIR /jepsen/jepsen-powersync

# caching layer for deps
COPY ./project.clj .
RUN lein deps

# build tests
COPY ./src ./src
RUN lein deps
RUN lein compile
