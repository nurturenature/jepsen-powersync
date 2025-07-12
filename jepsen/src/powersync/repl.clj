(ns powersync.repl
  (:require [causal.checker
             [adya :as adya]
             [opts :as causal-opts]
             [strong-convergence :as strong-convergence]]
            [causal.checker.mww
             [causal-consistency :refer [causal-consistency]]
             [stats :refer [completions-by-node]]
             [strong-convergence :refer [strong-convergence]]
             [util :as util]]
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
             [workload :as workload]]))

(def powersync_endpoint
  "http://localhost:8989/sql-txn")

