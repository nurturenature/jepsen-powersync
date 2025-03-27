(ns powersync.checker.causal-consistency
  "A Causal Consistency checker for:
   - max write wins database
   - using readAll, writeSome transactions"
  (:require [clojure.set :as set]
            [jepsen
             [checker :as checker]
             [history :as h]]
            [powersync.util :as util]))

(defn read-unwritten-write
  "Given a history, checks all ok reads against possibly written values
   returning nil or a sequence of {:read-unwritten-write #{[k v]} :op op}."
  [history]
  (let [history' (->> history
                      h/client-ops)

        all-writes (->> history'
                        h/possible
                        (reduce (fn [all-writes op]
                                  (->> op
                                       util/write-some
                                       (into all-writes)))
                                #{}))
        invalid-reads (->> history'
                           h/oks
                           (reduce (fn [invalid-reads op]
                                     (let [reads (->> op
                                                      util/read-all
                                                      ; remove nil, -1, reads
                                                      (remove (fn [[_k v]] (= v -1)))
                                                      (into #{}))
                                           not-written (set/difference reads all-writes)]
                                       (if (seq not-written)
                                         (conj invalid-reads {:read-unwritten-write not-written
                                                              :op                   op})
                                         invalid-reads)))
                                   nil))]
    invalid-reads))

; process-state 
; {k [v why]}

; process-states 
; {process process-state}

; monotonic writes, writes follow reads, states
; mw-wfr-states
; {[k v] process-state}

(defn nil-process-state
  "The initial, nil, state of the kv store."
  [all-keys]
  (let [v   -1
        why :initial-state]
    (->> all-keys
         (map (fn [k] [k [v why]]))
         (into {}))))

(defn nil-process-states
  "The initial states, process states, of the kv store."
  [all-keys all-processes]
  (->> all-processes
       (map (fn [p] [p (nil-process-state all-keys)]))
       (into {})))

(defn mw-wfr->process-state
  "Update the process-state with monotonic writes and write follows reads
   based on the reads in the op."
  [reads process-state mw-wfr-states]
  (->> reads
       (reduce (fn [process-state [read-k read-v :as read-kv]]
                 (if (= read-v -1)
                   ; read value is nil
                   process-state
                   ; update process state with mr-wfr state
                   (if-let [mw-wfr-state (get mw-wfr-states [read-k read-v])]
                     (merge-with (fn [[v why] [v' _why']]
                                   (if (<= v v')
                                     [v' :writes-follow-reads]
                                     [v why]))
                                 process-state mw-wfr-state)
                     ; seeing read before write, likely due to interleaved replication ops
                     ; ok for now, will be checked by `read-unwritten-write`
                     process-state)))
               process-state)))

(defn ryw-mw-wfr-mr
  "Process given history op by op returning a sequence of any Causal Consistency errors."
  [all-keys all-processes history]
  (let [; initial state of every process
        p-states (nil-process-states all-keys all-processes)

        ; process op by op for consistency
        [errors _p-states _mw-wfr-states]
        (->> history
             (reduce (fn [[errors p-states mw-wfr-states] {:keys [process] :as op}]
                       (let [reads  (util/read-all op)
                             writes (util/write-some op)

                             ; must read all keys
                             errors (let [missing-keys (set/difference all-keys (set (keys reads)))]
                                      (if (seq missing-keys)
                                        (conj errors {:error        :read-missing-keys
                                                      :missing-keys missing-keys
                                                      :op           op})
                                        errors))

                             ; prev state of process
                             p-state (get p-states process)

                             ; update process state to include monotonic writes and writes follow reads
                             p-state (mw-wfr->process-state reads p-state mw-wfr-states)

                             ; check reads against process state
                             errors (->> reads
                                         (reduce (fn [errors [read-k read-v :as read-kv]]
                                                   (let [[expected-v expected-why] (get p-state read-k)]
                                                     (if (<= expected-v read-v)
                                                       errors
                                                       (conj errors {:error       :invalid-read-kv
                                                                     :why         expected-why
                                                                     :expected-kv [read-k expected-v]
                                                                     :read-kv     read-kv
                                                                     :op          op}))))
                                                 errors))

                             ; add reads to process state
                             p-state (->> reads
                                          (reduce (fn [p-state [read-k read-v]]
                                                    (assoc p-state read-k [read-v :monotonic-reads]))
                                                  p-state))

                             ; add writes to process state
                             p-state (->> writes
                                          (reduce (fn [p-state [write-k write-v]]
                                                    (assoc p-state write-k [write-v :read-your-writes-monotonic-writes]))
                                                  p-state))

                             ; update process states with this process state
                             p-states (assoc p-states process p-state)

                             ; update monotonic writes, writes follow reads state
                             mw-wfr-states (->> writes
                                                (reduce (fn [mw-wfr-states [_write-k _write-v :as write-kv]]
                                                          (assoc mw-wfr-states write-kv p-state))
                                                        mw-wfr-states))]
                         [errors p-states mw-wfr-states]))
                     [nil p-states nil]))]
    errors))

(defn causal-consistency
  "Check, do processes
     - read their own writes?
     - read other's writes monotonically?
     - writes follow reads?
     - have monotonic reads?
     - only read written values"
  [defaults]
  (reify checker/Checker
    (check [_this _test history opts]
      (let [opts          (merge defaults opts)
            all-keys      (->> (get opts :key-count util/key-count) range (into #{}))

            history'      (->> history
                               h/client-ops
                               h/oks)
            all-processes (util/all-processes history')

            ryw-mw-wfr-mr (ryw-mw-wfr-mr all-keys all-processes history')

            read-unwritten-write (read-unwritten-write history)]

        ; result map
        (cond-> {:valid? true}
          (seq ryw-mw-wfr-mr)
          (assoc :valid?     false
                 :ryw-mw-wfr ryw-mw-wfr-mr)

          (seq read-unwritten-write)
          (assoc :valid?     false
                 :read-unwritten-write read-unwritten-write))))))
