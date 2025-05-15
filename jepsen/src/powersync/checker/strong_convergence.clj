(ns powersync.checker.strong-convergence
  "A Strong Convergence checker for:
   - max write wins database
   - using readAll, writeSome transactions
   - with :node and :final-read? in op map"
  (:require
   [clojure.set :as set]
   [jepsen
    [checker :as checker]
    [history :as h]]
   [powersync.util :as util]))

(defn non-monotonic-reads
  "Given a history, returns a sequence of 
   {:k k :prev-v prev-v :v v :prev-op prev-op :op op} for non-monotonic reads of k."
  [history]
  (let [[errors _prev-op _prev-reads]
        (->> history
             (reduce (fn [[errors prev-op prev-reads] op]
                       (let [read-all (util/read-all op)
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
      (let [nodes            (->> nodes (into (sorted-set)))

            history-client   (->> history
                                  h/client-ops)
            history-oks      (->> history-client
                                  h/oks)
            history-possible (->> history-client
                                  h/possible)

            final-reads      (->> history-oks
                                  (filter :final-read?))

            ; all nodes must have a final read
            final-nodes   (->> final-reads
                               (map :node)
                               (into #{}))
            missing-nodes (set/difference nodes final-nodes)

            ; {k #{v}} of all possible writes
            possible-writes (->> history-possible
                                 (mapcat (fn [op]
                                           (->> op
                                                util/write-some
                                                (map (fn [[k v]] {k #{v}})))))
                                 (reduce (fn [possible-kv kv]
                                           (merge-with set/union possible-kv kv))
                                         {}))

            ; seq of errors {:invalid-reads {k v} :op op}
            invalid-reads (->> history-oks
                               (keep (fn [op]
                                       (let [invalid-reads
                                             (->> op
                                                  util/read-all
                                                  ; -1 are 'nil' reads
                                                  (remove (fn [[_k v]]
                                                            (= -1 v)))
                                                  ; read of a possibly written value
                                                  (remove (fn [[k v]]
                                                            (contains? (get possible-writes k) v)))
                                                  (into (sorted-map)))]
                                         (when (seq invalid-reads)
                                           {:invalid-reads invalid-reads
                                            :op op})))))

            processes           (util/all-processes history-client)
            non-monotonic-reads (->> processes
                                     (mapcat (fn [p]
                                               (->> history-oks
                                                    (h/filter (fn [{:keys [process] :as _op}]
                                                                (= p process)))
                                                    (non-monotonic-reads))))
                                     (into []))

            ; max {k v} for all ok writes
            max-ok-writes (->> history-oks
                               (reduce (fn [max-ok-writes op]
                                         (->> op
                                              util/write-some
                                              (merge-with max max-ok-writes)))
                                       {}))
            ; max observed {k v}
            ;   - max ok writes plus
            ;   - any ok reads of info writes that are >
            max-observed (->> history-oks
                              (reduce (fn [max-observed op]
                                        (->> op
                                             util/read-all
                                             (reduce (fn [max-observed [k v]]
                                                       (if (and (< (get max-observed k -1) v)
                                                                (contains? (get possible-writes k) v))
                                                         (assoc max-observed k v)
                                                         max-observed))
                                                     max-observed)))
                                      max-ok-writes))

            ; summarize final reads into {k {v #{node}}}
            ; - include max-observed as a node
            k->v->nodes (->> max-observed
                             (reduce (fn [k->v->nodes [k v]]
                                       (assoc k->v->nodes k (sorted-map v (sorted-set "max-observed"))))
                                     (sorted-map)))
            k->v->nodes (->> final-reads
                             (reduce (fn [k->v->nodes {:keys [node] :as op}]
                                       (->> op
                                            util/read-all
                                            (reduce (fn [k->v->nodes [k v]]
                                                      (update-in k->v->nodes [k v] set/union (sorted-set node)))
                                                    k->v->nodes)))
                                     k->v->nodes))
            ; every k must be read by all nodes
            k->v->nodes (->> k->v->nodes
                             (reduce (fn [k->v->nodes [k vs]]
                                       (let [read-nodes    (->> vs vals (apply set/union))
                                             missing-nodes (set/difference nodes read-nodes)]
                                         (if (seq missing-nodes)
                                           (update-in k->v->nodes [k nil] set/union (into (sorted-set) missing-nodes))
                                           k->v->nodes)))
                                     k->v->nodes))
            ; any k that has multiple v's is divergent
            divergent-final-reads (->> k->v->nodes
                                       (filter (fn [[_k vs]]
                                                 (< 1 (count vs))))
                                       (into (sorted-map)))]

        ; result map
        (cond-> {:valid? true}
          (seq missing-nodes)
          (assoc :valid? false
                 :missing-nodes missing-nodes)

          (seq invalid-reads)
          (assoc :valid? false
                 :invalid-reads (vec invalid-reads))

          (seq non-monotonic-reads)
          (assoc :valid? false
                 :non-monotonic-reads non-monotonic-reads)

          (seq divergent-final-reads)
          (assoc :valid? false
                 :divergent-final-reads divergent-final-reads))))))
