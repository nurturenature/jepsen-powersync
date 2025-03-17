(ns powersync.client
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.tools.logging :refer [info]]
            [jepsen.client :as client]))

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
                                           v (if (contains? #{:readAll :writeSone} f)
                                               (->> v
                                                    (map (fn [[k v]]
                                                           [(parse-long (name k)) v]))
                                                    (into {}))
                                               v)]
                                       [f k v]))))))

(defn invoke
  "Invokes the op against the endpoint and returns the result."
  [op endpoint]
  (let [body   (-> (select-keys op [:type :f :value]) ; don't expose rest of op map 
                   op->json)]
    (try
      (let [result (http/post endpoint
                              {:body               body
                               :content-type       :json
                               :socket-timeout     1000
                               :connection-timeout 1000
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
               :error (.toString ex))))))

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
