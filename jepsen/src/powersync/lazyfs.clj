(ns powersync.lazyfs
  "Nemeses that test PowerSync's syncing of data using LazyFS."
  (:require [jepsen
             [control :as c]
             [db :as db]
             [generator :as gen]
             [lazyfs :as lazyfs]
             [nemesis :as nemesis]]
            [jepsen.nemesis.combined :as nc]))

(def lazyfs-commands
  #{:lose-unfsynced-writes :unsynced-data-report})

(defn unsynced-data-report!
  "Generate a report of the unsynced data for the given `lazyfs-map` in the lazyfs log file."
  [lazyfs-map]
  (lazyfs/fifo! lazyfs-map "lazyfs::unsynced-data-report"))

(defrecord LazyFSNemesis [lazyfs-map]
  nemesis/Reflection
  (fs [_this]
    lazyfs-commands)

  nemesis/Nemesis
  (setup!
    [this _test]
    this)

  (invoke!
    [_this test {:keys [f value] :as op}]
    (let [result (case f
                   :lose-unfsynced-writes
                   (c/with-nodes test value
                     (lazyfs/lose-unfsynced-writes! lazyfs-map))

                   :unsynced-data-report
                   (c/with-nodes test value
                     (unsynced-data-report! lazyfs-map)))
          result (->> result
                      (into (sorted-map)))]
      (assoc op :value result)))

  (teardown!
    [_this _test]
    nil))

(defn lazyfs-package
  "A nemesis and generator package for injecting storage faults using LazyFS.
   
   Opts:
   ```clj
   {:lazyfs
    {:targets  sequence-nodes    ; The nodes to target
     :behavior lazyfs-command}}  ; lose-unfsynced-writes, unsynced-data-report
   ```"
  [{:keys [db faults interval lazyfs] :as _opts}]
  (when (contains? faults :lazyfs)
    (let [targets    (:targets  lazyfs)
          behavior   (:behavior lazyfs)
          _          (assert (seq targets))
          _          (assert (lazyfs-commands behavior))
          gen        (->> {:type  :info
                           :f     behavior
                           :value targets}
                          repeat
                          (gen/stagger (or interval nc/default-interval)))
          final-gen  (gen/phases
                      (gen/log (str "final " behavior " for " targets))
                      {:type  :info
                       :f     behavior
                       :value targets})
          lazyfs-map (-> db :lazyfs-db :lazyfs)
          _          (assert lazyfs-map (str "DB is missing :lazyfs: " db))]
      {:generator       gen
       :final-generator final-gen
       :nemesis         (LazyFSNemesis. lazyfs-map)
       :perf            #{{:name  "lazyfs"
                           :fs    lazyfs-commands
                           :start #{}
                           :stop  #{}
                           :color "#FFCCCC"}}})))

(def power-glitch-commands
  #{:noop :power-glitch :start-powersync})

(defrecord PowerGlitchNemesis [lazyfs-db]
  nemesis/Reflection
  (fs [_this]
    power-glitch-commands)

  nemesis/Nemesis
  (setup!
    [this _test]
    this)

  (invoke!
    [_this test {:keys [f value] :as op}]
    (let [lazyfs-map (-> lazyfs-db :lazyfs-db :lazyfs)
          _          (assert lazyfs-map (str "DB is missing :lazyfs: " lazyfs-db))
          result (case f
                   :noop
                   (c/with-nodes* test value
                     (fn noop [_node]
                       :noop))

                   :power-glitch
                   (c/with-nodes* test value
                     (fn power-glitch [node]
                       (db/kill! lazyfs-db test node)
                       (unsynced-data-report! lazyfs-map)
                       (lazyfs/lose-unfsynced-writes! lazyfs-map)
                       (db/start! lazyfs-db test node)
                       :power-restored))

                   :start-powersync
                   (c/with-nodes* test value
                     (fn start-powersync [node]
                       (db/start! lazyfs-db test node))))]
      (assoc op :value result)))

  (teardown!
    [_this _test]))

(defn power-glitch-package
  "A nemesis and generator package to simulate a power glitch.
   
   ```bash
   --nemesis power-glitch
   ```
   "
  [{:keys [db faults interval power-glitch] :as _opts}]
  (when (contains? faults :power-glitch)
    (let [targets    (:targets power-glitch)
          gen        (->> (gen/cycle
                           (gen/phases
                            ; let db do work, i.e. writes
                            {:type  :info
                             :f     :noop
                             :value nil}

                            ; power glitch
                            {:type  :info
                             :f     :power-glitch
                             :value targets}))
                          (gen/stagger (or interval nc/default-interval)))
          final-gen  {:type  :info
                      :f     :start-powersync
                      :value nil}
          nemesis    (PowerGlitchNemesis. db)]
      {:generator       gen
       :final-generator final-gen
       :nemesis         nemesis
       :perf            #{{:name  "power-glitch"
                           :fs    power-glitch-commands
                           :start #{}
                           :stop  #{}
                           :color "#FFCCCC"}}})))

