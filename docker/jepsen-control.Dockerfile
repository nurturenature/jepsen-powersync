#
# Custom PowerSync control
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-control AS jepsen-control

WORKDIR /jepsen/jepsen-powersync

# caching layer for deps
COPY ./project.clj .
RUN lein deps

COPY ./src ./src

RUN lein compile
RUN lein deps
