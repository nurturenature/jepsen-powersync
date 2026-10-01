(ns powersync.util
  (:require [jepsen
             [control :as c]
             [util :as u]]))

; Jepsen's grepkill! has a bug
; FORNOW: workaround by explicitly calling killall
(defn killall
  "Kills the process group, or uses `signal` if given, for the given process name (as regex).
   Assumes on node, privs."
  ([process-name] (killall :KILL process-name))
  ([signal process-name]
   (u/meh ; will Exception if no processes
    (c/exec :killall :--signal signal :--process-group :--regexp :-- process-name))))