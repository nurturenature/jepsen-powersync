(ns powersync.checker.causal-consistency-test
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen
             [checker :as checker]
             [history :as h]]
            [powersync.checker.causal-consistency :refer [causal-consistency]]))

(def invalid-read-unwritten-write
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 4, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 1 1 1 2 1}] [:writeSome nil {}]], :node "n2", :index 5, :time -1}]
       h/history))

(deftest read-unwritten-write-test
  (testing "read unwritten write"
    (let [opts     {:key-count 3}
          test-map {:name "read-unwritten-write" :start-time 0 :nodes ["n1" "n2"]}]
      (is (= {:valid? false,
              :read-unwritten-write (list {:read-unwritten-write #{[0 1]},
                                           :op (h/op {:index 5, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 1, 1 1, 2 1}] [:writeSome nil {}]], :node "n2"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-read-unwritten-write
                            opts))))))

(def valid-read-your-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1}] [:writeSome nil {}]], :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 1 2 1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(def invalid-read-your-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 -1 2 -1}] [:writeSome nil {}]], :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(deftest read-your-writes-test
  (testing "read your writes"
    (let [opts     {:key-count 3}
          test-map {:name "read-your-writes" :start-time 0 :nodes ["n1" "n2"]}]
      (is (= {:valid? true}
             (checker/check (causal-consistency opts)
                            test-map
                            valid-read-your-writes
                            opts)))

      (is (= {:valid? false,
              :ryw-mw-wfr (list {:error :invalid-read-kv,
                                 :why :read-your-writes-monotonic-writes,
                                 :expected-kv [2 1],
                                 :read-kv [2 -1],
                                 :op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0, 2 -1}] [:writeSome nil {}]], :node "n2"})}
                                {:error :invalid-read-kv,
                                 :why :read-your-writes-monotonic-writes,
                                 :expected-kv [1 1],
                                 :read-kv [1 0],
                                 :op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0, 2 -1}] [:writeSome nil {}]], :node "n2"})}
                                {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [1 0],
                                 :read-kv [1 -1],
                                 :op (h/op {:index 5, :time -1, :type :ok, :process 0, :f :txn, :value [[:readAll nil {0 0, 1 -1, 2 -1}] [:writeSome nil {}]], :node "n1"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-read-your-writes
                            opts))))))

(def valid-monotonic-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1 3 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {2 1 3 1}]], :node "n1", :index 2, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1 3 -1}] [:writeSome nil {2 1 3 1}]], :node "n1", :index 3, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 4, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1 3 -1}] [:writeSome nil {}]], :node "n2", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 1 3 1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(def invalid-monotonic-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1 3 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {2 1 3 1}]], :node "n1", :index 2, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1 3 -1}] [:writeSome nil {2 1 3 1}]], :node "n1", :index 3, :time -1}

        ; invalid: read op 3 but not op 1
        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 4, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 1 3 1}] [:writeSome nil {}]], :node "n2", :index 5, :time -1}

        ; valid: read op 1 and op 3
        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 1 3 1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(deftest monotonic-writes-test
  (testing "monotonic writes"
    (let [opts     {:key-count 4}
          test-map {:name "monotonic-writes" :start-time 0 :nodes ["n1" "n2"]}]
      (is (= {:valid? true}
             (checker/check (causal-consistency opts)
                            test-map
                            valid-monotonic-writes
                            opts)))

      (is (= {:valid? false,
              :ryw-mw-wfr (list {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [1 0],
                                 :read-kv [1 -1],
                                 :op (h/op {:index 5, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 -1, 1 -1, 2 1, 3 1}] [:writeSome nil {}]], :node "n2"})}
                                {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [0 0],
                                 :read-kv [0 -1],
                                 :op (h/op {:index 5, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 -1, 1 -1, 2 1, 3 1}] [:writeSome nil {}]], :node "n2"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-monotonic-writes
                            opts))))))

(def valid-monotonic-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1}] [:writeSome nil {}]], :node "n1", :index 5, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 6, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :node "n1", :index 7, :time -1}]
       h/history))

(def invalid-monotonic-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 4, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 1 2 1}] [:writeSome nil {}]], :node "n3", :index 5, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 6, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 1}] [:writeSome nil {}]], :node "n3", :index 7, :time -1}]
       h/history))

(def invalid-monotonic-reads-wfr
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 4, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 1 2 1}] [:writeSome nil {}]], :node "n3", :index 5, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 6, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 -1}] [:writeSome nil {}]], :node "n3", :index 7, :time -1}]
       h/history))

(deftest monotonic-reads-test
  (testing "monotonic reads"
    (let [opts     {:key-count 3}
          test-map {:name "monotonic-reads" :start-time 0 :nodes ["n1" "n2" "n3"]}]
      (is (= {:valid? true}
             (checker/check (causal-consistency opts)
                            test-map
                            valid-monotonic-reads
                            opts)))

      (is (= {:valid? false,
              :ryw-mw-wfr (list {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [1 1],
                                 :read-kv [1 0],
                                 :op (h/op {:index 7, :time -1, :type :ok, :process 2, :f :txn, :value [[:readAll nil {0 0, 1 0, 2 1}] [:writeSome nil {}]], :node "n3"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-monotonic-reads
                            opts)))

      (is (= {:valid? false,
              :ryw-mw-wfr (list {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [2 1],
                                 :read-kv [2 -1],
                                 :op (h/op {:index 7, :time -1, :type :ok, :process 2, :f :txn, :value [[:readAll nil {0 0, 1 1, 2 -1}] [:writeSome nil {}]], :node "n3"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-monotonic-reads-wfr
                            opts))))))

(def valid-writes-follow-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 4, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 1 2 1}] [:writeSome nil {}]], :node "n3", :index 5, :time -1}]
       h/history))

(def invalid-writes-follow-reads
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 -1 2 -1}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0 2 -1}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 2, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n3", :index 4, :time -1}
        {:process 2, :type :ok, :f :txn, :value [[:readAll nil {0 -1 1 1 2 1}] [:writeSome nil {}]], :node "n3", :index 5, :time -1}]
       h/history))

(deftest writes-follow-reads-test
  (testing "writes follow reads"
    (let [opts     {:key-count 3}
          test-map {:name "writes-follow-reads" :start-time 0 :nodes ["n1" "n2" "n3"]}]
      (is (= {:valid? true}
             (checker/check (causal-consistency opts)
                            test-map
                            valid-writes-follow-reads
                            opts)))

      (is (= {:valid? false,
              :ryw-mw-wfr (list {:error :invalid-read-kv,
                                 :why :writes-follow-reads,
                                 :expected-kv [0 0],
                                 :read-kv [0 -1],
                                 :op (h/op {:index 5, :time -1, :type :ok, :process 2, :f :txn, :value [[:readAll nil {0 -1, 1 1, 2 1}] [:writeSome nil {}]], :node "n3"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-writes-follow-reads
                            opts))))))
