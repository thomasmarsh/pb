#!/usr/bin/env bash
# Rebuilds plsql-coverage-report.jar from source (src/, gen/).
#
# Not needed to just USE the tool -- the prebuilt jar is checked in. Only
# needed if gen/*.java is regenerated from a newer grammars-v4/sql/plsql
# grammar revision, or src/CoverageReport.java changes.
#
# Requires: a JDK (javac/jar) on PATH, network access (fetches the ANTLR
# Java runtime jar from Maven Central -- NOT the grammar or corpus, nothing
# corpus-related touches the network at any point).
set -euo pipefail
cd "$(dirname "$0")"

ANTLR_RUNTIME_VERSION=4.13.2
RUNTIME_JAR="antlr4-runtime-${ANTLR_RUNTIME_VERSION}.jar"
RUNTIME_URL="https://repo1.maven.org/maven2/org/antlr/antlr4-runtime/${ANTLR_RUNTIME_VERSION}/${RUNTIME_JAR}"

if [ ! -f "$RUNTIME_JAR" ]; then
  echo "Fetching $RUNTIME_JAR ..."
  curl -sf -o "$RUNTIME_JAR" "$RUNTIME_URL"
fi

rm -rf build
mkdir -p build/classes

# --release 8: target system runs JDK 8. See README "JDK 8 compatibility".
javac --release 8 -Xlint:-options -cp "$RUNTIME_JAR" -d build/classes gen/*.java src/CoverageReport.java

mkdir -p build/fatjar
( cd build/fatjar && unzip -oq "../../$RUNTIME_JAR" "org/antlr/v4/runtime/*" )
cp -r build/classes/* build/fatjar/

jar --create --file plsql-coverage-report.jar --main-class CoverageReport -C build/fatjar .

rm -rf build
echo "Built plsql-coverage-report.jar"
