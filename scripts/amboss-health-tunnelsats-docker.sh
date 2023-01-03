#!/bin/bash

set -eo pipefail

URL="https://api.amboss.space/graphql"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S%z)
LIGHTNINGCONTAINER=$(docker ps --format 'table {{.Image}} {{.Names}} {{.Ports}}' | grep 0.0.0.0:9735 | awk '{print $2}')
SIGNATURE=$(docker exec $LIGHTNINGCONTAINER lncli signmessage "$NOW" | jq -r .signature)

clearnetPost=$(docker run --rm --net=docker-tunnelsats curlimages/curl -s -X POST -H "Content-Type: application/json" -d '{
  "query": "mutation healthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }",
  "variables": {
   "signature": "'"$SIGNATURE"'",
    "timestamp": "'"$NOW"'"
  }
}' $URL)

if ! [[ $clearnetPost =~ "true" ]]; then
  torPost=$(torify curl -s -X POST -H "Content-Type: application/json" -d '{
                 "query": "mutation healthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }",
                          "variables": {
                                 "signature": "'"$SIGNATURE"'",
                                 "timestamp": "'"$NOW"'"
                          }
                }' $URL)
  if ! [[ $torPost =~ "true" ]]; then
    echo "> Amboss Health Ping failed"
    exit 1
  fi
fi
