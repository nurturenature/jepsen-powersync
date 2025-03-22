(ns powersync.checker.util
  "Utilities for checkers for:
   - max write wins database
   - using readAll, writeSome transactions")

(def key-count
  "The total number of keys."
  100)

(defn all-processes
  "Given a history, returns a sorted-set of all processes in it."
  [history]
  (->> history
       (map :process)
       distinct
       (into (sorted-set))))

(defn read-all
  "Given an op, returns a {k v} of its reads."
  [{:keys [value] :as op}]
  (let [[[readAll _k v :as _readAll] [writeSome _k _v :as _writeSome]] value]
    (assert (= readAll   :readAll)   (str "missing :readAll in op: " op))
    (assert (= writeSome :writeSome) (str "missing :writeSome in op: " op))
    v))

(defn write-some
  "Given an op, returns a {k v} of its writes."
  [{:keys [value] :as op}]
  (let [[[readAll _k _v :as _readAll] [writeSome _k v :as _writeSome]] value]
    (assert (= readAll   :readAll)   (str "missing :readAll in op: " op))
    (assert (= writeSome :writeSome) (str "missing :writeSome in op: " op))
    v))
