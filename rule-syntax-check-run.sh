#!/bin/sh

RULES=$(find /var/opt/systemd-tests/rules.d -name *.rules)
RULES+=" "$(find /var/opt/systemd-tests/rules.d -name *.rules.in)

./test/rule-syntax-check.py $RULES
