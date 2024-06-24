(ns powersync.cli
  "Command-line entry point for PowerSync tests."
  (:require [clojure.string :as str]
            [elle.consistency-model :as cm]
            [jepsen
             [checker :as checker]
             [cli :as cli]
             [generator :as gen]
             [tests :as tests]]
            [jepsen.checker.timeline :as timeline]
            [jepsen.nemesis.combined :as nemesis]
            [jepsen.os.debian :as debian]
            [powersync
             [workload :as workload]]))

(def workloads
  "A map of workload names to functions that take CLI options and return
  workload maps."
  {:powersync-local    workload/powersync-local
   :sqlite3-local      workload/sqlite3-local
   :sqlite3-local-noop workload/sqlite3-local-noop
   :none               (fn [_] tests/noop-test)})

(def all-workloads
  "A collection of workloads we run by default."
  [:powersync])

(def all-nemeses
  "Combinations of nemeses for tests"
  [[]
   [:pause]
   [:partition]
   [:pause :partition]
   [:kill]])

(def special-nemeses
  "A map of special nemesis names to collections of faults"
  {:none []
   :all  [:pause :partition :kill]})

(defn parse-nemesis-spec
  "Takes a comma-separated nemesis string and returns a collection of keyword
  faults."
  [spec]
  (->> (str/split spec #",")
       (map keyword)
       (mapcat #(get special-nemeses % [%]))))

(defn parse-nodes-spec
  "Takes a comma-separated nodes string and returns a set of node names."
  [spec]
  (->> (str/split spec #",")
       (map str/trim)
       (into #{})))

(def short-consistency-name
  "A map of consistency model names to a short name."
  {:strong-session-consistent-view "Consistent-View"})

(defn test-name
  "Given opts, returns a meaningful test name."
  [opts]
  (str (name (:workload opts))
       " " (str/join "," (->> (:consistency-models opts)
                              (map #(short-consistency-name % (name %)))))
       " " (str/join "," (map name (:nemesis opts)))
       " " (:rate opts) "tps-" (:time-limit opts) "s"))

(defn powersync-test
  "Given options from the CLI, constructs a test map."
  [opts]
  (let [workload-name (:workload opts)
        workload ((workloads workload-name) opts)
        db       (:db workload)
        nemesis  (nemesis/nemesis-package
                  {:db         db
                   :nodes      (:nodes opts)
                   :faults     (:nemesis opts)
                   :partition  {:targets [:one :minority-third :majority :majorities-ring]}
                   :pause      {:targets [:one :minority :majority :all]}
                   :kill       {:targets [:minority-third]}
                   :packet     {:targets   [:one :minority :majority :all]
                                :behaviors [{:delay {:time         :50ms
                                                     :jitter       :10ms
                                                     :correlation  :25%
                                                     :distribution :normal}}]}
                   :clock      {:targets [:minority-third]}
                   :offline-online {:targets [:minority]}
                   :interval   (:nemesis-interval opts)})]
    (merge tests/noop-test
           opts
           {:name      (test-name opts)
            :os        debian/os
            :db        db
            :checker   (checker/compose
                        {:perf               (checker/perf
                                              {:nemeses (:perf nemesis)})
                         :timeline           (timeline/html)
                         :stats              (checker/stats)
                         :exceptions         (checker/unhandled-exceptions)
                         :clock              (checker/clock-plot)
                         :workload           (:checker workload)})
            :client    (:client workload)
            :nemesis   (:nemesis nemesis)
            :generator (gen/phases
                        (gen/log "Workload with nemesis")
                        (->> (:generator workload)
                             (gen/stagger    (/ (:rate opts)))
                             (gen/nemesis    (:generator nemesis))
                             (gen/time-limit (:time-limit opts)))

                        (gen/log "Final nemesis")
                        (gen/nemesis (:final-generator nemesis))

                        (gen/log "Final workload")
                        (:final-generator workload))})))

(def cli-opts
  "Command line options"
  [[nil "--consistency-models MODELS" "What consistency models to check for."
    :parse-fn parse-nemesis-spec
    :validate [(partial every? cm/all-models)
               (str "Must be one or more of " cm/all-models)]]

   [nil "--cycle-search-timeout MS" "How long, in milliseconds, to look for a certain cycle in any given SCC."
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--key-count NUM" "Number of keys in active rotation."
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--key-dist DISTRIBUTION" "Exponential or uniform."
    :parse-fn keyword
    :validate [#{:exponential :uniform} "Must be exponential or uniform."]]

   [nil "--max-txn-length NUM" "Maximum number of operations in a transaction."
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--max-writes-per-key NUM" "Maximum number of writes to any given key."
    :default  256
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer."]]

   [nil "--min-txn-length NUM" "Minimum number of operations in a transaction."
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--nemesis FAULTS" "A comma-separated list of nemesis faults to enable"
    :parse-fn parse-nemesis-spec
    :validate [(partial every? #{:pause :partition :packet :kill :clock :offline-online})
               "Faults must be partition, pause, packet, kill, clock, offline-online, or the special faults all or none."]]

   [nil "--nemesis-interval SECS" "Roughly how long between nemesis operations."
    :default 5
    :parse-fn read-string
    :validate [pos? "Must be a positive number."]]

   ["-r" "--rate HZ" "Approximate request rate, in hz"
    :default 100
    :parse-fn read-string
    :validate [pos? "Must be a positive number."]]

   ["-w" "--workload NAME" "What workload should we run?"
    :parse-fn keyword
    :missing  (str "Must specify a workload: " (cli/one-of workloads))
    :validate [workloads (cli/one-of workloads)]]])

(defn all-tests
  "Turns CLI options into a sequence of tests."
  [opts]
  (let [nemeses   (if-let [n (:nemesis opts)] [n] all-nemeses)
        workloads (if-let [w (:workload opts)] [w] all-workloads)]
    (for [n nemeses, w workloads, _i (range (:test-count opts))]
      (powersync-test (assoc opts :nemesis n :workload w)))))

(defn opt-fn
  "Transforms CLI options before execution."
  [parsed]
  parsed)

(defn -main
  "CLI.
   `lein run` to list commands."
  [& args]
  (cli/run! (merge (cli/single-test-cmd {:test-fn  powersync-test
                                         :opt-spec cli-opts
                                         :opt-fn   opt-fn})
                   (cli/test-all-cmd {:tests-fn all-tests
                                      :opt-spec cli-opts
                                      :opt-fn   opt-fn})
                   (cli/serve-cmd))
            args))
