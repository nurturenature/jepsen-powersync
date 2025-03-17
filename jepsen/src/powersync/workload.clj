(ns powersync.workload
  (:require [causal.checker
             [adya :as adya]
             [opts :as causal-opts]
             [strong-convergence :as strong-convergence]]
            [clojure.set :as set]
            [jepsen
             [checker :as checker]
             [generator :as gen]]
            [powersync
             [client :as client]
             [powersync :as ps]
             [sqlite3 :as sqlite3]]))

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
  "A generator of [[:readAll nil {}]] transactions."
  [_opts]
  (repeat {:type  :invoke
           :f     :txn
           :value [[:readAll nil {}]]}))

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

(defn writeSome-generator
  "A generator of [[:writeSome nil {k v}]] transactions."
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
                   :value [[:writeSome nil write-some]]}))))))

(defn ps-rw-pg-rw
  "A PowerSync read/write, PostgreSQL read/write workload."
  [opts]
  (let [opts (merge causal-opts/causal-opts opts)] ; TODO: confirm consistent overriding of causal-opts

    {:db              (ps/db)
     :client          (client/->PowerSyncClient nil)
     :generator       (readAll-writeSome-generator opts)
     :final-generator (readAll-final-generator opts)
     :checker         (checker/compose
                       {:causal-consistency (adya/checker opts)
                        :strong-convergence (strong-convergence/final-reads
                                             (assoc opts :directory "strong-convergence"))})}))

(defn convergence
  "A ps-rw-pg-rw workload that only checks for strong convergence."
  [opts]
  (merge (ps-rw-pg-rw opts)
         {:checker (checker/compose
                    {:strong-convergence (strong-convergence/final-reads
                                          (assoc opts :directory "strong-convergence"))})}))

(defn ps-ro-pg-wo
  "A PowerSync doing reads only, PostgreSQL doing writes only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (ps-rw-pg-rw opts)
     {:generator (gen/mix
                  [; PostgreSQL
                   (gen/on-threads pg-processes
                                   (writeSome-generator opts))
                   ; PowerSync
                   (gen/on-threads ps-processes
                                   (readAll-generator opts))])})))

(defn ps-wo-pg-ro
  "A PowerSync doing writes only, PostgreSQL doing reads only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (ps-rw-pg-rw opts)
     {:generator (gen/mix
                  [; PostgreSQL
                   (gen/on-threads pg-processes
                                   (readAll-generator opts))
                   ; PowerSync
                   (gen/on-threads ps-processes
                                   (writeSome-generator opts))])})))

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

(defn sqlite3-local
  "A local SQLite3, single user, workload."
  [opts]
  (let [ps-workload (ps-rw-pg-rw opts)]
    (merge
     ps-workload
     {:db              (sqlite3/db)})))

(defn sqlite3-local-noop
  "A no-op workload."
  [opts]
  (let [ps-workload (ps-rw-pg-rw opts)]
    (merge
     ps-workload
     {:db      (sqlite3/db)
      :client  (client/->PowerSyncClientNOOP nil)
      :checker (checker/compose
                {:unbridled-optimism (checker/unbridled-optimism)})})))
