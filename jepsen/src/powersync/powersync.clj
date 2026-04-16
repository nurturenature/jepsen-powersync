(ns powersync.powersync
  (:require [clojure.tools.logging :refer [info]]
            [jepsen
             [db :as db]
             [control :as c]
             [lazyfs :as lazyfs]
             [util :as u]]
            [jepsen.control
             [util :as cu]]))

(def install-dir
  "Directory to install into."
  "/jepsen/jepsen-powersync")

(def app-dir
  "Application directory."
  (str install-dir "/powersync_endpoint"))

(def data-dir
  "Where to store SQLite3 database files"
  (str app-dir "/data"))

(comment
  (def database-file
    "SQLite3 database file."
    (str data-dir "/http.sqlite3"))

  (def database-files
    "A collection of all SQLite3 database files."
    [database-file
     (str database-file "-shm")
     (str database-file "-wal")]))

(def pid-file (str app-dir "/client.pid"))

(def log-file-short "client.log")
(def log-file       (str app-dir "/" log-file-short))

(def app-ps-name "powersync_http")

(def bin-path (str app-dir "/powersync_http/bundle/bin/" app-ps-name))

(defn wipe
  "Wipes local SQLite3 db data dir.
   Assumes on node and privs for file deletion."
  []
  (c/exec :rm :-rf data-dir))

(defrecord PSDB [lazyfs-db]
  db/DB
  (setup!
    [this test node]
    (info "Setting up powersync_endpoint db " node)

    ; insure data dir exists, else SQLite will fail creating db file
    (c/su
     (c/exec :mkdir :--parents data-dir))

    ; setup lazyfs first
    (when lazyfs-db
      (db/setup! lazyfs-db test node))

    (db/start! this test node)
    (u/sleep 1000)) ; TODO: sleep for 1s to allow endpoint to come up, should be retry http connection

  (teardown!
    [this test node]
    (info "Tearing down powersync_endpoint db")
    (db/kill! this test node)

    ; teardown lazyfs before wiping files
    (when lazyfs-db
      (db/teardown! lazyfs-db test node))

    (c/su
     (wipe)
     (c/exec :rm :-rf log-file)))

  ; PowerSync doesn't have `primaries`.
  db/Primary
  (primaries
    [_db _test]
    nil)

  (setup-primary!
    [_db _test _node]
    nil)

  db/LogFiles
  (log-files
    [_db test node]
    (merge
     {log-file log-file-short}
     (when lazyfs-db
       (db/log-files lazyfs-db test node))))

  db/Kill
  (start!
    [_this {:keys [postgres-nodes] :as _test} node]
    (if (cu/daemon-running? pid-file)
      :already-running
      (let [endpoint (if (contains? postgres-nodes node)
                       :postgresql
                       :powersync)]
        (c/su
         (cu/start-daemon!
          {:chdir   app-dir
           :logfile log-file
           :pidfile pid-file}
          bin-path
          :--endpoint endpoint))
        :started)))

  (kill!
    [_this _test _node]
    ; TODO: understand why sporadic Exception with exit code of 137 when using Docker,
    ;       for now, retrying is effective and safe 
    (u/timeout 10000
               :timed-out
               (do
                 (c/su
                  (u/retry 1 (cu/grepkill! app-ps-name)))
                 :killed)))

  db/Pause
  (pause!
    [_this _test _node]
    ; TODO: understand why sporadic Exception with exit code of 137 when using Docker,
    ;       for now, retrying is effective and safe 
    (u/timeout 10000
               :timed-out
               (do
                 (c/su
                  (u/retry 1 (cu/grepkill! :stop app-ps-name)))
                 :paused)))

  (resume!
    [_this _test _node]
    ; TODO: understand why sporadic Exception with exit code of 137 when using Docker,
    ;       for now, retrying is effective and safe 
    (u/timeout 10000
               :timed-out
               (do
                 (c/su
                  (u/retry 1 (cu/grepkill! :cont app-ps-name)))
                 :resumed))))

(defn psdb
  "Installs and uses PowerSync."
  []
  (PSDB. nil))

(defn lazyfs-psdb
  "Installs and uses PowerSync.
   Data directory is mounted on a lazyfs."
  []
  (let [lazyfs-db (->> data-dir
                       lazyfs/lazyfs
                       lazyfs/db)]
    (PSDB. lazyfs-db)))
