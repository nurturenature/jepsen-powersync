(ns powersync.workload
  (:require [causal.checker
             [adya :as adya]
             [opts :as causal-opts]
             [strong-convergence :as strong-convergence]]
            [clojure.set :as set]
            [elle.list-append :as list-append]
            [jepsen
             [checker :as checker]
             [generator :as gen]]
            [powersync
             [client :as client]
             [powersync :as ps]
             [sqlite3 :as sqlite3]]))

(def total-key-count
  "The total number of keys."
  100)

(def default-key-count
  "The default number of keys to act on in a transactions."
  10)

(def all-keys
  "A sorted set of all keys."
  (->> (range total-key-count)
       (into (sorted-set))))

(defn op+
  "Given a :f and :value, creates an :invoke op."
  [f value]
  (merge {:type :invoke :f f :value value}))

(defn txn-generator
  "Given optional opts, return a generator of multi-txn ops, e.g. random writes/reads over all-keys."
  ([] (txn-generator nil))
  ([{:keys [min-txn-length max-txn-length] :as opts}]
   (let [opts (assoc opts
                     :key-dist           :uniform
                     :key-count          total-key-count
                     :max-writes-per-key 1000
                     :min-txn-length     (or min-txn-length 4)
                     :max-txn-length     (or max-txn-length 4))]

     (list-append/gen opts))))

(defn append-generator
  "Given optional opts, return a lazy sequence of
   transactions consisting only of :append's."
  ([] (append-generator nil))
  ([{:keys [key-count] :as _opts}]
   (let [key-count (or key-count default-key-count)]
     (->> (range)
          (map (fn [v]
                 (let [append-keys (->> all-keys
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
  ([{:keys [key-count] :as _opts}]
   (let [key-count (or key-count default-key-count)]
     (repeatedly
      (fn [] (let [read-keys (->> all-keys
                                  shuffle
                                  (take key-count))
                   value (->> read-keys
                              (mapv (fn [k]
                                      [:r k nil])))]
               (op+ :read-only value)))))))

(defn txn-final-generator
  "final-generator for txn-generator."
  [_opts]
  (gen/phases
   (gen/log "Quiesce...")
   (gen/sleep 3)
   (gen/log "Final reads...")
   (->> all-keys
        (map (fn [k]
               {:type :invoke :f :r-final :value [[:r k nil]] :final-read? true}))
        (gen/each-thread)
        (gen/clients))))

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
  [opts]
  (let [opts (merge causal-opts/causal-opts opts)]
    {:db              (ps/db)
     :client          (client/->PowerSyncClient nil)
     :generator       (txn-generator opts)
     :final-generator (txn-final-generator opts)
     :checker         (checker/compose
                       {:monotonic-atomic-view (list-append-checker
                                                (assoc opts :consistency-models [:monotonic-atomic-view]))
                        :causal-consistency    (adya/checker opts)
                        :strong-convergence    (strong-convergence/final-reads)})}))

(defn powersync-single
  "A single client PowerSync workload."
  [opts]
  (merge
   (powersync opts)
   {:checker (checker/compose
              {:strict-serializable (list-append-checker (assoc opts :consistency-models [:strict-serializable]))
               :strong-convergence  (strong-convergence/final-reads)})}))

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
                     :causal-consistency (adya/checker opts)
                     :strong-convergence (strong-convergence/final-reads)})})))

(defn ps-wo-pg-ro
  "A PowerSync doing writes only, PostgreSQL doing reads only, workload."
  [{:keys [nodes postgres-nodes] :as opts}]
  (let [_            (assert (seq postgres-nodes))
        nodes        (into #{} nodes)
        ps-nodes     (set/difference nodes postgres-nodes)
        ps-processes (nodes->processes ps-nodes)
        pg-processes (nodes->processes postgres-nodes)
        opts         (merge
                      causal-opts/causal-opts
                      opts)]

    (merge
     (powersync opts)
     {:generator (gen/mix
                  [; PostgreSQL
                   (gen/on-threads pg-processes
                                   (read-generator opts))
                   ; PowerSync
                   (gen/on-threads ps-processes
                                   (append-generator opts))])})))

(defn sqlite3-local
  "A local SQLite3, single user, workload."
  [opts]
  {:db              (sqlite3/db)
   :client          (client/->PowerSyncClient nil)
   :generator       (txn-generator opts)
   :final-generator (txn-final-generator opts)
   :checker         (checker/compose
                     {:list-append    (list-append-checker (assoc opts :consistency-models [:strict-serializable]))
                      :logs-ps-client (checker/log-file-pattern #"(?i)ERROR" sqlite3/log-file-short)})})

(defn sqlite3-local-noop
  "A no-op workload."
  [opts]
  {:db              (sqlite3/db)
   :client          (client/->PowerSyncClientNOOP nil)
   :generator       (txn-generator opts)
   :final-generator (txn-final-generator opts)
   :checker         (checker/compose
                     {:unbridled-optimism (checker/unbridled-optimism)})})
