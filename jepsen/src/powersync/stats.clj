(ns powersync.stats
  (:require
   [jepsen
    [checker :as checker]
    [history :as h]]))

(defn completions-by-node
  "Calculate stats by completions by node."
  []
  (reify checker/Checker
    (check [_this {:keys [nodes] :as _test} history _opts]
      (let [; client completions only
            history' (->> history
                          h/client-ops
                          (h/remove (fn [{:keys [type] :as _op}] (= type :invoke))))

            ; {node {type total}}
            summary  (->> history'
                          (reduce (fn [summary {:keys [type node] :as op}]
                                    (assert node (str "op missing :node, op: " op))
                                    (-> summary
                                        (update-in ["all" type]   (fn [total]
                                                                    (+ (or total 0) 1)))
                                        (update-in ["all" :total] (fn [total]
                                                                    (+ (or total 0) 1)))
                                        (update-in [node  type]   (fn [total]
                                                                    (+ (or total 0) 1)))
                                        (update-in [node  :total] (fn [total]
                                                                    (+ (or total 0) 1)))))
                                  (sorted-map)))

            ; sort inner map for usability
            summary  (->> summary
                          (reduce (fn [summary [node inner-map]]
                                    (assoc summary node (into (sorted-map) inner-map)))
                                  (sorted-map)))]

        ; result map
        {:valid? true
         :nodes  nodes
         :completions-by-node summary}))))
