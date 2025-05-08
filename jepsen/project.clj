(defproject powersync "0.0.1-SNAPSHOT"
  :description "Jepsen Causal Consistency Tests for PowerSync."
  :url "https://github.com/nurturenature/jepsen-powersync"
  :license {:name "Apache License Version 2.0, January 2004"
            :url "http://www.apache.org/licenses/"}
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [jepsen "0.3.9"]
                 [causal "0.1.0-SNAPSHOT"]
                 [cheshire "5.13.0"]
                 [clj-http "3.13.0"]
                 [com.github.seancorfield/next.jdbc "1.3.1002"]
                 [org.postgresql/postgresql "42.7.5"]]
  :jvm-opts ["-Xmx8g"
             "-Djava.awt.headless=true"
             "-server"]
  :main powersync.cli
  :repl-options {:init-ns powersync.repl}
  :plugins [[lein-codox "0.10.8"]
            [lein-localrepo "0.5.4"]]
  :codox {:output-path "target/doc/"
          :source-uri "../../{filepath}#L{line}"
          :metadata {:doc/format :markdown}})
