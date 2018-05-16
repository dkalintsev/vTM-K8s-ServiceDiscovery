#!/bin/bash

cat <<EOF
{
    "version":1,
    "nodes":[
        { "ip":"192.0.2.0", "port":80 },
        { "ip":"192.0.2.1", "port":81, "draining":true }
    ],
    "code":200
}
EOF
