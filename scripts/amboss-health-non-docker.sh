#!/bin/bash

set -e

URL="https://api.amboss.space/graphql"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S%z)
SIGNATURE=$(/usr/local/bin/lncli signmessage "$NOW" | jq -r .signature)

clearnetPost=$(/usr/bin/cgexec -g net_cls:splitted_processes curl -s -X POST -H "Content-Type: application/json" -d '{
  "query": "mutation healthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }",
  "variables": {
   "signature": "'"$SIGNATURE"'",
    "timestamp": "'"$NOW"'"
  }
}' $URL)

if [[ $clearnetPost =~ "error" ]]; then
  torPost=$(torify curl -s -X POST -H "Content-Type: application/json" -d '{
                 "query": "mutation healthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }",
                          "variables": {
                                 "signature": "'"$SIGNATURE"'",
                                 "timestamp": "'"$NOW"'"
                          }
                }' $URL)
  if [[ $torPost =~ "error" ]]; then
    echo "> Amboss Health Ping failed"
    exit 1
  fi
fi
