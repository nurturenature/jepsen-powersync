(ns powersync.repl
  (:require [causal.checker
             [adya :as adya]
             [opts :as causal-opts]
             [strong-convergence :as strong-convergence]]
            [cheshire.core :as json]
            [jepsen
             [checker :as checker]
             [history :as h]
             [store :as store]]
            [powersync
             [cli :as cli]
             [client :as client]
             [nemesis :as nemesis]
             [powersync :as powersync]
             [util :as util]
             [workload :as workload]]
            [powersync.checker.stats :refer [completions-by-node]]
            [powersync.checker.strong-convergence :refer [strong-convergence]]
            [powersync.checker.causal-consistency :refer [causal-consistency]]))

(def powersync_endpoint
  "http://localhost:8989/sql-txn")

