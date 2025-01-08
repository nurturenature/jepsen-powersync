(ns powersync.workload
  (:require [causal.checker
             [adya :as adya]
             [opts :as causal-opts]
             [strong-convergence :as strong-convergence]]
            [clojure.math :as math]
            [clojure.set :as set]
            [elle.list-append :as list-append]
            [jepsen
             [checker :as checker]
             [generator :as gen]]
            [powersync
             [client :as client]
             [powersync :as ps]
             [sqlite3 :as sqlite3]]))

(def default-key-count
  "The default total number of keys."
  100)

(def default-keys-txn
  "The default number of keys to act on in a transactions."
  10)

(defn op+
  "Given a :f and :value, creates an :invoke op."
  [f value]
  (merge {:type :invoke :f f :value value}))

(defn txn-generator
  "Given optional opts, return a generator of multi-txn ops, e.g. random writes/reads over all-keys."
  ([] (txn-generator nil))
  ([{:keys [min-txn-length max-txn-length total-key-count] :as opts}]
   (let [opts (assoc opts
                     :key-dist           :uniform
                     :key-count          (or total-key-count default-key-count)
                     :max-writes-per-key 1000
                     :min-txn-length     (or min-txn-length 4)
                     :max-txn-length     (or max-txn-length 4))]

     (list-append/gen opts))))

(defn append-generator
  "Given optional opts, return a lazy sequence of
   transactions consisting only of :append's."
  ([] (append-generator nil))
  ([{:keys [key-count total-key-count] :as _opts}]
   (let [total-key-count (or total-key-count default-key-count)
         key-count       (or key-count default-keys-txn)]
     (->> (range)
          (map (fn [v]
                 (let [append-keys (->> (range 0 total-key-count)
                                        shuffle
                                        (take key-count))
                       value (->> append-keys
                                  (mapv (fn [k]
                                          [:append k v])))]
                   (op+ :append-only value))))))))

(defn read-generator
  "Given optional opts, return a lazy sequence of
   transactions consisting only of :r's."
  ([] (read-generator nil))
  ([{:keys [key-count total-key-count] :as _opts}]
   (let [key-count       (or key-count default-keys-txn)
         total-key-count (or total-key-count default-key-count)]
     (repeatedly
      (fn [] (let [read-keys (->> (range 0 total-key-count)
                                  shuffle
                                  (take key-count))
                   value (->> read-keys
                              (mapv (fn [k]
                                      [:r k nil])))]
               (op+ :read-only value)))))))

(defn txn-final-generator
  "final-generator for txn-generator."
  [{:keys [key-count total-key-count] :as _opts}]
  (let [key-count       (or key-count default-keys-txn)
        total-key-count (or total-key-count default-key-count)]
    (gen/phases
     (gen/log "Quiesce 3s...")
     (gen/sleep 3)
     (gen/log "Final reads...")
     (->> (range 0 total-key-count)
          (partition-all key-count)
          (map (fn [ks]
                 (let [mops (->> ks
                                 (mapv (fn [k]
                                         [:r k nil])))]
                   {:type :invoke :f :r-final :value mops :final-read? true})))
          (gen/each-thread)
          (gen/clients)))))

(defn list-append-gen
  "A list-append/gen that stops at total-key-count."
  [{:keys [total-key-count] :as opts}]
  (let [total-key-count (or total-key-count default-key-count)]
    (->> (list-append/gen opts)
         (take-while (fn [{:keys [value] :as _op}]
                       (if (some (fn [[_f k _v]]
                                   (>= k total-key-count))
                                 value)
                         false
                         true))))))

(defn list-append-checker
  "Uses elle/list-append checker."
  [defaults]
  (reify checker/Checker
    (check [_this _test history opts]
      (let [opts (merge defaults opts)]
        (list-append/check opts history)))))

