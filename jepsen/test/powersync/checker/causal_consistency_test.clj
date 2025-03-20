(ns powersync.checker.causal-consistency-test
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen
             [checker :as checker]
             [history :as h]]
            [powersync.checker.causal-consistency :refer [causal-consistency]]))

(def valid-read-your-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0}] [:writeSome nil {}]], :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {1 1 2 1}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(def invalid-read-your-writes
  (->> [{:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 0, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {0 0 1 0}]], :node "n1", :index 1, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 2, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {}] [:writeSome nil {1 1 2 1}]], :node "n2", :index 3, :time -1}

        {:process 0, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n1", :index 4, :time -1}
        {:process 0, :type :ok, :f :txn, :value [[:readAll nil {0 0}] [:writeSome nil {}]], :node "n1", :index 5, :time -1}

        {:process 1, :type :invoke, :f :txn, :value [[:readAll nil {}] [:writeSome nil {}]], :node "n2", :index 6, :time -1}
        {:process 1, :type :ok, :f :txn, :value [[:readAll nil {0 0 1 0}] [:writeSome nil {}]], :node "n2", :index 7, :time -1}]
       h/history))

(deftest read-your-writes-test
  (testing "read your writes"
    (let [opts     nil
          test-map {:name "read-your-writes" :start-time 0 :nodes ["n1" "n2"]}]
      (is (= {:valid? true}
             (checker/check (causal-consistency opts)
                            test-map
                            valid-read-your-writes
                            opts)))

      (is (= {:valid? false,
              :read-your-writes
              (list
               {:write-k 1,
                :prev-write 0,
                :this-read -1,
                :op (h/op {:index 5, :time -1, :type :ok, :process 0, :f :txn, :value [[:readAll nil {0 0}] [:writeSome nil {}]], :node "n1"})}
               {:write-k 2,
                :prev-write 1,
                :this-read -1,
                :op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0}] [:writeSome nil {}]], :node "n2"})}
               {:write-k 1,
                :prev-write 1,
                :this-read 0,
                :op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0}] [:writeSome nil {}]], :node "n2"})}
               {:read-k 1,
                :prev-write 1,
                :this-read 0,
                :op (h/op {:index 7, :time -1, :type :ok, :process 1, :f :txn, :value [[:readAll nil {0 0, 1 0}] [:writeSome nil {}]], :node "n2"})})}
             (checker/check (causal-consistency opts)
                            test-map
                            invalid-read-your-writes
                            opts))))))

