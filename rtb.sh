#!/bin/sh

export XMPPB_LIMIT=65536

erl +K true -pa ebin -pa deps/*/ebin +P $XMPPB_LIMIT +Q $XMPPB_LIMIT \
    -sname rtb@localhost \
    -s rtb -rtb config "\"rtb.yml\"" "$@"
