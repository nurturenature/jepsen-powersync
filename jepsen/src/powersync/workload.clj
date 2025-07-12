(ns powersync.workload
  (:require [causal.checker.mww
             [causal-consistency :refer [causal-consistency]]
             [strong-convergence :refer [strong-convergence]]]
            [clojure.set :as set]
            [jepsen
             [checker :as checker]
             [generator :as gen]]
            [powersync
             [client :as client]
             [powersync :as ps]]))

(defn nodes->processes
  "Given a collection of nodes, returns a set of processes.
   TODO: use test context"
  [nodes]
  (->> nodes
       (map #(subs % 1))
       (map parse-long)
       (map #(- % 1))
       (into #{})))

(defn readAll-writeSome-generator
  "A generator of [[:readAll nil {}] [:writeSome nil {k v}]] transactions."
  [{:keys [key-count keys-txn] :as _opts}]
  (let [all-keys (->> key-count range (into #{}))]
    (->> (range)
         (map (fn [n]
                (let [write-keys (->> all-keys shuffle (take keys-txn))
                      write-some (->> write-keys
                                      (map (fn [k] [k n]))
                                      (into {}))]
                  {:type  :invoke
                   :f     :txn
                   :value [[:readAll   nil {}]
                           [:writeSome nil write-some]]}))))))

(defn readAll-generator
  "A generator of [[:readAll nil {}] [:writeSome nil {}]] transactions."
  [_opts]
  (repeat {:type  :invoke
           :f     :txn
           :value [[:readAll nil {}] [:writeSome nil {}]]}))

(defn readAll-final-generator
  "final-generator that readAll on all clients."
  [opts]
  (gen/phases
   (gen/log "Quiesce 3s...")
   (gen/sleep 3)
   (gen/log "Final reads...")
   (->> (readAll-generator opts)
        (gen/map (fn [op] (assoc op
                                 :f           :r-final
                                 :final-read? true)))
        (gen/once)
        (gen/each-thread)
        (gen/clients))))

(defn ps-rw-pg-rw
  "A PowerSync read/write, PostgreSQL read/write workload."
  [opts]
  {:db              (ps/db)
   :client          (client/->PowerSyncClient nil)
   :generator       (readAll-writeSome-generator opts)
   :final-generator (readAll-final-generator opts)
   :checker         (checker/compose
                     {:causal-consistency (causal-consistency opts)
                      :strong-convergence (strong-convergence opts)})})

(defn convergence
  "A ps-rw-pg-rw workload that only checks for strong convergence."
  [opts]
  (merge (ps-rw-pg-rw opts)
         {:checker (checker/compose
                    {:strong-convergence (strong-convergence opts)})}))

(defn ps-ro-pg-rw
  "A PowerSync doing reads only, PostgreSQL doing reads/writes, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (ps-rw-pg-rw opts)
     {:generator (gen/mix
                  [; PowerSync
                   (gen/on-threads ps-processes
                                   (readAll-generator opts))

                   ; PostgreSQL
                   (gen/on-threads pg-processes
                                   (readAll-writeSome-generator opts))])})))

(defn ps-rw-pg-ro
  "A PowerSync doing reads and writes, PostgreSQL doing reads only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (ps-rw-pg-rw opts)
     {:generator (gen/mix
                  [; PostgreSQL - read only
                   (->> (readAll-generator opts)
                        (gen/on-threads pg-processes))

                   ; PowerSync - read write
                   (->> (readAll-writeSome-generator opts)
                        (gen/on-threads ps-processes))])})))

