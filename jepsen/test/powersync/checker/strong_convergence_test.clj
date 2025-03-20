(ns powersync.checker.strong-convergence-test
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen
             [checker :as checker]
             [history :as h]]
            [powersync.checker.strong-convergence :refer [strong-convergence]]))

(def valid-final-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 7, :time -1}]
       h/history))

(def non-monotonic-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 8, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0}] [:writeSome nil {}]], :node "n2", :index 9, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 10, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 11, :time -1}]
       h/history))

(def missing-nodes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 5, :time -1}]
       h/history))

(def divergent-final-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :final-read? true, :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0}] [:writeSome nil {}]], :final-read? true, :node "n2", :index 7, :time -1}]
       h/history))

(deftest strong-convergence-test
  (testing "strong-convergence"
    (let [opts     nil
          test-map {:name "strong-convergence" :start-time 0 :nodes ["n1" "n2"]}]
      (is (= {:valid? true}
             (checker/check (strong-convergence opts)
                            test-map
                            valid-final-reads
                            opts)))

      (is (= {:valid? false
              :missing-nodes #{"n2"}}
             (checker/check (strong-convergence opts)
                            test-map
                            missing-nodes
                            opts)))

      (is (= {:valid? false
              :divergent-reads {1 {:expected 1, "n2" 0}}}
             (checker/check (strong-convergence opts)
                            test-map
                            divergent-final-reads
                            opts)))
      (is (= {:valid? false
              :non-monotonic-reads [{:k 1
                                     :prev-v 1
                                     :v 0
                                     :prev-op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 1, 2 1}] [:writeSome nil {}]], :node "n2"})
                                     :op      (h/op {:index 9, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0}]      [:writeSome nil {}]], :node "n2"})}]}
             (checker/check (strong-convergence opts)
                            test-map
                            non-monotonic-reads
                            opts))))))

