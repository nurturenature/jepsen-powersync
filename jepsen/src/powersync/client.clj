(ns powersync.client
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.tools.logging :refer [info]]
            [jepsen.client :as client]
            [slingshot.slingshot :refer [try+]]))

(defn op->json
  "Given an op, encodes it as a json string."
  [op]
  (-> op
      (update :value (fn [value]
                       (->> value
                            (mapv (fn [[f k v :as _mop]]
                                    ; JSON requires Maps with String keys
                                    (let [v (if (= f :writeSome)
                                              (->> v
                                                   (map (fn [[k v]]
                                                          [(str k) v]))
                                                   (into {}))
                                              v)]
                                      {:f f :k k :v v}))))))
      json/generate-string))

(defn json->op
  "Given a json string, decodes it into an op."
  [json-string]
  (-> json-string
      (json/decode true)
      (select-keys [:type :f :value])
      (update :type  keyword)
      (update :f     keyword)
      (update :value (partial mapv (fn [{:keys [f k v]}]
                                     (let [f (keyword f)
                                           ; JSON Maps had Strings as keys,
                                           ; which json/decode will have turned into keywords
                                           v (if (contains? #{:readAll :writeSome} f)
                                               (->> v
                                                    (map (fn [[k v]]
                                                           [(parse-long (name k)) v]))
                                                    (into {}))
                                               v)]
                                       [f k v]))))))

(defn invoke
  "Invokes the op against the endpoint and returns the result."
  [op endpoint timeout]
  (let [body   (-> (select-keys op [:type :f :value]) ; don't expose rest of op map 
                   op->json)]
    (try+
     (let [result (http/post endpoint
                             {:body               body
                              :content-type       :json
                              :socket-timeout     timeout  ; TODO: correlate with PowerSync pg_endpoint behavior
                              :connection-timeout timeout  ;       correlate with postgres  run_tx      behavior
                              :accept             :json})
           op'    (->> result
                       :body
                       json->op)]
       (merge op op'))

     (catch java.net.ConnectException ex
       (if (= (.getMessage ex) "Connection refused")
         (assoc op
                :type  :fail
                :error (.toString ex))
         (assoc op
                :type  :info
                :error (.toString ex))))
     (catch java.net.SocketException ex
       (if (= (.getMessage ex) "Connection reset")
         (assoc op
                :type  :info
                :error (.toString ex))
         (assoc op
                :type  :info
                :error (.toString ex))))
     (catch java.net.SocketTimeoutException ex
       (assoc op
              :type  :info
              :error (.toString ex)))
     (catch org.apache.http.NoHttpResponseException ex
       (assoc op
              :type  :info
              :error (.toString ex)))
     (catch [:status 500] {}
       (assoc op
              :type  :info
              :error {:status 500})))))

(defrecord PowerSyncClient [conn]
  client/Client
  (open!
    [this {:keys [client-timeout] :as _test} node]
    (assoc this
           :node    node
           :url     (str "http://" node ":8089" "/sql-txn")
           :timeout (* client-timeout 1000)))

  (setup!
    [_this _test])

  (invoke!
    [{:keys [node url timeout] :as _this} _test op]
    (let [op (assoc op :node node)]
      (invoke op url timeout)))

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
