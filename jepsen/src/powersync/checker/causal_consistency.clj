(ns powersync.checker.causal-consistency
  "A Causal Consistency checker for:
   - max write wins database
   - using readAll, writeSome transactions"
  (:require
   [jepsen
    [checker :as checker]
    [history :as h]]
   [powersync.checker.util :as util]))



(defn reading-writes-in-history
  "Do operations in the given history read their own writes?
   Returns nil or a sequence of errors."
  [history]
  (let [[errors _prev-writes]
        (->> history
             (reduce (fn [[errors prev-writes] op]
                       (let [reads  (util/read-all  op)
                             writes (util/write-some op)
                             ; every read must be <= previous write
                             errors (->> reads
                                         (reduce (fn [errors [read-k read-v]]
                                                   (let [prev-write (get prev-writes read-k -1)]
                                                     (if (<= prev-write read-v)
                                                       errors
                                                       (conj errors {:read-k     read-k
                                                                     :prev-write prev-write
                                                                     :this-read  read-v
                                                                     :op         op}))))
                                                 errors))
                             ; every previous write must be <= this read
                             errors (->> prev-writes
                                         (reduce (fn [errors [write-k write-v]]
                                                   (let [this-read (get reads write-k -1)]
                                                     (if (<= write-v this-read)
                                                       errors
                                                       (conj errors {:write-k    write-k
                                                                     :prev-write write-v
                                                                     :this-read  this-read
                                                                     :op         op}))))
                                                 errors))]
                         [errors (merge prev-writes writes)]))
                     [nil nil]))]
    errors))

(defn read-your-writes
  "Does each process in a history read its own writes?
   Returns nil or a sequence of errors."
  [all-processes history]
  (->> all-processes
       (mapcat (fn [process]
                 (->> history
                      (h/filter #(= (:process %) process))
                      (reading-writes-in-history))))))

(defn causal-consistency
  "Check
   - do processes read their own writes?"
  [_defaults]
  (reify checker/Checker
    (check [_this _test history _opts]
      (let [history'      (->> history
                               h/client-ops
                               h/oks)
            all-processes (util/all-processes history')

            read-your-writes (read-your-writes all-processes history')]

        ; result map
        (cond-> {:valid? true}
          (seq read-your-writes)
          (assoc :valid? false
                 :read-your-writes read-your-writes))))))
