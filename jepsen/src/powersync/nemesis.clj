(ns powersync.nemesis
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.set :as set]
            [jepsen
             [control :as c]
             [db :as db]
             [generator :as gen]
             [nemesis :as nemesis]]
            [jepsen.nemesis.combined :as nc]))

(def nemesis-path
  "URI path for nemesis on HTTP server"
  "db-api")

(comment
  (def api-enum
    "The actual enum values used in the Dart HTTP server.
     This value just serves as documentation."
    #{:connect :disconnect :close
      :selectAll
      :uploadQueueCount :uploadQueueWait :downloadingWait}))

(def disconnected-nodes
  "Set of nodes that are currently disconnected as an atom."
  (atom #{}))

(defn disconnect
  "Disconnect from sync service."
  [_test node]
  (try
    (http/get (str "http://" node ":8089/" nemesis-path "/disconnect"))
    :disconnected
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn connect
  "Connect to sync service."
  [_test node]
  (try
    (http/get (str "http://" node ":8089/" nemesis-path "/connect"))
    :connected
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn disconnect-orderly-nemesis
  "A nemesis that disconnects and connects to the sync service in an orderly fashion,
   i.e. only connect to nodes that have been disconnected.
   This nemesis responds to:
  ```
  {:f :disconnect-orderly :value :node-spec}   ; target nodes as interpreted by `db-nodes`
  {:f :connect-orderly    :value nil}          ; connects to nodes that were disconnected
   ```"
  [db]
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:disconnect-orderly :connect-orderly})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this {:keys [postgres-nodes] :as test} {:keys [f value] :as op}]
      (let [result (case f
                     :disconnect-orderly (let [_       (assert (not (seq @disconnected-nodes)))
                                               ; target nodes per db-spec
                                               targets (->> value
                                                            (nc/db-nodes test db)
                                                            (into #{}))
                                               ; ignore PostgreSQL nodes
                                               targets (set/difference targets postgres-nodes)]
                                           (swap! disconnected-nodes (fn [_]
                                                                       targets))
                                           (c/on-nodes test targets disconnect))
                     :connect-orderly    (let [; final generator may or may not have any disconnected nodes
                                               _       (assert (case value
                                                                 :orderly (seq @disconnected-nodes)
                                                                 :final   true))
                                               targets @disconnected-nodes]
                                           (swap! disconnected-nodes (fn [_]
                                                                       #{}))
                                           (c/on-nodes test targets connect)))
            result (into (sorted-map) result)]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn disconnect-orderly-package
  "A nemesis and generator package that disconnects and connects in an orderly fashion to the sync service.
   
   Opts:
   ```clj
   {:disconnect-orderly {:targets [...]}}  ; A collection of node specs, e.g. [:one, :all]
  ```"
  [{:keys [db faults interval disconnect-orderly] :as _opts}]
  (when (contains? faults :disconnect-orderly)
    (let [targets    (:targets disconnect-orderly (nc/node-specs db))
          disconnect (fn disconnect [_ _]
                       {:type  :info
                        :f     :disconnect-orderly
                        :value (rand-nth targets)})
          connect    {:type  :info
                      :f     :connect-orderly
                      :value :orderly}
          gen        (->> (gen/flip-flop disconnect (repeat connect))
                          (gen/stagger (or interval nc/default-interval)))]
      {:generator       gen
       :final-generator (assoc connect :value :final)
       :nemesis         (disconnect-orderly-nemesis db)
       :perf            #{{:name  "disconnect-orderly"
                           :fs    #{}
                           :start #{:disconnect-orderly}
                           :stop  #{:connect-orderly}
                           :color "#D1E8A0"}}})))

(defn disconnect-random-nemesis
  "A nemesis that disconnects and connects to the sync service in a random fashion,
   i.e. disconnect random nodes, connect random nodes.
   This nemesis responds to:
  ```
  {:f :disconnect-random :value :node-spec}   ; target nodes as interpreted by `db-nodes`
  {:f :connect-random    :value :node-spec}   ; target nodes as interpreted by `db-nodes`
   ```"
  [db]
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:disconnect-random :connect-random})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this {:keys [postgres-nodes] :as test} {:keys [f value] :as op}]
      (let [; target nodes per db-spec
            targets (->> value
                         (nc/db-nodes test db)
                         (into #{}))
            ; ignore PostgreSQL nodes
            targets (set/difference targets postgres-nodes)
            result (case f
                     :disconnect-random (c/on-nodes test targets disconnect)
                     :connect-random    (c/on-nodes test targets connect))
            result (into (sorted-map) result)]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn disconnect-random-package
  "A nemesis and generator package that disconnects and connects in a random fashion to the sync service.
   
   Opts:
   ```clj
   {:disconnect-random {:targets [...]}}  ; A collection of node specs, e.g. [:one, :all]
  ```"
  [{:keys [db faults interval disconnect-random] :as _opts}]
  (when (contains? faults :disconnect-random)
    (let [targets    (:targets disconnect-random (nc/node-specs db))
          disconnect (fn disconnect [_ _]
                       {:type  :info
                        :f     :disconnect-random
                        :value (rand-nth targets)})
          connect    {:type  :info
                      :f     :connect-random
                      :value (rand-nth targets)}
          gen        (->> (gen/flip-flop disconnect (repeat connect))
                          (gen/stagger (or interval nc/default-interval)))]
      {:generator       gen
       :final-generator (assoc connect :value :all)
       :nemesis         (disconnect-random-nemesis db)
       :perf            #{{:name  "disconnect-random"
                           :fs    #{}
                           :start #{:disconnect-random}
                           :stop  #{:connect-random}
                           :color "#D1E8A0"}}})))

(defn stop-node!
  "Stopping a node is
   - call db.close() on node
   - kill node"
  [{:keys [db] :as test} node]
  (try
    (http/get (str "http://" node ":8089/" nemesis-path "/close"))
    (db/kill! db test node)
    :stopped
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn start-node!
  [{:keys [db] :as test} node]
  ; will return :started or :already-running
  (db/start! db test node))

(defn stop-start-nemesis
  "A nemesis that stops and starts nodes.
   This nemesis responds to:
  ```
  {:f :stop-nodes  :value :node-spec}   ; target nodes as interpreted by `db-nodes`
  {:f :start-nodes :value nil}
   ```"
  [db]
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:stop-nodes :start-nodes})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this {:keys [nodes postgres-nodes] :as test} {:keys [f value] :as op}]
      (let [result (case f
                     :stop-nodes  (let [; target nodes per db-spec
                                        targets (->> value
                                                     (nc/db-nodes test db)
                                                     (into #{}))
                                        ; ignore PostgreSQL nodes
                                        targets (set/difference targets postgres-nodes)]
                                    (c/on-nodes test targets stop-node!))
                     :start-nodes (let [; target all nodes
                                        targets (->> nodes
                                                     (into #{}))
                                        ; ignore PostgreSQL nodes
                                        targets (set/difference targets postgres-nodes)]
                                    (c/on-nodes test targets start-node!)))
            result (into (sorted-map) result)]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn stop-start-package
  "A nemesis and generator package that stops and starts nodes.
   
   Opts:
   ```clj
   {:stop-start {:targets [...]}}  ; A collection of node specs, e.g. [:one, :all]
  ```"
  [{:keys [db faults interval stop-start] :as _opts}]
  (when (contains? faults :stop-start)
    (let [targets     (:targets stop-start (nc/node-specs db))
          stop-nodes  (fn stop-nodes [_ _]
                        {:type  :info
                         :f     :stop-nodes
                         :value (rand-nth targets)})
          start-nodes (repeat {:type  :info
                               :f     :start-nodes
                               :value nil})
          gen         (->> (gen/flip-flop
                            stop-nodes
                            start-nodes)
                           (gen/stagger (or interval nc/default-interval)))]
      {:generator       gen
       :final-generator (take 1 start-nodes)
       :nemesis         (stop-start-nemesis db)
       :perf            #{{:name  "stop-start"
                           :fs    #{}
                           :start #{:stop-nodes}
                           :stop  #{:start-nodes}
                           :color "#E8DBA0"}}})))

(defn partition-sync-service
  "Partition node from sync service and PostgreSQL."
  [_test _node]
  (c/su
   (c/exec :iptables
           :-A :INPUT
           :-s :powersync
           :-j :DROP
           :-w)
   (c/exec :iptables
           :-A :INPUT
           :-s :pg-db
           :-j :DROP
           :-w))
  :partitioned)

(defn heal-sync-service
  "Heal node's network partition with sync service and PostgreSQL."
  [_test _node]
  (c/su
   (c/exec :iptables :-F :-w)
   (c/exec :iptables :-X :-w))
  :healed)

(defn partition-sync-service-nemesis
  "A nemesis that partitions nodes from the sync service and PostgreSQL.
   This nemesis responds to:
  ```
  {:f :partition-sync :value :node-spec}   ; target nodes as interpreted by `db-nodes`
  {:f :heal-sync      :value nil}
   ```"
  [db]
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:partition-sync :heal-sync})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this {:keys [nodes postgres-nodes] :as test} {:keys [f value] :as op}]
      (let [result (case f
                     :partition-sync (let [; target nodes per db-spec
                                           targets (->> value
                                                        (nc/db-nodes test db)
                                                        (into #{}))
                                           ; ignore PostgreSQL nodes
                                           targets (set/difference targets postgres-nodes)]
                                       (c/on-nodes test targets partition-sync-service))
                     :heal-sync      (let [; target all nodes
                                           targets (->> nodes
                                                        (into #{}))
                                           ; ignore PostgreSQL nodes
                                           targets (set/difference targets postgres-nodes)]
                                       (c/on-nodes test targets heal-sync-service)))
            result (into (sorted-map) result)]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn partition-sync-service-package
  "A nemesis and generator package that partitions nodes from the sync service and PostgreSQL.
   
   Opts:
   ```clj
   {:partition-sync {:targets [...]}}  ; A collection of node specs, e.g. [:one, :all]
  ```"
  [{:keys [db faults interval partition-sync] :as _opts}]
  (when (contains? faults :partition-sync)
    (let [targets                     (:targets partition-sync (nc/node-specs db))
          partition-sync-service      (fn partition-sync-service [_ _]
                                        {:type  :info
                                         :f     :partition-sync
                                         :value (rand-nth targets)})
          heal-sync-service           {:type  :info
                                       :f     :heal-sync
                                       :value nil}
          gen                         (->> (gen/flip-flop
                                            partition-sync-service
                                            (repeat heal-sync-service))
                                           (gen/stagger (or interval nc/default-interval)))]
      {:generator       gen
       :final-generator heal-sync-service
       :nemesis         (partition-sync-service-nemesis db)
       :perf            #{{:name  "part-sync"
                           :fs    #{}
                           :start #{:partition-sync}
                           :stop  #{:heal-sync}
                           :color "#B7A0E8"}}})))

(defn upload-queue-count
  "Get the count of transactions in the PowerSync db upload queue for the PowerSync node."
  [_test node]
  (try
    (-> (str "http://" node ":8089/" nemesis-path "/uploadQueueCount")
        (http/get {:accept :json :socket-timeout 1000 :connection-timeout 1000})
        :body
        (json/decode true)
        :db.uploadQueueStats.count)
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))
    (catch java.net.SocketTimeoutException ex
      (if (= (.getMessage ex) "Read timed out")
        :connection-timeout
        (throw ex)))))

(defn upload-queue-wait
  "Wait until the count of transactions in the PowerSync db upload queue for the PowerSync node is 0."
  [_test node]
  (try
    (-> (str "http://" node ":8089/" nemesis-path "/uploadQueueWait")
        (http/get {:accept :json})
        :body
        (json/decode true)
        :db.uploadQueueStats.count)
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn downloading-wait
  "Wait until db.currentStatus.downloading is false."
  [_test node]
  (try
    (-> (str "http://" node ":8089/" nemesis-path "/downloadingWait")
        (http/get {:accept :json})
        :body
        (json/decode true)
        :db.currentStatus.downloading)
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn upload-queue-nemesis
  "A nemesis that gets the count of transactions in the PowerSync db upload queue for all PowerSync nodes,
   - or waits for the PowerSync db upload queue to be 0 for all PowerSync nodes
   - or waits for the PowerSync db currentStatus downloading to be false.
   This nemesis responds to:
   ```
   {:f :upload-queue-count :value :nil}
   {:f :upload-queue-wait  :value :nil}
   {:f :downloading-wait   :value :nil}
   ```"
  []
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:upload-queue-count :upload-queue-wait
        :downloading-wait})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this {:keys [nodes postgres-nodes] :as test} {:keys [f] :as op}]
      (let [nodes    (into #{} nodes)
            ps-nodes (set/difference nodes postgres-nodes)
            result   (case f
                       :upload-queue-count (c/on-nodes test ps-nodes upload-queue-count)
                       :upload-queue-wait  (c/on-nodes test ps-nodes upload-queue-wait)
                       :downloading-wait   (c/on-nodes test ps-nodes downloading-wait))
            result   (into (sorted-map) result)]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn upload-queue-package
  "A nemesis and generator package that gets the count of transactions in the PowerSync db upload queue for all PowerSync nodes,
   with a final generator that waits for the count of transactions in the PowerSync db upload queue to be 0 for all PowerSync nodes.
   
   Opts:
   ```clj
   {:upload-queue nil}
   ```"
  [{:keys [faults interval] :as _opts}]
  (when (contains? faults :upload-queue)
    (let [interval           (or interval nc/default-interval)
          upload-queue-count (repeat
                              {:type  :info
                               :f     :upload-queue-count
                               :value nil})
          upload-queue-wait  {:type  :info
                              :f     :upload-queue-wait
                              :value nil}
          downloading-wait   {:type  :info
                              :f     :downloading-wait
                              :value nil}
          gen                (->> upload-queue-count
                                  (gen/stagger interval))]
      {:generator       gen
       :final-generator [upload-queue-wait downloading-wait]
       :nemesis         (upload-queue-nemesis)
       :perf            #{{:name  "upload-queue"
                           :fs    #{:upload-queue-count :upload-queue-wait :downloading-wait}
                           :start #{}
                           :stop  #{}
                           :color "#d3d3d3"}}}))) ; light grey

(defn nemesis-package
  "Constructs combined nemeses and generators into a nemesis package."
  [opts]
  (let [opts (update opts :faults set)]
    (->> [(disconnect-orderly-package opts)
          (disconnect-random-package opts)
          (stop-start-package opts)
          (partition-sync-service-package opts)
          (upload-queue-package opts)]
         (concat (nc/nemesis-packages opts))
         (filter :generator)
         nc/compose-packages)))