(defn nodes->processes
  [nodes]
  (->> nodes
       (map #(subs % 1))
       (map parse-long)
       (map #(- % 1))
       (into #{})))

(defn powersync
  "A PowerSync workload."
  [{:keys [rate time-limit] :as opts}]
  (let [opts (-> opts
                 (merge causal-opts/causal-opts) ; TODO: confirm consistent overriding by causal-opts
                 (update :min-txn-length     (fn [x] (or x 1)))
                 (update :max-txn-length     (fn [x] (or x 4)))
                 (update :max-writes-per-key (fn [x] (or x 256)))
                 (update :total-key-count    (fn [x] (or x (-> (+ 1 4)
                                                               (/ 2)               ; ~mops per op
                                                               (/ 2)               ; ~appends per op
                                                               (* rate time-limit) ; ~total ops
                                                               (/ 256)             ; writes per key
                                                               math/ceil           ; round up
                                                               long
                                                               (+ 10))))))]        ; account for active keys
    {:db              (ps/db)
     :client          (client/->PowerSyncClient nil)
     :generator       (list-append-gen opts)
     :final-generator (txn-final-generator opts)
     :checker         (checker/compose
                       {:causal-consistency    (adya/checker opts)
                        :strong-convergence    (strong-convergence/final-reads (assoc opts :directory "strong-convergence"))})}))

(defn powersync+
  "A PowerSync workload with PostgreSQL included in final reads."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        ps-workload  (powersync opts)]

    (merge
     ps-workload
     {:generator (->> ; PowerSync nodes only for main workload
                  ps-workload
                  :generator
                  (gen/on-threads ps-processes))})))

(defn convergence
  "A PowerSync workload that only checks for strong convergence."
  [opts]
  (merge (powersync opts)
         {:checker (checker/compose
                    {:strong-convergence (strong-convergence/final-reads (assoc opts :directory "strong-convergence"))})}))

(defn convergence+
  "A PowerSync workload that only checks for strong convergence,
   with PostgreSQL included in final reads."
  [opts]
  (merge (powersync+ opts)
         {:checker (checker/compose
                    {:strong-convergence (strong-convergence/final-reads (assoc opts :directory "strong-convergence"))})}))

(defn powersync-single
  "A single client PowerSync workload."
  [opts]
  (merge
   (powersync opts)
   {:checker (checker/compose
              {:strict-serializable (list-append-checker (assoc opts :consistency-models [:strict-serializable]))
               :strong-convergence  (strong-convergence/final-reads (assoc opts :directory "strong-convergence"))})}))

(defn ps-ro-pg-wo
  "A PowerSync doing reads only, PostgreSQL doing writes only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (powersync opts)
     {:generator (gen/mix
                  [; PostgreSQL
                   (gen/on-threads pg-processes
                                   (append-generator opts))
                   ; PowerSync
                   (gen/on-threads ps-processes
                                   (read-generator opts))])
      :checker     (checker/compose
                    {:repeatable-read    (list-append-checker (assoc opts :consistency-models [:repeatable-read]))
                     :causal-consistency (adya/checker (merge opts causal-opts/causal-opts)) ; TODO: confirm consistent overriding by causal-opts
                     :strong-convergence (strong-convergence/final-reads (assoc opts :directory "strong-convergence"))})})))

(defn ps-wo-pg-ro
  "A PowerSync doing writes only, PostgreSQL doing reads only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (powersync opts)
     {:generator (gen/mix
                  [; PostgreSQL
                   (gen/on-threads pg-processes
                                   (read-generator opts))
                   ; PowerSync
                   (gen/on-threads ps-processes
                                   (append-generator opts))])})))

(defn ps-rw-pg-ro
  "A PowerSync doing reads and writes, PostgreSQL doing reads only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)]

    (merge
     (powersync opts)
     {:generator (gen/mix
                  [; PostgreSQL - read only
                   (->> (read-generator opts)
                        (gen/on-threads pg-processes))

                   ; PowerSync - read write
                   (->> (read-generator opts)
                        (gen/on-threads ps-processes))
                   (->> (append-generator opts)
                        (gen/on-threads ps-processes))])
      :final-generator (txn-final-generator opts)})))

(defn sqlite3-local
  "A local SQLite3, single user, workload."
  [opts]
  {:db              (sqlite3/db)
   :client          (client/->PowerSyncClient nil)
   :generator       (list-append/gen opts)
   :final-generator (txn-final-generator opts)
   :checker         (checker/compose
                     {:list-append    (list-append-checker (assoc opts :consistency-models [:strict-serializable]))
                      :logs-ps-client (checker/log-file-pattern #"(?i)ERROR" sqlite3/log-file-short)})})

(defn sqlite3-local-noop
  "A no-op workload."
  [opts]
  {:db              (sqlite3/db)
   :client          (client/->PowerSyncClientNOOP nil)
   :generator       (list-append/gen opts)
   :final-generator (txn-final-generator opts)
   :checker         (checker/compose
                     {:unbridled-optimism (checker/unbridled-optimism)})})
