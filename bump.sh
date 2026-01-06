#!/bin/bash

APIKEY=$1
shift  # remove the first argument (API key) from "$@"

dart_bump . \
  --api-key "$APIKEY" \
  "$@"
