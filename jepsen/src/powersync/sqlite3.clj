(ns powersync.sqlite3
  (:require [clojure.tools.logging :refer [info]]
            [jepsen
             [db :as db]
             [control :as c]]
            [jepsen.control
             [util :as cu]]))

(def install-dir
  "Directory to install into."
  "/jepsen/jepsen-powersync")

(def app-dir
  "Application directory."
  (str install-dir "/sqlite3_endpoint"))

(def database-file
  "Local SQLite3 database file."
  (str app-dir "/sqlite3.db"))

(def database-files
  "A collection of all local SQLite3 database files."
  [database-file
   (str database-file "-shm")
   (str database-file "-wal")])

(def pid-file (str app-dir "/client.pid"))

(def log-file-short "client.log")
(def log-file       (str app-dir "/" log-file-short))

(def app-ps-name "sqlite3_endpoint.exe")
(def bin-path (str app-dir "/bin/" app-ps-name))

(defn wipe
  "Wipes local SQLite3 db files.
   Assumes on node and privs for file deletion."
  []
  (c/exec :rm :-rf database-files))

(defn db
  "Local SQLite3 database."
  []
  (reify db/DB
    (setup!
      [this test node]
      (info "Setting up local PowerSync client")

      (db/start! this test node))

    (teardown!
      [this test node]
      (info "Tearing down local PowerSync")
      (db/kill! this test node)
      (c/su
       (wipe)
       (c/exec :rm :-rf log-file)))

    ; local SQLite3 doesn't have `primaries`.
    ; db/Primary

    db/LogFiles
    (log-files
      [_db _test _node]
      {log-file log-file-short})

    db/Kill
    (start!
      [_this _test _node]
      (if (cu/daemon-running? pid-file)
        :already-running
        (do
          (c/su
           (cu/start-daemon!
            {:chdir   app-dir
             :logfile log-file
             :pidfile pid-file}
            bin-path))
          :started)))

    (kill!
      [_this _test _node]
      (c/su
       (cu/stop-daemon! pid-file)
       (cu/grepkill! app-ps-name))
      :killed)

    db/Pause
    (pause!
      [_this _test _node]
      (c/su
       (cu/grepkill! :stop app-ps-name))
      :paused)

    (resume!
      [_this _test _node]
      (c/su
       (cu/grepkill! :cont app-ps-name))
      :resumed)))
