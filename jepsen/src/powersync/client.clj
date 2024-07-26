(ns powersync.client
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.string :as str]
            [clojure.tools.logging :refer [info]]
            [jepsen
             [client :as client]]
            [next.jdbc :as jdbc]
            [slingshot.slingshot :refer [try+ throw+]]))

(defn db-spec
  [{:keys [postgres-host] :as _opts}]
  {:dbtype   "postgresql"
   :host     (or postgres-host "pg-db")
   :user     "postgres"
   :password "mypassword"
   :dbname   "postgres"})

(defn get-jdbc-connection
  "Tries to get a `jdbc` connection for a total of ms, default 5000, every 1000ms.
   Throws if no client can be gotten."
  [db-spec]
  (let [conn (->> db-spec
                  jdbc/get-datasource
                  jdbc/get-connection)]
    (when (nil? conn)
      (throw+ {:connection-failure db-spec}))
    conn))

(defrecord PostgreSQLJDBCClient [db-spec table]
  client/Client
  (open!
    [this _test node]
    (info "PostgreSQL opening: " db-spec ", using table: " table)
    (assoc this
           :node      node
           :conn      (get-jdbc-connection db-spec)
           :table     table
           :result-kw (keyword table "v")))

  (setup!
    [_this _test])

  (invoke!
    [{:keys [conn node table result-kw] :as _this} _test {:keys [value] :as op}]
    (let [op (assoc op
                    :node node)]
      (try+
       (let [mops' (jdbc/with-transaction
                     [tx conn {:isolation :repeatable-read}]
                     (->> value
                          (mapv (fn [[f k v :as mop]]
                                  (case f
                                    :r
                                    (let [v (->> (jdbc/execute! tx [(str "SELECT k,v FROM " table " WHERE k = " k)])
                                                 (map result-kw)
                                                 first)
                                          ; v may be nil, '', ' 0...'
                                          v (cond
                                              (nil? v)
                                              nil

                                              (= (str/trim v) "")
                                              nil

                                              :else
                                              (let [v (str/trim v)]
                                                (->> (str/split v #"\s+")
                                                     (mapv parse-long))))]
                                      [:r k v])

                                    :append
                                    (let [insert (->> (jdbc/execute! tx
                                                                     [(str "INSERT INTO " table " (k,v) VALUES (" k "," v ")"
                                                                           " ON CONFLICT (k) DO UPDATE SET v = concat_ws(' '," table ".v,'" v "')")])
                                                      first)]
                                      (assert (= 1 (:next.jdbc/update-count insert)))
                                      mop))))))]
         (assoc op
                :type  :ok
                :value mops'))
       (catch (fn [e]
                (if (and (instance? org.postgresql.util.PSQLException e)
                         (re-find #"ERROR\: deadlock detected" (.getMessage e)))
                  true
                  false)) {}
         (assoc op
                :type  :fail
                :error :deadlock))
       (catch (fn [e]
                (if (and (instance? org.postgresql.util.PSQLException e)
                         (re-find #"ERROR\: could not serialize access due to concurrent update" (.getMessage e)))
                  true
                  false)) {}
         (assoc op
                :type  :fail
                :error :concurrent-update)))))

  (teardown!
    [_this _test])

  (close!
    [{:keys [conn] :as _client} _test]
    (.close conn)))

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
        ]
    (try
      (let [result (http/post endpoint
                              {:body               body
                               :content-type       :json
                               :socket-timeout     1000
                               :connection-timeout 1000
                               :accept             :json})
            result (:body result)]
        (merge op
               {:type  :ok ; always :ok, i.e. no Exception
                :value (->> result
                            json->op
                            :value)}))

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
    [this {:keys [postgres-nodes] :as _test} node]
    ; PostgreSQL client or PowerSync client
    (if (contains? postgres-nodes node)
      (client/open! (PostgreSQLJDBCClient. (db-spec test) "lww") test node)
      (assoc this
             :node node
             :url  (str "http://" node ":8089" "/sql-txn"))))

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
