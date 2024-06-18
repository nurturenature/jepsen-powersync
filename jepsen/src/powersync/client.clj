(ns powersync.client
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.tools.logging :refer [info]]
            [jepsen
             [client :as client]]))

(defn op->json
  "Given an op, encodes it as a json string."
  [op]
  (-> op
      (update :value (fn [value]
                       (->> value
                            (mapv (fn [[f k v :as _mop]]
                                    {:f f :k k :v v})))))
      json/generate-string))

(defn json->op
  "Given a json string, decodes it into an op."
  [json-string]
  (-> json-string
      (json/decode true)
      (update :value (partial mapv (fn [{:keys [f k v]}]
                                     (let [f (keyword f)]
                                       (case f
                                         :append [f k v]
                                         :r
                                         (if (nil? v)
                                           [f k nil]
                                           [f k (read-string v)]))))))))

(defn invoke
  "Invokes the op against the endpoint and returns the result."
  [op endpoint]
  (let [body   (->> (select-keys op [:value]) ; only sending :value
                    op->json)                 ; don't expose rest of op map
        result (http/post endpoint
                          {:body               body
                           :content-type       :json
                           :socket-timeout     1000
                           :connection-timeout 1000
                           :accept             :json})
        result (:body result)]

    (merge op
           {:type :ok}          ; always :ok, i.e. no Exception
           (json->op result)))) ; :value

(defrecord PowerSyncClient [conn]
  client/Client
  (open!
    [this _test node]
    (assoc this
           :node node
           :url  (str "http://" node ":8089" "/sql-txn")))

  (setup!
    [_this _test])

  (invoke!
    [{:keys [node url] :as _this} _test op]
    (let [op (assoc op :node node)]
      (invoke op url)))

  (teardown!
    [_this _test])

  (close!
    [this _test]
    (dissoc this
            :node
            :url)))

(defrecord PowerSyncClientNOOP [conn]
  client/Client
  (open!
    [this _test node]
    (assoc this
           :node node
           :url  (str "http://" node ":8089" "/sql-txn")))

  (setup!
    [_this _test])

  (invoke!
    [_this _test op]
    (info "client ignoring: " op)
    (assoc op :type :ok))

  (teardown!
    [_this _test])

  (close!
    [this _test]
    (dissoc this
            :node
            :url)))
