(ns powersync.nemesis
  (:require [clj-http.client :as http]
            [jepsen
             [control :as c]
             [generator :as gen]
             [nemesis :as nemesis]]
            [jepsen.nemesis.combined :as nc]))

(defn disconnect
  "Disconnect from sync service."
  [_test node]
  (try
    (http/get (str "http://" node ":8089/powersync/disconnect"))
    :disconnected
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn connect
  "Connect to sync service."
  [_test node]
  (try
    (http/get (str "http://" node ":8089/powersync/connect"))
    :connected
    (catch java.net.ConnectException ex
      (if (= (.getMessage ex) "Connection refused")
        :connection-refused
        (throw ex)))))

(defn disconnect-connect-nemesis
  "A nemesis that disconnects and connects to the sync service.
   This nemesis responds to:
  ```
  {:f :disconnect :value :node-spec}   ; target nodes as interpreted by `db-nodes`
  {:f :connect    :value nil}
   ```"
  [db]
  (reify
    nemesis/Reflection
    (fs [_this]
      #{:disconnect :connect})

    nemesis/Nemesis
    (setup! [this _test]
      this)

    (invoke! [_this test {:keys [f value] :as op}]
      (let [result (case f
                     :disconnect (let [targets (nc/db-nodes test db value)]
                                   (c/on-nodes test targets disconnect))
                     :connect    (c/on-nodes test connect))]
        (assoc op :value result)))

    (teardown! [_this _test]
      nil)))

(defn disconnect-connect-package
  "A nemesis and generator package that disconnects and connects to the sync service.
   
   Opts:
   ```clj
   {:disconnect-connect {:targets [...]}}  ; A collection of node specs, e.g. [:one, :all]
  ```"
  [{:keys [db faults interval disconnect-connect] :as _opts}]
  (when (contains? faults :disconnect-connect)
    (let [targets    (:targets disconnect-connect (nc/node-specs db))
          disconnect (fn disconnect [_ _]
                       {:type  :info
                        :f     :disconnect
                        :value (rand-nth targets)})
          connect    {:type  :info
                      :f     :connect
                      :value nil}
          gen        (->> (gen/flip-flop disconnect (repeat connect))
                          (gen/stagger (or interval nc/default-interval)))]
      {:generator       gen
       :final-generator connect
       :nemesis         (disconnect-connect-nemesis db)
       :perf            #{{:name  "disconnect-connect"
                           :fs    #{}
                           :start #{:disconnect}
                           :stop  #{:connect}
                           :color "#D1E8A0"}}})))

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

    (invoke! [_this test {:keys [f value] :as op}]
      (let [result (case f
                     :partition-sync (let [targets (nc/db-nodes test db value)]
                                       (c/on-nodes test targets partition-sync-service))
                     :heal-sync      (c/on-nodes test heal-sync-service))
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
                           :color "B7A0E8"}}})))

(defn nemesis-package
  "Constructs combined nemeses and generators into a nemesis package."
  [opts]
  (let [opts (update opts :faults set)]
    (->> [(disconnect-connect-package opts)
          (partition-sync-service-package opts)]
         (concat (nc/nemesis-packages opts))
         (filter :generator)
         nc/compose-packages)))
