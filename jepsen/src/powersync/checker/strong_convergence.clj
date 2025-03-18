(ns powersync.checker.strong-convergence
  "A Strong Convergence checker for:
   - max write wins database
   - using readAll, writeSome transactions
   - with :node and :final-read? in op map"
  (:require
   [clojure.set :as set]
   [jepsen
    [checker :as checker]
    [history :as h]]))

(defn all-processes
  "Given a history, returns a sorted-set of all processes in it."
  [history]
  (->> history
       (map :process)
       distinct
       (into (sorted-set))))

(defn non-monotonic-reads
  "Given a history, returns a sequence of 
   {:k k :prev-v prev-v :v v :prev-op prev-op :op op} for non-monotonic reads of k."
  [history]
  (let [[errors _prev-op _prev-reads]
        (->> history
             (reduce (fn [[errors prev-op prev-reads] {:keys [value] :as op}]
                       (let [read-all (->> value
                                           (reduce (fn [_ [f _k v]]
                                                     (if (= f :readAll)
                                                       (reduced v)
                                                       {}))
                                                   {}))
                             [errors prev-reads] (->> read-all
                                                      (reduce (fn [[errors prev-reads] [k v]]
                                                                (let [prev-v    (get prev-reads k -1)
                                                                      new-reads (assoc prev-reads k v)
                                                                      errors    (if (<= prev-v v)
                                                                                  errors
                                                                                  (conj errors {:k k
                                                                                                :prev-v prev-v
                                                                                                :v v
                                                                                                :prev-op prev-op
                                                                                                :op op}))]
                                                                  [errors new-reads]))
                                                              [errors prev-reads]))]
                         [errors op prev-reads]))
                     [nil nil nil]))]
    errors))

(defn strong-convergence
  "Check
   - are reads per process per k monotonic?
   - do `:final-read? true` reads strongly converge?
     - final read from all nodes
     - final reads are == all :ok writes"
  [_defaults]
  (reify checker/Checker
    (check [_this {:keys [nodes] :as _test} history _opts]
      (let [nodes    (->> nodes (into (sorted-set)))
            history' (->> history
                          h/client-ops
                          h/oks)

            processes           (all-processes history')
            non-monotonic-reads (->> processes
                                     (mapcat (fn [p]
                                               (->> history'
                                                    (h/filter (fn [{:keys [process] :as _op}]
                                                                (= p process)))
                                                    (non-monotonic-reads))))
                                     (into []))


            final-reads   (->> history'
                               (filter :final-read?))
            final-read-kv (->> history'
                               (reduce (fn [final-read-kv {:keys [value] :as _op}]
                                         (let [write-some (->> value
                                                               (reduce (fn [_ [f _k v]]
                                                                         (if (= f :writeSome)
                                                                           (reduced v)
                                                                           {}))
                                                                       {}))]
                                           (merge-with max final-read-kv write-some)))
                                       {}))

            ; divergent final reads, {k {:expected v node v ...}}
            divergent-reads (->> final-reads
                                 (reduce (fn [divergent {:keys [value node] :as _op}]
                                           (let [read-all (->> value
                                                               (reduce (fn [_ [f _k v]]
                                                                         (if (= f :readAll)
                                                                           (reduced v)
                                                                           {}))
                                                                       {}))]
                                             (->> read-all
                                                  (reduce (fn [divergent [k v]]
                                                            (let [expected-v (get final-read-kv k)]
                                                              (if (= v expected-v)
                                                                divergent
                                                                (-> divergent
                                                                    (update k assoc :expected expected-v)
                                                                    (update k assoc node      v)))))
                                                          divergent))))
                                         (sorted-map)))

            final-nodes   (->> final-reads
                               (map :node)
                               (into #{}))
            missing-nodes (set/difference nodes final-nodes)]

        ; result map
        (cond-> {:valid? true}
          (seq non-monotonic-reads)
          (assoc :valid? false
                 :non-monotonic-reads non-monotonic-reads)

          (seq missing-nodes)
          (assoc :valid? false
                 :missing-nodes missing-nodes)

          (seq divergent-reads)
          (assoc :valid? false
                 :divergent-reads divergent-reads))))))
