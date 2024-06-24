(ns powersync.repl
  (:require [cheshire.core :as json]
            [powersync
             [cli :as cli]
             [client :as client]
             [powersync :as powersync]
             [sqlite3 :as sqlite3]
             [workload :as workload]]))

(def powersync_endpoint
  "http://localhost:8989/sql-txn")

(def sample-op
  {:type :invoke
   :f    :txn
   :value [[:r 0 nil]
           [:append 0 0]
           [:r 0 nil]
           [:append 0 1]
           [:r 0 nil]]})
