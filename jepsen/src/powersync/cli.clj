(ns powersync.cli
  "Command-line entry point for PowerSync tests."
  (:require [causal.checker.mww
             [stats :as stats]
             [util :as util]]
            [clojure.set :as set]
            [clojure.string :as str]
            [jepsen
             [checker :as checker]
             [cli :as cli]
             [generator :as gen]
             [tests :as tests]]
            [jepsen.checker.timeline :as timeline]
            [jepsen.os.debian :as debian]
            [powersync
             [nemesis :as nemesis]
             [powersync :as ps]
             [workload :as workload]]))

(def workloads
  "A map of workload names to functions that take CLI options and return
  workload maps."
  {:ps-rw-pg-rw        workload/ps-rw-pg-rw
   :ps-ro-pg-rw        workload/ps-ro-pg-rw
   :ps-rw-pg-ro        workload/ps-rw-pg-ro
   :convergence        workload/convergence
   :none               (fn [_] tests/noop-test)})

(def all-workloads
  "A collection of workloads we run by default."
  [:powersync])

(def nemeses
  "A collection of valid nemeses."
  #{:disconnect-orderly :disconnect-random
    :stop-start
    :partition-sync :partition-postgres :partition-both
    :pause :kill
    :upload-queue})

(def all-nemeses
  "Combinations of nemeses for tests"
  [[]
   [:disconnect-orderly :disconnect-random]
   [:stop-start]
   [:pause]
   [:partition-sync :partition-postgres :partition-both]
   [:pause :partition-sync]
   [:kill]])

(def special-nemeses
  "A map of special nemesis names to collections of faults"
  {:none []
   :all  nemeses})

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

(defn test-name
  "Given opts, returns a meaningful test name."
  [{:keys [client-impl nemesis nodes postgres-nodes rate time-limit workload] :as _opts}]
  (let [nodes (into #{} nodes)]
    (str (name workload)
         (when (not= client-impl "dflt")
           (str " " client-impl))
         " " (str/join "," (map name nemesis))
         " " (count postgres-nodes) "pg"
         "-" (count (set/difference nodes postgres-nodes)) "ps"
         "-" rate "tps"
         "-" time-limit "s")))

(defn powersync-test
  "Given options from the CLI, constructs a test map."
  [opts]
  (let [workload-name (:workload opts)
        workload ((workloads workload-name) opts)
        db       (:db workload)
        nemesis  (nemesis/nemesis-package
                  {:db                 db
                   :nodes              (:nodes opts)
                   :faults             (:nemesis opts)
                   :disconnect-orderly {:targets [nil]}
                   :disconnect-random  {:targets [nil]}
                   :stop-start         {:targets [nil]}
                   :partition-sync     {:targets [nil]}
                   :partition-postgres {:targets [nil]}
                   :partition-both     {:targets [nil]}
                   :pause              {:targets [nil]}
                   :kill               {:targets [:majority]}
                   :upload-queue       nil
                   :interval           (:nemesis-interval opts)})]
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
                         :completions-by-node (stats/completions-by-node)
                         :exceptions         (checker/unhandled-exceptions)
                         :logs-ps-client     (checker/log-file-pattern #"(SEVERE)|(ERROR)" ps/log-file-short)
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
                        (->> (:final-generator workload)
                             (gen/stagger (/ (:rate opts)))))})))

(def cli-opts
  "Command line options"
  [[nil "--client-impl IMPL" "Client implementation, e.g. dart, rust, etc."
    :default  "rust"
    :validate [ps/client-impls (cli/one-of ps/client-impls)]]

   [nil "--client-timeout SECS" "The number of seconds to wait before timing out a client connection."
    :default  3
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--key-count NUM" "The total number of keys."
    :default  util/key-count
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--keys-txn NUM" "The number of keys to act on in a transactions."
    :default  4
    :parse-fn parse-long
    :validate [pos? "Must be a positive integer"]]

   [nil "--nemesis FAULTS" "A comma-separated list of nemesis faults to enable"
    :parse-fn parse-nemesis-spec
    :validate [(partial every? nemeses)
               (str "Faults must be " nemeses ", or the special faults all or none.")]]

   [nil "--nemesis-interval SECS" "Roughly how long between nemesis operations."
    :default 5
    :parse-fn read-string
    :validate [pos? "Must be a positive number."]]

   [nil "--postgres-nodes NODES" "List of nodes that should be PostgreSQL clients"
    :parse-fn parse-nodes-spec]

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
