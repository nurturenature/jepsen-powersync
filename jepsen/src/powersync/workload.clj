(ns powersync.workload
  (:require [elle.list-append :as list-append]
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

(defn powersync-single
  "A single client PowerSync workload."
  [opts]
  {:db              (ps/db)
   :client          (client/->PowerSyncClient nil)
   :generator       (txn-generator opts)
   :final-generator (txn-final-generator opts)
   :checker         (checker/compose
                     {:list-append    (list-append-checker (assoc opts :consistency-models [:strict-serializable]))
                      :logs-ps-client (checker/log-file-pattern #"ERROR" ps/log-file-short)})})

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
