#!/bin/bash

iptables -A OUTPUT -d 169.254.0.0/16 -m owner --uid-owner sync_gateway -j DROP
