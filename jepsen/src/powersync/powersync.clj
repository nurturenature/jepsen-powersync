(ns powersync.powersync
  (:require [clojure.tools.logging :refer [info]]
            [jepsen
             [db :as db]
             [control :as c]
             [util :as u]]
            [jepsen.control
             [util :as cu]]))

(def install-dir
  "Directory to install into."
  "/jepsen/jepsen-powersync")

(def app-dir
  "Application directory."
  (str install-dir "/powersync_endpoint"))

(def database-file
  "SQLite3 database file."
  (str app-dir "/http.sqlite3"))

(def database-files
  "A collection of all SQLite3 database files."
  [database-file
   (str database-file "-shm")
   (str database-file "-wal")])

(def pid-file (str app-dir "/client.pid"))

(def log-file-short "client.log")
(def log-file       (str app-dir "/" log-file-short))

(def app-ps-name "powersync_http")

(def bin-path (str app-dir "/" app-ps-name))

(defn wipe
  "Wipes local SQLite3 db files.
   Assumes on node and privs for file deletion."
  []
  (c/exec :rm :-rf database-files))

(defn db
  "PowerSync or PostgreSQL endpoint database."
  []
  (reify db/DB
    (setup!
      [this test node]
      (info "Setting up powersync_endpoint db " node)

      (db/start! this test node)
      (u/sleep 1000)) ; TODO: sleep for 1s to allow endpoint to come up, should be retry http connection

    (teardown!
      [this test node]
      (info "Tearing down powersync_endpoint db")
      (db/kill! this test node)
      (c/su
       (wipe)
       (c/exec :rm :-rf log-file)))

    ; PowerSync doesn't have `primaries`.
    ; db/Primary

    db/LogFiles
    (log-files
      [_db _test _node]
      {log-file log-file-short})

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
      (c/su
       (u/retry 1 (cu/grepkill! app-ps-name)))
      :killed)

    db/Pause
    (pause!
      [_this _test _node]
      ; TODO: timeout is an attempt to workaround GitHub Action timeout
      (u/timeout 1000 :grepkill-timeout
                 (c/su
                  (cu/grepkill! :stop app-ps-name))
                 :paused))

    (resume!
      [_this _test _node]
      ; TODO: timeout is an attempt to workaround GitHub Action timeout
      (u/timeout 1000 :grepkill-timeout
                 (c/su
                  (cu/grepkill! :cont app-ps-name))
                 :resumed))))

